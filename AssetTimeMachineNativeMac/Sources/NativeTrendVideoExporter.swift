import AVFoundation
import CoreGraphics
import CoreText
import Foundation

/// Creates a trend movie only when requested; it never retains frames or market history.
enum NativeTrendVideoExporter {
    enum ExportError: LocalizedError {
        case insufficientHistory
        case writerUnavailable
        case frameUnavailable
        var errorDescription: String? {
            switch self {
            case .insufficientHistory: "至少需要两条资产记录才能生成视频"
            case .writerUnavailable: "无法创建视频文件"
            case .frameUnavailable: "无法绘制视频画面"
            }
        }
    }

    static func export(_ summaries: [TimeMachineSnapshotProjection]) async throws -> URL {
        guard summaries.count >= 2 else { throw ExportError.insufficientHistory }
        let reduced = stride(from: 0, to: summaries.count, by: max(1, summaries.count / 180)).map { summaries[$0] }
            + [summaries[summaries.count - 1]]
        let url = FileManager.default.temporaryDirectory.appending(path: "asset-trend-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = 720
        let height = 1280
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )
        guard writer.canAdd(input) else { throw ExportError.writerUnavailable }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError.writerUnavailable }
        writer.startSession(atSourceTime: .zero)
        do {
            let frames = 120
            for frame in 0..<frames {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard let pool = adaptor.pixelBufferPool else { throw ExportError.frameUnavailable }
                var pixel: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess,
                      let pixel else { throw ExportError.frameUnavailable }
                try render(reduced, progress: Double(frame + 1) / Double(frames), into: pixel,
                           width: width, height: height)
                let time = CMTime(value: Int64(frame), timescale: 20)
                guard adaptor.append(pixel, withPresentationTime: time) else {
                    throw writer.error ?? ExportError.writerUnavailable
                }
                if frame.isMultiple(of: 6) { await Task.yield() }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? ExportError.writerUnavailable }
            return url
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private static func render(
        _ source: [TimeMachineSnapshotProjection], progress: Double,
        into pixel: CVPixelBuffer, width: Int, height: Int
    ) throws {
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        guard let data = CVPixelBufferGetBaseAddress(pixel),
              let graphics = CGContext(
                data: data, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixel),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { throw ExportError.frameUnavailable }
        graphics.setFillColor(CGColor(red: 0.065, green: 0.07, blue: 0.08, alpha: 1))
        graphics.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawText("资产时光机", size: 42, color: CGColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1),
                 x: 50, y: CGFloat(height - 130), context: graphics)
        drawText("资产趋势", size: 22, color: CGColor(red: 0.60, green: 0.60, blue: 0.58, alpha: 1),
                 x: 50, y: CGFloat(height - 178), context: graphics)
        let visibleCount = max(2, Int(Double(source.count) * progress))
        let visible = source.prefix(visibleCount)
        let range = source.flatMap { [$0.totalAssets, $0.totalAssets - $0.totalLiabilities] }
        let minimum = (range.min() ?? 0) * 0.94
        let maximum = max((range.max() ?? 1) * 1.06, minimum + 1)
        let chart = CGRect(x: 52, y: 320, width: width - 104, height: 650)
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = chart.minY + chart.height * fraction
            graphics.setStrokeColor(CGColor(gray: 0.28, alpha: 0.65))
            graphics.setLineWidth(1)
            graphics.move(to: CGPoint(x: chart.minX, y: y))
            graphics.addLine(to: CGPoint(x: chart.maxX, y: y))
            graphics.strokePath()
        }
        for net in [false, true] {
            graphics.beginPath()
            for (index, entry) in visible.enumerated() {
                let value = net ? entry.totalAssets - entry.totalLiabilities : entry.totalAssets
                let point = CGPoint(
                    x: chart.minX + chart.width * Double(index) / Double(max(source.count - 1, 1)),
                    y: chart.minY + chart.height * (value - minimum) / (maximum - minimum)
                )
                if index == 0 { graphics.move(to: point) } else { graphics.addLine(to: point) }
            }
            graphics.setStrokeColor(net
                ? CGColor(red: 0.36, green: 0.75, blue: 0.53, alpha: 1)
                : CGColor(red: 0.87, green: 0.70, blue: 0.44, alpha: 1))
            graphics.setLineWidth(4)
            graphics.strokePath()
        }
        let current = visible.last!
        drawText("净资产", size: 22, color: CGColor(gray: 0.62, alpha: 1),
                 x: 52, y: 214, context: graphics)
        drawText((current.totalAssets - current.totalLiabilities).formatted(.currency(code: "CNY")),
                 size: 38, color: CGColor(red: 0.95, green: 0.94, blue: 0.91, alpha: 1),
                 x: 52, y: 165, context: graphics)
        drawText(current.date.formatted(Date.FormatStyle().year().month().day().locale(Locale(identifier: "zh_CN"))),
                 size: 20, color: CGColor(gray: 0.60, alpha: 1), x: 52, y: 114, context: graphics)
    }

    private static func drawText(_ value: String, size: CGFloat, color: CGColor,
                                 x: CGFloat, y: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("PingFangSC-Regular" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
