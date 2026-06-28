import AVFoundation
import AVKit
import CoreGraphics
import Foundation
import Photos
import SwiftUI
import UIKit

struct TrendVideoExportOptions {
    var size: CGSize = CGSize(width: 1080, height: 1920)
    var framesPerSecond: Int32 = 30
    var duration: TimeInterval = 6
}

enum TrendVideoExportError: LocalizedError {
    case insufficientData
    case cannotCreateWriter
    case cannotCreatePixelBuffer
    case writingFailed

    var errorDescription: String? {
        switch self {
        case .insufficientData:
            return AppLocalization.string("趋势数据不足，至少需要两条记录")
        case .cannotCreateWriter:
            return AppLocalization.string("视频文件创建失败")
        case .cannotCreatePixelBuffer:
            return AppLocalization.string("视频画面创建失败")
        case .writingFailed:
            return AppLocalization.string("视频写入失败")
        }
    }
}

enum TrendVideoExporter {
    static func export(
        points sourcePoints: [TimeMachineTrendPoint],
        rangeLabel: String,
        options: TrendVideoExportOptions,
        progressHandler: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        let points = evenlySampledItems(sourcePoints, maxCount: 180)
            .filter { point in
                point.mainAssets.isFinite &&
                point.netAssets.isFinite &&
                point.liabilities.isFinite
            }
        guard points.count >= 2 else { throw TrendVideoExportError.insufficientData }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("asset-trend-\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let width = Int(options.size.width)
        let height = Int(options.size.height)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        input.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height
            ]
        )

