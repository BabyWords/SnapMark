import AppKit
import ImageIO

/// Periodically captures a fixed screen region and appends only the newly revealed strip.
final class ScrollCaptureController {
    enum Axis { case vertical, horizontal }

    private let screen: NSScreen
    private let region: NSRect
    private let axis: Axis
    private let excludedWindowID: CGWindowID?
    private var timer: Timer?
    private var capturing = false
    private var previous: CGImage?
    private var previousOffset = 0
    private var canvasOrigin = 0
    private var canvas: CGContext?
    private var pixelWidth = 0
    private var pixelHeight = 0
    private var stopped = false
    private let maxPixels = 24_000_000

    var onFinish: ((CGImage?) -> Void)?
    var onStatus: ((String) -> Void)?

    init(screen: NSScreen, region: NSRect, axis: Axis, excludingWindowID: CGWindowID? = nil) {
        self.screen = screen
        self.region = region
        self.axis = axis
        self.excludedWindowID = excludingWindowID
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
        ScreenCapture.capture(screen: screen, excludingWindowID: excludedWindowID) { [weak self] outcome in
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

    struct CanvasLayout {
        let origin: Int
        let length: Int
        let previousDrawOffset: Int
        let nextDrawOffset: Int
    }

    static func layout(canvasOrigin: Int, canvasLength: Int, newFrameOffset: Int,
                       frameLength: Int) -> CanvasLayout {
        let origin = min(canvasOrigin, newFrameOffset)
        let end = max(canvasOrigin + canvasLength, newFrameOffset + frameLength)
        return CanvasLayout(origin: origin,
                           length: end - origin,
                           previousDrawOffset: canvasOrigin - origin,
                           nextDrawOffset: newFrameOffset - origin)
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
            previousOffset = 0
            return
        }

        guard previous.width == frame.width, previous.height == frame.height else { return }
        guard let match = Self.bestOverlap(previous: previous, next: frame, axis: axis) else {
            onStatus?("未匹配到重叠内容，请缓慢滚动并避免快速跳过画面")
            return
        }
        let frameLength = axis == .vertical ? frame.height : frame.width
        let advance = frameLength - match.overlap
        guard advance > 2 else { return }

        // `previousOffset` 与 `newOffset` 均为画布中从顶部/左侧起算的坐标。
        // 匹配在帧的头部表示向顶部/左侧移动，匹配在尾部表示向底部/右侧移动。
        let newOffset = match.direction == .towardEnd
            ? previousOffset + advance
            : previousOffset - advance
        let oldAxisLength = axis == .vertical ? pixelHeight : pixelWidth
        let layout = Self.layout(canvasOrigin: canvasOrigin, canvasLength: oldAxisLength,
                                 newFrameOffset: newOffset, frameLength: frameLength)
        let newOrigin = layout.origin
        let axisLength = layout.length
        let normalizedPreviousOffset = layout.previousDrawOffset
        let normalizedNewOffset = layout.nextDrawOffset
        let newW = axis == .horizontal ? axisLength : pixelWidth
        let newH = axis == .vertical ? axisLength : pixelHeight
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
            let oldDrawY = axisLength - normalizedPreviousOffset - pixelHeight
            let frameDrawY = axisLength - normalizedNewOffset - frame.height
            nextCanvas.draw(existing, in: CGRect(x: 0, y: oldDrawY, width: pixelWidth, height: pixelHeight))
            nextCanvas.draw(frame, in: CGRect(x: 0, y: frameDrawY, width: frame.width, height: frame.height))
        } else {
            nextCanvas.draw(existing, in: CGRect(x: normalizedPreviousOffset, y: 0, width: pixelWidth, height: pixelHeight))
            nextCanvas.draw(frame, in: CGRect(x: normalizedNewOffset, y: 0, width: frame.width, height: frame.height))
        }
        canvas = nextCanvas
        pixelWidth = newW
        pixelHeight = newH
        canvasOrigin = newOrigin
        previousOffset = newOffset
        self.previous = frame
        onStatus?("长截图采集中：\(pixelWidth) × \(pixelHeight) 像素")
    }

    private struct PixelSampler {
        let pixels: [UInt8]
        let width: Int
        let height: Int

        init?(_ image: CGImage) {
            let imageWidth = image.width
            let imageHeight = image.height
            guard imageWidth > 0, imageHeight > 0, imageWidth <= Int.max / imageHeight else { return nil }
            var normalized = [UInt8](repeating: 0, count: imageWidth * imageHeight)
            var rendered = false
            normalized.withUnsafeMutableBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress,
                      let context = CGContext(data: baseAddress, width: imageWidth, height: imageHeight,
                                              bitsPerComponent: 8, bytesPerRow: imageWidth,
                                              space: CGColorSpaceCreateDeviceGray(),
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
                rendered = true
            }
            guard rendered else { return nil }
            width = imageWidth
            height = imageHeight
            pixels = normalized
        }

        func value(x: Int, y: Int) -> Double {
            guard x >= 0, x < width, y >= 0, y < height else { return 0 }
            return Double(pixels[y * width + x]) / 255
        }

        func localActivity(x: Int, y: Int) -> Double {
            let x1 = min(width - 1, x + 1)
            let y1 = min(height - 1, y + 1)
            let center = value(x: x, y: y)
            return max(abs(center - value(x: x1, y: y)), abs(center - value(x: x, y: y1)))
        }
    }

    enum MatchDirection { case towardStart, towardEnd }

