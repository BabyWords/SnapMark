import AppKit
import ImageIO

/// Periodically captures a fixed screen region and appends only the newly revealed strip.
final class ScrollCaptureController {
    enum Axis { case vertical, horizontal }

    private let screen: NSScreen
    private let region: NSRect
    private let axis: Axis
    private var timer: Timer?
    private var capturing = false
    private var previous: CGImage?
    private var canvas: CGContext?
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var stopped = false
    private let maxPixels = 24_000_000

    var onFinish: ((CGImage?) -> Void)?
    var onStatus: ((String) -> Void)?

    init(screen: NSScreen, region: NSRect, axis: Axis) {
        self.screen = screen
        self.region = region
        self.axis = axis
    }

    func start() {
        onStatus?("长截图采集中：请缓慢滚动，点菜单栏 SnapMark → 停止长截图")
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.captureFrame() }
        timer?.fire()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        let image = canvas?.makeImage()
        onFinish?(image)
    }

    private func captureFrame() {
        guard !capturing, !stopped else { return }
        capturing = true
        ScreenCapture.capture(screen: screen) { [weak self] outcome in
            guard let self else { return }
            self.capturing = false
            guard !self.stopped else { return }
            guard case .success(let full) = outcome, let frame = self.crop(full) else { return }
            self.append(frame)
        }
    }

    private func crop(_ full: CGImage) -> CGImage? {
        let scale = CGFloat(full.width) / max(1, screen.frame.width)
        let px = CGRect(x: region.minX * scale,
                        y: CGFloat(full.height) - region.maxY * scale,
                        width: region.width * scale,
                        height: region.height * scale).integral
        return full.cropping(to: px.intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height)))
    }

    private func append(_ frame: CGImage) {
        guard let previous else {
            guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return }
            pixelWidth = frame.width
            pixelHeight = frame.height
            canvas = CGContext(data: nil, width: pixelWidth, height: pixelHeight,
                               bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            canvas?.draw(frame, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            self.previous = frame
            return
        }

        guard previous.width == frame.width, previous.height == frame.height else { return }
        if averageDifference(previous: previous, next: frame) < 0.012 {
            return
        }
        let overlap = bestOverlap(previous: previous, next: frame)
        guard overlap > 8 else {
            onStatus?("未匹配到重叠内容，请慢一些滚动，或停止后重新开始")
            return
        }
        let advance = (axis == .vertical ? frame.height : frame.width) - overlap
        guard advance > 2 else { return }
        let newW = axis == .horizontal ? pixelWidth + advance : pixelWidth
        let newH = axis == .vertical ? pixelHeight + advance : pixelHeight
        guard newW > 0, newH > 0, newW <= maxPixels / max(1, newH),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let nextCanvas = CGContext(data: nil, width: newW, height: newH,
                                         bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            onStatus?("长图达到安全尺寸上限，正在完成已有内容")
            stop()
            return
        }
        guard let existing = canvas?.makeImage() else { return }
        if axis == .vertical {
            nextCanvas.draw(existing, in: CGRect(x: 0, y: advance, width: pixelWidth, height: pixelHeight))
            nextCanvas.draw(frame, in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        } else {
            nextCanvas.draw(existing, in: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
            nextCanvas.draw(frame, in: CGRect(x: pixelWidth - overlap, y: 0, width: frame.width, height: frame.height))
        }
        canvas = nextCanvas
        pixelWidth = newW
        pixelHeight = newH
        self.previous = frame
        onStatus?("长截图采集中：\(pixelWidth) × \(pixelHeight) 像素")
    }

    private struct PixelSampler {
        let data: CFData
        let pointer: UnsafePointer<UInt8>
        let width: Int
        let height: Int
        let rowBytes: Int
        let bytesPerPixel: Int

        init?(_ image: CGImage) {
            guard let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return nil }
            self.data = data
            self.pointer = pointer
            width = image.width
            height = image.height
            rowBytes = image.bytesPerRow
            bytesPerPixel = max(1, image.bitsPerPixel / 8)
        }

        func value(x: Int, y: Int) -> Double {
            guard x >= 0, x < width, y >= 0, y < height else { return 0 }
            let offset = y * rowBytes + x * bytesPerPixel
            guard offset + 2 < CFDataGetLength(data) else { return 0 }
            return (Double(pointer[offset]) * 0.299 + Double(pointer[offset + 1]) * 0.587 + Double(pointer[offset + 2]) * 0.114) / 255
        }
    }

    private func averageDifference(previous: CGImage, next: CGImage) -> Double {
        guard let a = PixelSampler(previous), let b = PixelSampler(next) else { return 1 }
        let cross = axis == .vertical ? previous.width : previous.height
        let length = axis == .vertical ? previous.height : previous.width
        let crossStep = max(2, cross / 32)
        let lengthStep = max(2, length / 32)
        var diff = 0.0
        var count = 0
        for c in stride(from: crossStep / 2, to: cross, by: crossStep) {
            for p in stride(from: lengthStep / 2, to: length, by: lengthStep) {
                let x = axis == .vertical ? c : p
                let y = axis == .vertical ? p : c
                diff += abs(a.value(x: x, y: y) - b.value(x: x, y: y))
                count += 1
            }
        }
        return count == 0 ? 1 : diff / Double(count)
    }

    private func bestOverlap(previous: CGImage, next: CGImage) -> Int {
        guard let a = PixelSampler(previous), let b = PixelSampler(next) else { return 0 }
        let length = axis == .vertical ? min(previous.height, next.height) : min(previous.width, next.width)
        let cross = axis == .vertical ? previous.width : previous.height
        let minOverlap = max(16, Int(Double(length) * 0.12))
        let maxOverlap = Int(Double(length) * 0.88)
        let step = max(2, length / 180)
        let crossStep = max(2, cross / 48)
        var best = 0
        var bestError = Double.greatestFiniteMagnitude
        for overlap in stride(from: minOverlap, through: maxOverlap, by: step) {
            var error = 0.0
            var samples = 0
            for c in stride(from: crossStep / 2, to: cross, by: crossStep) {
                for d in stride(from: 0, to: overlap, by: max(step, overlap / 32)) {
                    let p1 = axis == .vertical ? (c, previous.height - overlap + d) : (previous.width - overlap + d, c)
                    let p2 = axis == .vertical ? (c, d) : (d, c)
                    error += abs(a.value(x: p1.0, y: p1.1) - b.value(x: p2.0, y: p2.1))
                    samples += 1
                }
            }
            guard samples > 0 else { continue }
            error /= Double(samples)
            if error < bestError { bestError = error; best = overlap }
        }
        return bestError < 0.10 ? best : 0
    }

}