        guard writer.canAdd(input) else { throw TrendVideoExportError.cannotCreateWriter }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? TrendVideoExportError.cannotCreateWriter }
        writer.startSession(atSourceTime: .zero)

        let frameCount = max(Int(options.duration * Double(options.framesPerSecond)), 2)
        let frameDuration = CMTime(value: 1, timescale: options.framesPerSecond)
        let renderer = TrendVideoFrameRenderer(points: points, rangeLabel: rangeLabel, size: options.size)

        for frameIndex in 0..<frameCount {
            try Task.checkCancellation()

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(8))
            }

            guard let pool = adaptor.pixelBufferPool else { throw TrendVideoExportError.cannotCreatePixelBuffer }
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
                  let pixelBuffer else {
                throw TrendVideoExportError.cannotCreatePixelBuffer
            }

            let progress = Double(frameIndex + 1) / Double(frameCount)
            renderer.draw(progress: progress, into: pixelBuffer)

            let time = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw writer.error ?? TrendVideoExportError.writingFailed
            }

            if frameIndex % 3 == 0 || frameIndex == frameCount - 1 {
                progressHandler(progress)
                await Task.yield()
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? TrendVideoExportError.writingFailed
        }
        return outputURL
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct TrendVideoPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let points: [TimeMachineTrendPoint]
    let rangeLabel: String

    @State private var videoURL: URL?
    @State private var player: AVPlayer?
    @State private var exportProgress: Double = 0
    @State private var isGenerating = false
    @State private var hasStartedExport = false
    @State private var exportErrorMessage: String?
    @State private var isSaving = false
    @State private var shareURL: URL?
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                VStack(spacing: 18) {
                    videoPreviewArea

                    HStack(spacing: 12) {
                        Button {
                            Task { await saveVideoToPhotoLibrary() }
                        } label: {
                            previewActionLabel(
                                title: isSaving ? AppLocalization.string("正在保存") : AppLocalization.string("保存到相册"),
                                systemImage: "square.and.arrow.down",
                                showsProgress: isSaving
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isSaving || videoURL == nil)

                        Button {
                            shareURL = videoURL
                        } label: {
                            previewActionLabel(
                                title: AppLocalization.string("分享"),
                                systemImage: "square.and.arrow.up"
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(videoURL == nil)
                    }
                    .opacity(videoURL == nil ? 0.56 : 1)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            .navigationTitle(AppLocalization.string("视频预览"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(AppLocalization.string("完成")) {
                        dismiss()
                    }
                    .foregroundStyle(AssetTheme.gold)
                }
            }
        }
        .task {
            await generateVideoIfNeeded()
        }
        .onDisappear {
            player?.pause()
        }
        .sheet(isPresented: Binding(
            get: { shareURL != nil },
            set: { isPresented in
                if !isPresented {
                    shareURL = nil
                }
            }
        )) {
            if let shareURL {
                ActivityShareSheet(items: [shareURL])
                    .presentationDetents([.medium, .large])
            }
        }
        .alert(AppLocalization.string("视频保存"), isPresented: Binding(
            get: { statusMessage != nil },
            set: { isPresented in
                if !isPresented {
                    statusMessage = nil
                }
            }
        )) {
            Button(AppLocalization.string("知道了"), role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
    }

    private var videoPreviewArea: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
            } else {
                VStack(spacing: 16) {
                    if let exportErrorMessage {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(AssetTheme.negative)

                        Text(exportErrorMessage)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AssetTheme.textPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(3)

                        Button(AppLocalization.string("重新生成")) {
                            hasStartedExport = false
                            Task { await generateVideoIfNeeded() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AssetTheme.gold)
                    } else {
                        ProgressView(value: exportProgress)
                            .progressViewStyle(.linear)
                            .tint(AssetTheme.gold)
                            .frame(maxWidth: 260)
                            .animation(.linear(duration: 0.16), value: exportProgress)

                        Text(AppLocalization.format("%@ %.0f%%", AppLocalization.string("正在生成视频"), exportProgress * 100))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AssetTheme.textPrimary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AssetTheme.surface.opacity(0.72))
            }
        }
        .aspectRatio(9.0 / 16.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(AssetTheme.border.opacity(0.58), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.24), radius: 22, y: 12)
    }

    private func previewActionLabel(title: String, systemImage: String, showsProgress: Bool = false) -> some View {
        HStack(spacing: 8) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
                    .tint(.black.opacity(0.86))
            } else {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.bold))
            }

            Text(title)
                .font(.subheadline.weight(.bold))
                .lineLimit(1)
        }
        .foregroundStyle(Color.black.opacity(0.88))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(
            LinearGradient(
                colors: [AssetTheme.gold.opacity(0.98), AssetTheme.goldSoft.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }

    @MainActor
    private func generateVideoIfNeeded() async {
        guard !hasStartedExport, !isGenerating else { return }
        hasStartedExport = true
        isGenerating = true
        defer { isGenerating = false }
        exportProgress = 0
        exportErrorMessage = nil
        videoURL = nil
        player = nil

        do {
            let url = try await TrendVideoExporter.export(
                points: points,
                rangeLabel: rangeLabel,
                options: TrendVideoExportOptions(),
                progressHandler: { progress in
                    Task { @MainActor in
                        exportProgress = min(max(progress, 0), 1)
                    }
                }
            )
            exportProgress = 1
            videoURL = url
            let nextPlayer = AVPlayer(url: url)
            player = nextPlayer
            await nextPlayer.seek(to: .zero)
            nextPlayer.play()
        } catch is CancellationError {
            return
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func saveVideoToPhotoLibrary() async {
        guard !isSaving else { return }
        guard let videoURL else { return }
        isSaving = true
        defer { isSaving = false }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            statusMessage = AppLocalization.string("未获得相册保存权限")
            return
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }
            statusMessage = AppLocalization.string("视频已保存到相册")
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

private final class TrendVideoFrameRenderer {
    private let points: [TimeMachineTrendPoint]
    private let rangeLabel: String
    private let size: CGSize
    private let dateFormatter: DateFormatter
    private let domain: ClosedRange<Double>
    private let firstDate: Date
    private let lastDate: Date
    private let videoGold = UIColor(red: 0.96, green: 0.75, blue: 0.36, alpha: 1)
    private let videoCyan = UIColor(red: 0.35, green: 0.78, blue: 0.96, alpha: 1)
    private let videoRed = UIColor(red: 0.96, green: 0.39, blue: 0.43, alpha: 1)
    private let videoTextPrimary = UIColor(red: 0.95, green: 0.95, blue: 0.93, alpha: 1)
    private let videoTextSecondary = UIColor(red: 0.58, green: 0.62, blue: 0.70, alpha: 1)

    init(points: [TimeMachineTrendPoint], rangeLabel: String, size: CGSize) {
        self.points = points
        self.rangeLabel = rangeLabel
        self.size = size
        self.firstDate = points.first?.date ?? Date()
        self.lastDate = points.last?.date ?? Date()
        self.domain = Self.makeDomain(points: points)

        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = AppLocalization.currentLocale
        formatter.dateFormat = AppLocalization.string("yyyy年M月d日")
        self.dateFormatter = formatter
    }

    func draw(progress: Double, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let context = CGContext(
                data: baseAddress,
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
        else { return }

        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }

        // Pixel buffers use a lower-left origin; UIKit drawing expects a top-left origin.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        let rect = CGRect(origin: .zero, size: size)
        drawBackground(in: rect)
        let index = visibleEndIndex(progress: progress)
        let point = points[index]
        drawHeader(point: point)
        drawDateWatermark(point: point)
        drawChart(progress: progress)
        drawBottomPanels(point: point)
        drawFooter()
    }

    private func drawBackground(in rect: CGRect) {
        let colors = [
            UIColor(red: 0.015, green: 0.022, blue: 0.045, alpha: 1).cgColor,
            UIColor(red: 0.028, green: 0.046, blue: 0.075, alpha: 1).cgColor,
            UIColor(red: 0.010, green: 0.012, blue: 0.024, alpha: 1).cgColor
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1])
        UIGraphicsGetCurrentContext()?.drawLinearGradient(
            gradient!,
            start: CGPoint(x: rect.minX, y: rect.minY),
            end: CGPoint(x: rect.maxX, y: rect.maxY * 0.78),
            options: []
        )

        UIColor(red: 0.93, green: 0.77, blue: 0.45, alpha: 0.04).setFill()
        UIBezierPath(ovalIn: CGRect(x: -240, y: 520, width: 640, height: 720)).fill()
        UIColor(red: 0.19, green: 0.55, blue: 0.86, alpha: 0.05).setFill()
        UIBezierPath(ovalIn: CGRect(x: 720, y: 300, width: 520, height: 720)).fill()
    }

    private func drawHeader(point: TimeMachineTrendPoint) {
        drawText(
            AppLocalization.string("资产时光机"),
            in: CGRect(x: 54, y: 104, width: size.width - 108, height: 42),
            font: .systemFont(ofSize: 30, weight: .semibold),
            color: videoGold
        )
        drawText(
            AppLocalization.string("财富走势回放"),
            in: CGRect(x: 54, y: 152, width: size.width - 108, height: 86),
            font: .systemFont(ofSize: 62, weight: .bold),
            color: videoTextPrimary
        )
        drawText(
            "\(rangeLabel) · \(dateFormatter.string(from: point.date))",
            in: CGRect(x: 54, y: 244, width: size.width - 108, height: 42),
            font: .systemFont(ofSize: 27, weight: .medium),
            color: videoTextSecondary
        )

        drawLegend(in: CGRect(x: 56, y: 360, width: 560, height: 42))
    }

    private func drawDateWatermark(point: TimeMachineTrendPoint) {
        let year = Calendar.current.component(.year, from: point.date)
        drawText(
            "\(year)",
            in: CGRect(x: 690, y: 318, width: 330, height: 100),
            font: .monospacedDigitSystemFont(ofSize: 86, weight: .thin),
            color: videoTextPrimary.withAlphaComponent(0.12),
            alignment: .right
        )
        drawText(
            point.date.shortDateString,
            in: CGRect(x: 780, y: 414, width: 240, height: 48),
            font: .monospacedDigitSystemFont(ofSize: 38, weight: .light),
            color: videoTextPrimary.withAlphaComponent(0.16),
            alignment: .right
        )
    }

    private func drawChart(progress: Double) {
        let plotRect = CGRect(x: 74, y: 512, width: size.width - 148, height: 648)
        drawGrid(in: plotRect)

        let visibleCount = max(2, Int((Double(points.count - 1) * progress).rounded()) + 1)
        let visiblePoints = Array(points.prefix(visibleCount))

        drawSeries(.mainAssets, points: visiblePoints, in: plotRect, dashed: false)
        drawSeries(.netAssets, points: visiblePoints, in: plotRect, dashed: false)
        drawSeries(.liabilities, points: visiblePoints, in: plotRect, dashed: true)

        if let point = visiblePoints.last {
            drawCurrentMarker(point: point, in: plotRect)
        }

        drawAxisLabels(in: plotRect)
    }

    private func drawGrid(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.075).cgColor)
        context.setLineWidth(1.2)

        for step in 0...4 {
            let y = rect.minY + rect.height * CGFloat(step) / 4
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        for step in 0...4 {
            let x = rect.minX + rect.width * CGFloat(step) / 4
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawSeries(_ series: TimeMachineAssetSeries, points: [TimeMachineTrendPoint], in rect: CGRect, dashed: Bool) {
        guard points.count >= 2, let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.setStrokeColor(uiColor(for: series).cgColor)
        context.setLineWidth(series == .liabilities ? 5 : 6.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        if dashed {
            context.setLineDash(phase: 0, lengths: [18, 15])
        }

        for (index, point) in points.enumerated() {
            let cgPoint = chartPoint(for: point, series: series, in: rect)
            if index == 0 {
                context.move(to: cgPoint)
            } else {
                context.addLine(to: cgPoint)
            }
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawCurrentMarker(point: TimeMachineTrendPoint, in rect: CGRect) {
        let markerPoint = chartPoint(for: point, series: .netAssets, in: rect)
        let outer = CGRect(x: markerPoint.x - 18, y: markerPoint.y - 18, width: 36, height: 36)
        let inner = CGRect(x: markerPoint.x - 7, y: markerPoint.y - 7, width: 14, height: 14)
        videoCyan.withAlphaComponent(0.18).setFill()
        UIBezierPath(ovalIn: outer).fill()
        videoCyan.setFill()
        UIBezierPath(ovalIn: inner).fill()
    }

    private func drawLegend(in rect: CGRect) {
        let items: [(TimeMachineAssetSeries, Bool)] = [(.mainAssets, false), (.netAssets, false), (.liabilities, true)]
        let itemWidth = rect.width / CGFloat(items.count)
        for (index, item) in items.enumerated() {
            let x = rect.minX + CGFloat(index) * itemWidth
            let color = uiColor(for: item.0)
            color.setFill()
            if item.1 {
                for dash in 0..<3 {
                    UIBezierPath(roundedRect: CGRect(x: x + CGFloat(dash) * 17, y: rect.midY - 3, width: 11, height: 5), cornerRadius: 3).fill()
                }
            } else {
                UIBezierPath(roundedRect: CGRect(x: x, y: rect.midY - 3, width: 42, height: 5), cornerRadius: 3).fill()
            }
            drawText(
                item.0.title,
                in: CGRect(x: x + 56, y: rect.minY - 1, width: itemWidth - 62, height: rect.height),
                font: .systemFont(ofSize: 24, weight: .semibold),
                color: videoTextSecondary
            )
        }
    }

    private func drawAxisLabels(in rect: CGRect) {
        let upper = domain.upperBound.currencyString()
        let middle = ((domain.lowerBound + domain.upperBound) / 2).currencyString()
        let lower = domain.lowerBound.currencyString()
        drawText(upper, in: CGRect(x: rect.minX, y: rect.minY - 38, width: 260, height: 30), font: .systemFont(ofSize: 21, weight: .medium), color: videoTextSecondary.withAlphaComponent(0.84))
        drawText(middle, in: CGRect(x: rect.minX, y: rect.midY - 16, width: 260, height: 30), font: .systemFont(ofSize: 20, weight: .medium), color: videoTextSecondary.withAlphaComponent(0.7))
        drawText(lower, in: CGRect(x: rect.minX, y: rect.maxY + 8, width: 260, height: 30), font: .systemFont(ofSize: 20, weight: .medium), color: videoTextSecondary.withAlphaComponent(0.72))
        drawText(firstDate.shortDateString, in: CGRect(x: rect.minX, y: rect.maxY + 44, width: 220, height: 30), font: .systemFont(ofSize: 20, weight: .medium), color: videoTextSecondary)
        drawText(lastDate.shortDateString, in: CGRect(x: rect.maxX - 220, y: rect.maxY + 44, width: 220, height: 30), font: .systemFont(ofSize: 20, weight: .medium), color: videoTextSecondary, alignment: .right)
    }

    private func drawBottomPanels(point: TimeMachineTrendPoint) {
        let first = points.first ?? point
        let panelX: CGFloat = 34
        let panelWidth = size.width - panelX * 2
        let panelHeight: CGFloat = 144
        let gap: CGFloat = 14
        let startY: CGFloat = 1288

        drawValuePanel(
            title: AppLocalization.string("总资产"),
            value: point.mainAssets.currencyString(),
            delta: deltaDescription(current: point.mainAssets, baseline: first.mainAssets),
            color: videoGold,
            frame: CGRect(x: panelX, y: startY, width: panelWidth, height: panelHeight)
        )
        drawValuePanel(
            title: AppLocalization.string("净资产"),
            value: point.netAssets.currencyString(),
            delta: deltaDescription(current: point.netAssets, baseline: first.netAssets),
            color: videoCyan,
            frame: CGRect(x: panelX, y: startY + panelHeight + gap, width: panelWidth, height: panelHeight)
        )
        drawValuePanel(
            title: AppLocalization.string("总负债"),
            value: point.liabilities.currencyString(),
            delta: deltaDescription(current: point.liabilities, baseline: first.liabilities),
            color: videoRed,
            frame: CGRect(x: panelX, y: startY + (panelHeight + gap) * 2, width: panelWidth, height: panelHeight)
        )
    }

    private func drawValuePanel(title: String, value: String, delta: String, color: UIColor, frame: CGRect) {
        let path = UIBezierPath(roundedRect: frame, cornerRadius: 20)
        UIColor(red: 0.035, green: 0.055, blue: 0.090, alpha: 0.82).setFill()
        path.fill()
        color.withAlphaComponent(0.88).setStroke()
        path.lineWidth = 2
        path.stroke()

        drawText(
            title,
            in: CGRect(x: frame.minX + 34, y: frame.minY + 36, width: 300, height: 44),
            font: .systemFont(ofSize: 34, weight: .bold),
            color: color
        )
        drawText(
            value,
            in: CGRect(x: frame.midX - 40, y: frame.minY + 25, width: frame.width / 2 + 2, height: 64),
            font: .monospacedDigitSystemFont(ofSize: 50, weight: .medium),
            color: videoTextPrimary,
            alignment: .right
        )
        drawText(
            delta,
            in: CGRect(x: frame.midX - 40, y: frame.minY + 90, width: frame.width / 2 + 2, height: 34),
            font: .systemFont(ofSize: 25, weight: .medium),
            color: videoTextSecondary,
            alignment: .right
        )
    }

    private func drawFooter() {
        drawText(
            AppLocalization.string("由资产时光机生成"),
            in: CGRect(x: 72, y: size.height - 96, width: size.width - 144, height: 32),
            font: .systemFont(ofSize: 23, weight: .medium),
            color: videoTextSecondary.withAlphaComponent(0.72),
            alignment: .center
        )
    }

    private func drawText(_ text: String, in rect: CGRect, font: UIFont, color: UIColor, alignment: NSTextAlignment = .left) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func deltaDescription(current: Double, baseline: Double) -> String {
        let delta = current - baseline
        let percentage: Double
        if abs(baseline) > 0.0001 {
            percentage = delta / abs(baseline)
        } else {
            percentage = 0
        }

        let sign = delta >= 0 ? "+" : "-"
        let amount = abs(delta).currencyString()
        let percent = String(format: "%.1f%%", abs(percentage) * 100)
        return AppLocalization.format("变化 %@%@ / %@", sign, amount, percent)
    }

    private func visibleEndIndex(progress: Double) -> Int {
        min(points.count - 1, max(0, Int((Double(points.count - 1) * progress).rounded())))
    }

    private func chartPoint(for point: TimeMachineTrendPoint, series: TimeMachineAssetSeries, in rect: CGRect) -> CGPoint {
        let dateSpan = max(lastDate.timeIntervalSince(firstDate), 1)
        let xRatio = point.date.timeIntervalSince(firstDate) / dateSpan
        let value = series.value(from: point)
        let yRatio = (value - domain.lowerBound) / max(domain.upperBound - domain.lowerBound, 1)
        return CGPoint(
            x: rect.minX + CGFloat(xRatio) * rect.width,
            y: rect.maxY - CGFloat(yRatio) * rect.height
        )
    }

    private func uiColor(for series: TimeMachineAssetSeries) -> UIColor {
        switch series {
        case .mainAssets:
            return videoGold
        case .netAssets:
            return videoCyan
        case .liabilities:
            return videoRed
        }
    }

    private static func makeDomain(points: [TimeMachineTrendPoint]) -> ClosedRange<Double> {
        let values = points.flatMap { point in
            [point.mainAssets, point.netAssets, point.liabilities]
        }
        guard let minValue = values.min(), let maxValue = values.max(), minValue < maxValue else {
            let value = values.first ?? 0
            let padding = max(abs(value) * 0.12, 1)
            return (value - padding)...(value + padding)
        }
        let padding = max((maxValue - minValue) * 0.12, abs(maxValue) * 0.02, 1)
        return (minValue - padding)...(maxValue + padding)
    }
}

private extension UIBezierPath {
    func fill(color: UIColor) {
        color.setFill()
        fill()
    }
}