    struct OverlapMatch {
        let overlap: Int
        let direction: MatchDirection
    }

    private struct ScoredOverlap {
        let shift: Int
        let direction: MatchDirection
        let score: Double
        let activity: Double
    }

    private static func scoreOverlap(previous: PixelSampler, next: PixelSampler,
                                     axis: Axis, shift: Int, direction: MatchDirection,
                                     cross: Int, length: Int) -> ScoredOverlap? {
        let overlap = length - shift
        guard overlap > 0 else { return nil }
        let crossStep = max(1, cross / 128)
        let alongStep = max(1, overlap / 160)
        var difference = 0.0
        var activity = 0.0
        var samples = 0

        for c in stride(from: crossStep / 2, to: cross, by: crossStep) {
            for d in stride(from: alongStep / 2, to: overlap, by: alongStep) {
                let previousPosition: Int
                let nextPosition: Int
                switch direction {
                case .towardEnd:
                    previousPosition = shift + d
                    nextPosition = d
                case .towardStart:
                    previousPosition = d
                    nextPosition = shift + d
                }
                let p1 = axis == .vertical ? (c, previousPosition) : (previousPosition, c)
                let p2 = axis == .vertical ? (c, nextPosition) : (nextPosition, c)
                difference += abs(previous.value(x: p1.0, y: p1.1) - next.value(x: p2.0, y: p2.1))
                activity += previous.localActivity(x: p1.0, y: p1.1)
                activity += next.localActivity(x: p2.0, y: p2.1)
                samples += 1
            }
        }
        guard samples > 0 else { return nil }
        let meanDifference = difference / Double(samples)
        let meanActivity = activity / Double(samples * 2)
        let normalizedError = meanDifference / max(0.02, meanActivity)
        return ScoredOverlap(shift: shift, direction: direction, score: normalizedError, activity: meanActivity)
    }

    static func bestOverlap(previous: CGImage, next: CGImage, axis: Axis) -> OverlapMatch? {
        guard let a = PixelSampler(previous), let b = PixelSampler(next) else { return nil }
        let length = axis == .vertical ? min(previous.height, next.height) : min(previous.width, next.width)
        let cross = axis == .vertical ? min(previous.width, next.width) : min(previous.height, next.height)
        if previous.width == next.width, previous.height == next.height, a.pixels == b.pixels {
            return OverlapMatch(overlap: length, direction: .towardEnd)
        }
        let minOverlap = max(16, Int(Double(length) * 0.12))
        let maxShift = length - minOverlap
        let minShift = 0
        guard maxShift >= minShift else { return nil }

        // Coarse search spans the whole legal displacement range; each promising basin is
        // refined pixel-by-pixel so slow scrolling is not rounded into a large jump.
        let coarseStep = max(2, length / 240)
        var coarse: [ScoredOverlap] = []
        for direction in [MatchDirection.towardEnd, .towardStart] {
            var shift = minShift
            while shift <= maxShift {
                if let score = scoreOverlap(previous: a, next: b, axis: axis,
                                            shift: shift, direction: direction,
                                            cross: cross, length: length) {
                    coarse.append(score)
                }
                shift += coarseStep
            }
            if (maxShift - minShift) % coarseStep != 0,
               let score = scoreOverlap(previous: a, next: b, axis: axis,
                                       shift: maxShift, direction: direction,
                                       cross: cross, length: length) {
                coarse.append(score)
            }
        }

        let basinSpacing = max(12, length / 80)
        var localMinima: [ScoredOverlap] = []
        for direction in [MatchDirection.towardEnd, .towardStart] {
            let ordered = coarse.filter { $0.direction == direction }.sorted { $0.shift < $1.shift }
            for index in ordered.indices {
                let candidate = ordered[index]
                let betterThanPrevious = index == ordered.startIndex || candidate.score <= ordered[index - 1].score
                let betterThanNext = index == ordered.index(before: ordered.endIndex) || candidate.score <= ordered[index + 1].score
                if betterThanPrevious && betterThanNext { localMinima.append(candidate) }
            }
        }
        let promising = localMinima.sorted { $0.score < $1.score }.prefix(20)

        var refined: [ScoredOverlap] = []
        for candidate in promising {
            let lower = max(minShift, candidate.shift - coarseStep)
            let upper = min(maxShift, candidate.shift + coarseStep)
            for shift in lower...upper {
                if let score = scoreOverlap(previous: a, next: b, axis: axis,
                                            shift: shift, direction: candidate.direction,
                                            cross: cross, length: length) {
                    refined.append(score)
                }
            }
        }
        let ranked = refined.sorted { $0.score < $1.score }.reduce(into: [ScoredOverlap]()) { chosen, candidate in
            guard !chosen.contains(where: { $0.direction == candidate.direction && abs($0.shift - candidate.shift) < 2 }) else { return }
            chosen.append(candidate)
        }
        guard let best = ranked.first, best.activity >= 0.006, best.score < 0.35 else { return nil }

        // A second distant match with nearly the same score usually means blank space or
        // repeated rows; refusing is safer than duplicating a page at a guessed offset.
        if ranked.dropFirst().contains(where: {
            let distinctPosition = $0.direction != best.direction || abs($0.shift - best.shift) >= basinSpacing
            return distinctPosition && $0.score <= best.score + max(0.025, best.score * 0.15)
        }) {
            return nil
        }
        return OverlapMatch(overlap: length - best.shift, direction: best.direction)
    }

}
