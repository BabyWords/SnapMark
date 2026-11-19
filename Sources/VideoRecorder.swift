import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// 录屏时的声音来源。
enum RecordingAudioSource: Int, CaseIterable {
    case none = 0
    case system = 1
    case microphone = 2
    case both = 3

    var title: String {
        switch self {
        case .none: return "静音"
        case .system: return "系统声音"
        case .microphone: return "麦克风"
        case .both: return "系统 + 麦克风"
        }
    }

    var capturesSystemAudio: Bool { self == .system || self == .both }
    var capturesMicrophone: Bool { self == .microphone || self == .both }
}

final class VideoRecorder: NSObject, SCStreamOutput, SCStreamDelegate,
                           AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFinish: ((Result<URL, Error>) -> Void)?
    var onStarted: (() -> Void)?

    private enum RecorderError: LocalizedError {
        case invalidScreen
        case invalidRegion
        case displayUnavailable
        case noFrames
        case writerSetup
        case outputExists
        case appendFailed

        var errorDescription: String? {
            switch self {
            case .invalidScreen: return "无法识别录制屏幕。"
            case .invalidRegion: return "录制区域无效。"
            case .displayUnavailable: return "找不到要录制的显示器。"
            case .noFrames: return "录制期间没有收到完整画面。"
            case .writerSetup: return "无法初始化视频写入器。"
            case .outputExists: return "输出文件已存在。"
            case .appendFailed: return "写入视频帧失败。"
            }
        }
    }

    private let outputURL: URL
    private let displayID: CGDirectDisplayID
    private let sourceRect: CGRect
    private let outputWidth: Int
    private let outputHeight: Int
    private let excludingWindowID: CGWindowID?
    private let audioSource: RecordingAudioSource
    /// 视频帧、系统音频、麦克风全部在这个串行队列里处理，避免多队列竞态。
    private let outputQueue = DispatchQueue(label: "snapmark.video-recorder.frames")
    private let lock = NSLock()

    private var stream: SCStream?
    private var startRequested = false
    private var stopRequested = false
    private var captureStarted = false
    private var stopInFlight = false
    private var completionDelivered = false
    private var pendingError: Error?
    private var stopUptime: TimeInterval?

    // The writer and frame timing state are only accessed on outputQueue.
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var lastPixelBuffer: CVPixelBuffer?
    private var firstFrameUptime: TimeInterval?
    private var frameCount = 0
    private var writerFinishing = false
    private var ownsOutputFile = false
    private var tailFrame: (CVPixelBuffer, CMTime)?

    // 麦克风采集（AVCaptureSession），只在本对象持有期间存活。
    private var microphoneSession: AVCaptureSession?
    private var microphoneFirstPTS: CMTime?

    init(screen: NSScreen, region: NSRect, outputURL: URL,
         excludingWindowID: CGWindowID? = nil, audioSource: RecordingAudioSource = .none) {
        self.outputURL = outputURL
        self.excludingWindowID = excludingWindowID
        self.audioSource = audioSource
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        displayID = number.map { CGDirectDisplayID($0.uint32Value) } ?? 0
        let geometry = number == nil ? nil : Self.captureGeometry(
            region: region, screenSize: screen.frame.size, scale: screen.backingScaleFactor
        )
        sourceRect = geometry?.sourceRect ?? .zero
        outputWidth = geometry?.width ?? 0
        outputHeight = geometry?.height ?? 0
        super.init()
        if number == nil {
            recordError(RecorderError.invalidScreen)
        } else if geometry == nil {
            recordError(RecorderError.invalidRegion)
        }
    }

    /// Converts display-local AppKit coordinates (bottom-left origin) into
    /// ScreenCaptureKit's top-left source rectangle and even pixel dimensions.
    static func captureGeometry(region: NSRect, screenSize: NSSize, scale: CGFloat)
        -> (sourceRect: CGRect, width: Int, height: Int)? {
        guard scale.isFinite, scale > 0,
              screenSize.width.isFinite, screenSize.height.isFinite,
              screenSize.width > 0, screenSize.height > 0,
              region.minX.isFinite, region.minY.isFinite,
              region.width.isFinite, region.height.isFinite else { return nil }
        let bounds = CGRect(origin: .zero, size: screenSize)
        let rect = region.standardized.intersection(bounds)
        guard !rect.isNull, !rect.isEmpty else { return nil }

        func evenPixelLength(_ points: CGFloat) -> Int {
            let rounded = max(2, Int((points * scale).rounded()))
            return rounded.isMultiple(of: 2) ? rounded : rounded + 1
        }
        guard rect.width * scale < CGFloat(Int.max - 2),
              rect.height * scale < CGFloat(Int.max - 2) else { return nil }

        return (
            CGRect(x: rect.minX, y: screenSize.height - rect.maxY,
                   width: rect.width, height: rect.height),
            evenPixelLength(rect.width),
            evenPixelLength(rect.height)
        )
    }

    func start() {
        lock.lock()
        guard !startRequested, !completionDelivered else {
            lock.unlock()
            return
        }
        startRequested = true
        let invalid = pendingError
        lock.unlock()

        if let invalid {
            outputQueue.async { [weak self] in self?.finishWithoutCapture(error: invalid) }
            return
        }

        guard #available(macOS 14.0, *) else {
            outputQueue.async { [weak self] in
                self?.finishWithoutCapture(error: NSError(domain: "VideoRecorder", code: 14,
                                                          userInfo: [NSLocalizedDescriptionKey: "录屏需要 macOS 14 或更高版本。"]))
            }
            return
        }

        Task { [weak self] in
            await self?.beginCapture()
        }
    }

    func stop() {
        lock.lock()
        guard startRequested, !completionDelivered else {
            lock.unlock()
            return
        }
        stopRequested = true
        if stopUptime == nil { stopUptime = ProcessInfo.processInfo.systemUptime }
        let shouldStop = captureStarted && !stopInFlight
        if shouldStop { stopInFlight = true }
        let currentStream = stream
        lock.unlock()

        if shouldStop, let currentStream {
            stopCapture(currentStream)
        }
    }

    @available(macOS 14.0, *)
    private func beginCapture() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard !isStopRequested else {
                outputQueue.async { [weak self] in self?.finishWithoutCapture(error: RecorderError.noFrames) }
                return
            }
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw RecorderError.displayUnavailable
            }

            let filter = SCContentFilter(display: display, excludingWindows: excludedWindows(from: content))
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = sourceRect
            configuration.width = outputWidth
            configuration.height = outputHeight
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.queueDepth = 8
            configuration.showsCursor = true
            configuration.capturesAudio = audioSource.capturesSystemAudio

            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            if audioSource.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)
            }

            lock.withLock { self.stream = stream }

            try await stream.startCapture()

            // 麦克风与录屏同步启动；失败只降级为无麦克风声音，不影响录屏。
            if audioSource.capturesMicrophone {
                startMicrophoneCapture()
            }

            let shouldStop = lock.withLock {
                captureStarted = true
                let shouldStop = stopRequested && !stopInFlight
                if shouldStop { stopInFlight = true }
                return shouldStop
            }

            DispatchQueue.main.async { [weak self] in self?.onStarted?() }
            if shouldStop { stopCapture(stream) }
        } catch {
            recordError(error)
            let (currentStream, shouldStop) = lock.withLock {
                stopRequested = true
                let currentStream = self.stream
                let shouldStop = currentStream != nil && !stopInFlight
                if shouldStop { stopInFlight = true }
                return (currentStream, shouldStop)
            }
            if shouldStop, let currentStream {
                stopCapture(currentStream)
            } else {
                outputQueue.async { [weak self] in self?.finishWithoutCapture(error: error) }
            }
        }
    }

    /// 从 SCShareableContent 里找到要排除的提示窗（录制范围红框），返回排除列表。
    private func excludedWindows(from content: SCShareableContent) -> [SCWindow] {
        guard let excludingWindowID,
              let hintWindow = content.windows.first(where: { $0.windowID == excludingWindowID }) else {
            return []
        }
        return [hintWindow]
    }

    private func stopCapture(_ stream: SCStream) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await stream.stopCapture()
            } catch {
                self.recordError(error)
            }
            self.stopMicrophone()
            // This block is ordered after all pending sample callbacks on the same serial queue.
            self.outputQueue.async { [weak self] in self?.finishAfterCaptureStopped() }
        }
    }

    // MARK: 屏幕 / 系统音频采集

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        if outputType == .audio {
            handleSystemAudio(sampleBuffer)
            return
        }
        guard outputType == .screen else { return }
        // 帧状态（.complete 表示有可用画面）存放在 sample attachments 数组里，
        // 而不是 buffer 级 attachment。用 CMGetAttachment 读不到，会把所有帧都当成
        // 无效丢弃，导致停止时 frameCount == 0、报“没有收到完整画面”。
        guard let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = attachmentsArray.first,
              let statusRawValue = attachments[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRawValue),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard !isStopRequested else { return }
        appendFrame(pixelBuffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordError(error)
        lock.lock()
        stopRequested = true
        if stopUptime == nil { stopUptime = ProcessInfo.processInfo.systemUptime }
        let shouldStop = captureStarted && !stopInFlight
        if shouldStop { stopInFlight = true }
        lock.unlock()
        if shouldStop { stopCapture(stream) }
    }

    // MARK: 麦克风采集

    private func startMicrophoneCapture() {
        guard microphoneSession == nil else { return }
        guard let device = AVCaptureDevice.default(for: .audio) else {
            FileHandle.standardError.write(Data("SnapMark: 找不到麦克风设备，本次录屏不采集麦克风。\n".utf8))
            return
        }
        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            // 固定输出为线性 PCM，交给 AVAssetWriter 实时编码成 AAC。
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            output.setSampleBufferDelegate(self, queue: outputQueue)
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)

            session.startRunning()
            microphoneSession = session
        } catch {
            FileHandle.standardError.write(Data("SnapMark: 麦克风启动失败（\(error.localizedDescription)），本次录屏不采集麦克风。\n".utf8))
        }
    }

    private func stopMicrophone() {
        microphoneSession?.stopRunning()
        microphoneSession = nil
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handleMicrophoneBuffer(sampleBuffer)
    }

    private func handleMicrophoneBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard !isStopRequested else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return }
        if microphoneFirstPTS == nil { microphoneFirstPTS = pts }
        guard let first = microphoneFirstPTS else { return }
        let relative = CMTimeSubtract(pts, first)
        guard CMTimeCompare(relative, .zero) >= 0 else { return }
        guard let input = microphoneInput, input.isReadyForMoreMediaData else { return }
        guard let retimed = Self.retimed(sampleBuffer, to: relative) else { return }
        if !input.append(retimed) {
            recordError(writer?.error ?? RecorderError.appendFailed)
        }
    }

    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !isStopRequested else { return }
        guard let firstPresentationTime else { return }   // 视频第一帧尚未到达，丢弃
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid, pts.isNumeric else { return }
        let relative = CMTimeSubtract(pts, firstPresentationTime)
        guard CMTimeCompare(relative, .zero) >= 0 else { return }
        guard let input = systemAudioInput, input.isReadyForMoreMediaData else { return }
        guard let retimed = Self.retimed(sampleBuffer, to: relative) else { return }
        if !input.append(retimed) {
            recordError(writer?.error ?? RecorderError.appendFailed)
        }
    }

    /// 用新的展示时间戳重建一个 sample buffer（数据不变），供 writer 按相对时间写入。
    private static func retimed(_ sampleBuffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        guard status == noErr else { return nil }
        return out
    }

    private var isStopRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested || completionDelivered
    }

    private func appendFrame(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard presentationTime.isValid, presentationTime.isNumeric else { return }

        if writer == nil {
            do {
                try createWriter()
                firstPresentationTime = presentationTime
                firstFrameUptime = ProcessInfo.processInfo.systemUptime
                writer?.startSession(atSourceTime: .zero)
            } catch {
                recordError(error)
                requestStopAfterWriterFailure()
                return
            }
        }

        guard let firstPresentationTime,
              let writer, writer.status == .writing,
              let writerInput, let adaptor else { return }

        let relativeTime = CMTimeSubtract(presentationTime, firstPresentationTime)
        if let lastPresentationTime, CMTimeCompare(relativeTime, lastPresentationTime) <= 0 { return }

        guard writerInput.isReadyForMoreMediaData else { return }
        guard adaptor.append(pixelBuffer, withPresentationTime: relativeTime) else {
            recordError(writer.error ?? RecorderError.appendFailed)
            requestStopAfterWriterFailure()
            return
        }
        lastPresentationTime = relativeTime
        lastPixelBuffer = pixelBuffer
        frameCount += 1
        if let firstFrameUptime {
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - firstFrameUptime)
            tailFrame = (pixelBuffer, CMTime(seconds: elapsed, preferredTimescale: 600))
        }
    }

    private func createWriter() throws {
        guard outputWidth >= 2, outputHeight >= 2 else { throw RecorderError.invalidRegion }
        guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw RecorderError.outputExists }
        ownsOutputFile = true
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let bitRate = max(2_000_000, outputWidth * outputHeight * 6)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoMaxKeyFrameIntervalKey: 60
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(input) else { throw RecorderError.writerSetup }
        writer.add(input)

        // 系统声音：SCK 输出的是压缩 AAC，直接 passthrough。
        if audioSource.capturesSystemAudio {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            audioInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(audioInput) else { throw RecorderError.writerSetup }
            writer.add(audioInput)
            systemAudioInput = audioInput
        }

        // 麦克风：PCM 交给 writer 实时编码成 AAC。
        if audioSource.capturesMicrophone {
            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128_000
            ])
            micInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(micInput) else { throw RecorderError.writerSetup }
            writer.add(micInput)
            microphoneInput = micInput
        }

        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerSetup }
        self.writer = writer
        writerInput = input
        self.adaptor = adaptor
    }

    private func requestStopAfterWriterFailure() {
        lock.lock()
        stopRequested = true
        if stopUptime == nil { stopUptime = ProcessInfo.processInfo.systemUptime }
        let shouldStop = captureStarted && !stopInFlight
        if shouldStop { stopInFlight = true }
        let currentStream = stream
        lock.unlock()
        if shouldStop, let currentStream { stopCapture(currentStream) }
    }

    private func finishWithoutCapture(error: Error) {
        recordError(error)
        finishWriterOrReportNoFrames()
    }

    private func finishAfterCaptureStopped() {
        guard !writerFinishing else { return }
        finishWriterOrReportNoFrames()
    }

    private func finishWriterOrReportNoFrames() {
        guard !writerFinishing else { return }
        guard let writer, let writerInput else {
            complete(.failure(currentError ?? RecorderError.noFrames))
            return
        }
        guard frameCount > 0, writer.status == .writing else {
            let error = writer.error ?? currentError ?? RecorderError.noFrames
            writer.cancelWriting()
            complete(.failure(error))
            return
        }

        appendTailFrameIfNeeded()
        writerFinishing = true
        writerInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        microphoneInput?.markAsFinished()
        writer.finishWriting { [weak self, weak writer] in
            guard let self else { return }
            if let writer, writer.status == .completed {
                self.complete(.success(self.outputURL))
            } else {
                self.complete(.failure(writer?.error ?? self.currentError ?? RecorderError.writerSetup))
            }
        }
    }

    private func appendTailFrameIfNeeded() {
        guard let firstFrameUptime, let lastPresentationTime, let lastPixelBuffer,
              let writer, writer.status == .writing,
              let writerInput, writerInput.isReadyForMoreMediaData,
              let adaptor else { return }

        lock.lock()
        let stopUptime = self.stopUptime ?? ProcessInfo.processInfo.systemUptime
        lock.unlock()
        let elapsed = max(0, stopUptime - firstFrameUptime)
        let stopTime = CMTime(seconds: elapsed, preferredTimescale: 600)
        let frameDuration = CMTime(value: 1, timescale: 30)
        let tailTime = CMTimeCompare(stopTime, CMTimeAdd(lastPresentationTime, frameDuration)) > 0
            ? stopTime : CMTimeAdd(lastPresentationTime, frameDuration)
        guard CMTimeCompare(tailTime, lastPresentationTime) > 0 else { return }
        if !adaptor.append(lastPixelBuffer, withPresentationTime: tailTime) {
            recordError(writer.error ?? RecorderError.appendFailed)
        }
    }

    private var currentError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return pendingError
    }

    private func recordError(_ error: Error) {
        lock.lock()
        if pendingError == nil { pendingError = error }
        lock.unlock()
    }

    private func complete(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completionDelivered else {
            lock.unlock()
            return
        }
        completionDelivered = true
        lock.unlock()
        if case .failure = result, ownsOutputFile {
            try? FileManager.default.removeItem(at: outputURL)
        }
        DispatchQueue.main.async { [weak self] in self?.onFinish?(result) }
    }
}
