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

struct LocalFileExportPicker: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
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
    @State private var showsExportPanel = false
    @State private var localExportURL: URL?
    @State private var shareURL: URL?
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                AssetTheme.pageGradient.ignoresSafeArea()

                GeometryReader { geometry in
                    ZStack(alignment: .bottom) {
                        VStack(spacing: 0) {
                            videoPreviewArea
                                .frame(maxHeight: min(geometry.size.height * 0.79, 660))

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 12)

                        if showsExportPanel {
                            exportPanel
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            exportTriggerButton
                                .padding(.horizontal, 22)
                                .padding(.bottom, 18)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
            }
            .navigationTitle(AppLocalization.string("预览走势视频"))
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
            get: { localExportURL != nil },
            set: { isPresented in
                if !isPresented {
                    localExportURL = nil
                }
            }
        )) {
            if let localExportURL {
                LocalFileExportPicker(url: localExportURL)
            }
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

    private var exportTriggerButton: some View {
        Button {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                showsExportPanel = true
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .semibold))

                Text(AppLocalization.string("导出视频"))
                    .font(.system(size: 16, weight: .bold))

                Spacer(minLength: 8)

                Image(systemName: "chevron.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.48))
            }
            .foregroundStyle(Color.black.opacity(0.86))
            .padding(.horizontal, 18)
            .frame(height: 54)
            .background(
                LinearGradient(
                    colors: [AssetTheme.goldSoft, AssetTheme.gold.opacity(0.92)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 18, y: 9)
        }
        .buttonStyle(.plain)
        .disabled(videoURL == nil)
        .opacity(videoURL == nil ? 0.56 : 1)
        .accessibilityLabel(AppLocalization.string("导出视频"))
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                    showsExportPanel = false
                }
            } label: {
                VStack(spacing: 8) {
                    Capsule()
                        .fill(Color.black.opacity(0.13))
                        .frame(width: 42, height: 5)

                    HStack {
                        Text(AppLocalization.string("导出视频"))
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.black.opacity(0.52))

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.38))
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(AppLocalization.string("收起导出选项"))

            VStack(spacing: 0) {
                exportActionRow(
                    title: AppLocalization.string("保存到本地"),
                    systemImage: "tray.and.arrow.down.fill",
                    isProminent: true
                ) {
                    localExportURL = videoURL
                }

                Divider()
                    .overlay(Color.black.opacity(0.07))
                    .padding(.leading, 62)

                exportActionRow(
                    title: isSaving ? AppLocalization.string("正在保存") : AppLocalization.string("保存到相册"),
                    systemImage: "photo",
                    showsProgress: isSaving
                ) {
                    Task { await saveVideoToPhotoLibrary() }
                }

                Divider()
                    .overlay(Color.black.opacity(0.07))
                    .padding(.leading, 62)

                exportActionRow(
                    title: AppLocalization.string("用其他应用打开"),
                    systemImage: "square.and.arrow.up",
                    showsDisclosure: true
                ) {
                    shareURL = videoURL
                }
            }
            .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 30, topTrailing: 30),
                style: .continuous
            )
            .fill(Color(red: 0.94, green: 0.93, blue: 0.91))
            .shadow(color: Color.black.opacity(0.26), radius: 26, y: -10)
        }
        .opacity(videoURL == nil ? 0.72 : 1)
        .gesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    guard value.translation.height > 34 else { return }
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                        showsExportPanel = false
                    }
                }
        )
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

    private func exportActionRow(
        title: String,
        systemImage: String,
        isProminent: Bool = false,
        showsProgress: Bool = false,
        showsDisclosure: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(isProminent ? AssetTheme.gold.opacity(0.14) : Color.black.opacity(0.045))

                    if showsProgress {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.black.opacity(0.76))
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isProminent ? Color(red: 0.43, green: 0.29, blue: 0.10) : Color.black.opacity(0.72))
                    }
                }
                .frame(width: 42, height: 42)

                Text(title)
                    .font(.system(size: 17, weight: isProminent ? .bold : .medium))
                    .foregroundStyle(Color.black.opacity(0.86))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.black.opacity(0.36))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(videoURL == nil || (showsProgress && isSaving))
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
        drawChart(progress: progress)
        drawBottomSummary(point: point)
        drawFooter()
    }

    private func drawBackground(in rect: CGRect) {
        if let backgroundImage = UIImage(named: "trend_video_background") {
            let imageSize = backgroundImage.size
            let scale = max(rect.width / max(imageSize.width, 1), rect.height / max(imageSize.height, 1))
            let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let drawRect = CGRect(
                x: rect.midX - drawSize.width / 2,
                y: rect.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            backgroundImage.draw(in: drawRect)

            UIColor.black.withAlphaComponent(0.12).setFill()
            UIBezierPath(rect: rect).fill()

            if let context = UIGraphicsGetCurrentContext() {
                let readabilityColors = [
                    UIColor.black.withAlphaComponent(0.18).cgColor,
                    UIColor.clear.cgColor,
                    UIColor.black.withAlphaComponent(0.26).cgColor
                ] as CFArray
                if let readabilityGradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: readabilityColors,
                    locations: [0, 0.5, 1]
                ) {
                    context.drawLinearGradient(
                        readabilityGradient,
                        start: CGPoint(x: rect.midX, y: rect.minY),
                        end: CGPoint(x: rect.midX, y: rect.maxY),
                        options: []
                    )
                }
            }
            return
        }

        let colors = [
            UIColor(red: 0.018, green: 0.022, blue: 0.032, alpha: 1).cgColor,
            UIColor(red: 0.028, green: 0.041, blue: 0.061, alpha: 1).cgColor,
            UIColor(red: 0.010, green: 0.012, blue: 0.018, alpha: 1).cgColor
        ] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.45, 1])
        UIGraphicsGetCurrentContext()?.drawLinearGradient(
            gradient!,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )

        guard let context = UIGraphicsGetCurrentContext() else { return }
        let spotlightColors = [
            UIColor.white.withAlphaComponent(0.065).cgColor,
            UIColor.clear.cgColor
        ] as CFArray
        if let spotlight = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: spotlightColors, locations: [0, 1]) {
            context.drawRadialGradient(
                spotlight,
                startCenter: CGPoint(x: rect.midX, y: 300),
                startRadius: 0,
                endCenter: CGPoint(x: rect.midX, y: 300),
                endRadius: 390,
                options: [.drawsAfterEndLocation]
            )
        }
    }

    private func drawHeader(point: TimeMachineTrendPoint) {
        drawText(
            AppLocalization.string("净资产"),
            in: CGRect(x: 80, y: 158, width: size.width - 160, height: 50),
            font: .systemFont(ofSize: 36, weight: .medium),
            color: videoTextSecondary,
            alignment: .center
        )
        drawText(
            point.netAssets.currencyString(),
            in: CGRect(x: 36, y: 216, width: size.width - 72, height: 114),
            font: .monospacedDigitSystemFont(ofSize: 84, weight: .semibold),
            color: videoGold,
            alignment: .center
        )

        videoGold.withAlphaComponent(0.32).setFill()
        UIBezierPath(roundedRect: CGRect(x: size.width / 2 - 30, y: 350, width: 60, height: 2), cornerRadius: 1).fill()

        drawText(
            AppLocalization.string("财富走势回放"),
            in: CGRect(x: 80, y: 386, width: size.width - 160, height: 56),
            font: .systemFont(ofSize: 42, weight: .semibold),
            color: videoTextPrimary,
            alignment: .center
        )
        drawText(
            rangeLabel,
            in: CGRect(x: 80, y: 448, width: size.width - 160, height: 44),
            font: .systemFont(ofSize: 30, weight: .medium),
            color: videoTextSecondary,
            alignment: .center
        )
    }

    private func drawChart(progress: Double) {
        let plotRect = CGRect(x: 92, y: 704, width: size.width - 184, height: 630)
        drawGrid(in: plotRect)

        let visibleCount = max(2, Int((Double(points.count - 1) * progress).rounded()) + 1)
        let visiblePoints = Array(points.prefix(visibleCount))

        drawSeries(.mainAssets, points: visiblePoints, in: plotRect, dashed: false)
        drawSeries(.netAssets, points: visiblePoints, in: plotRect, dashed: false)
        drawSeries(.liabilities, points: visiblePoints, in: plotRect, dashed: true)

        if let point = visiblePoints.last {
            drawCurrentMarkers(point: point, in: plotRect)
        }

        drawAxisLabels(in: plotRect)
    }

    private func drawGrid(in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.setStrokeColor(UIColor.white.withAlphaComponent(0.065).cgColor)
        context.setLineWidth(1.2)

        for step in 0...4 {
            let y = rect.minY + rect.height * CGFloat(step) / 4
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }

        context.setLineDash(phase: 0, lengths: [5, 10])
        for step in 0...3 {
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
        context.setLineWidth(series == .liabilities ? 4.2 : 6.5)
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

    private func drawCurrentMarkers(point: TimeMachineTrendPoint, in rect: CGRect) {
        for series in TimeMachineAssetSeries.allCases {
            let markerPoint = chartPoint(for: point, series: series, in: rect)
            let color = uiColor(for: series)
            let outer = CGRect(x: markerPoint.x - 15, y: markerPoint.y - 15, width: 30, height: 30)
            let inner = CGRect(x: markerPoint.x - 6, y: markerPoint.y - 6, width: 12, height: 12)
            color.withAlphaComponent(0.16).setFill()
            UIBezierPath(ovalIn: outer).fill()
            color.setFill()
            UIBezierPath(ovalIn: inner).fill()
        }
    }

    private func drawAxisLabels(in rect: CGRect) {
        let upper = domain.upperBound.currencyString()
        let middle = ((domain.lowerBound + domain.upperBound) / 2).currencyString()
        let lower = domain.lowerBound.currencyString()
        drawText(upper, in: CGRect(x: rect.maxX - 250, y: rect.minY - 34, width: 250, height: 30), font: .systemFont(ofSize: 21, weight: .medium), color: videoTextSecondary.withAlphaComponent(0.82), alignment: .right)
        drawText(middle, in: CGRect(x: rect.maxX - 250, y: rect.midY - 16, width: 250, height: 30), font: .systemFont(ofSize: 20, weight: .medium), color: videoTextSecondary.withAlphaComponent(0.68), alignment: .right)
        drawText(lower, in: CGRect(x: rect.maxX - 250, y: rect.maxY - 26, width: 250, height: 30), font: .systemFont(ofSize: 20, weight: .medium), color: videoTextSecondary.withAlphaComponent(0.70), alignment: .right)
        drawText(firstDate.shortDateString, in: CGRect(x: rect.minX, y: rect.maxY + 32, width: 220, height: 32), font: .systemFont(ofSize: 21, weight: .medium), color: videoGold.withAlphaComponent(0.76))

        let midpointDate = firstDate.addingTimeInterval(lastDate.timeIntervalSince(firstDate) / 2)
        drawText(midpointDate.shortDateString, in: CGRect(x: rect.midX - 110, y: rect.maxY + 32, width: 220, height: 32), font: .systemFont(ofSize: 21, weight: .medium), color: videoTextSecondary, alignment: .center)
        drawText(lastDate.shortDateString, in: CGRect(x: rect.maxX - 220, y: rect.maxY + 32, width: 220, height: 32), font: .systemFont(ofSize: 21, weight: .medium), color: videoGold.withAlphaComponent(0.82), alignment: .right)
    }

    private func drawBottomSummary(point: TimeMachineTrendPoint) {
        let items: [(String, Double, UIColor)] = [
            (AppLocalization.string("总资产"), point.mainAssets, videoGold),
            (AppLocalization.string("净资产"), point.netAssets, videoCyan),
            (AppLocalization.string("总负债"), point.liabilities, videoRed)
        ]
        let startX: CGFloat = 70
        let availableWidth = size.width - startX * 2
        let columnWidth = availableWidth / CGFloat(items.count)
        let titleY: CGFloat = 1458
        let valueY: CGFloat = 1510

        for (index, item) in items.enumerated() {
            let x = startX + CGFloat(index) * columnWidth
            item.2.setFill()
            UIBezierPath(ovalIn: CGRect(x: x, y: titleY + 12, width: 10, height: 10)).fill()
            drawText(
                item.0,
                in: CGRect(x: x + 22, y: titleY, width: columnWidth - 28, height: 38),
                font: .systemFont(ofSize: 25, weight: .medium),
                color: videoTextSecondary
            )
            drawText(
                item.1.currencyString(),
                in: CGRect(x: x, y: valueY, width: columnWidth - 20, height: 48),
                font: .monospacedDigitSystemFont(ofSize: 29, weight: .medium),
                color: item.2
            )
        }
    }

    private func drawFooter() {
        let logoSize: CGFloat = 44
        let brandWidth: CGFloat = 218
        let brandX = (size.width - brandWidth) / 2
        let logoFrame = CGRect(x: brandX, y: size.height - 94, width: logoSize, height: logoSize)

        if let logoImage = UIImage(named: "brand_logo"), let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            UIBezierPath(roundedRect: logoFrame, cornerRadius: 10).addClip()
            logoImage.draw(in: logoFrame)
            context.restoreGState()
        }

        drawText(
            AppLocalization.string("资产时光机"),
            in: CGRect(x: logoFrame.maxX + 12, y: size.height - 89, width: brandWidth - logoSize - 12, height: 34),
            font: .systemFont(ofSize: 24, weight: .semibold),
            color: videoGold.withAlphaComponent(0.74)
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
