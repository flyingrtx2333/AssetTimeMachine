#if targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

struct MacWindowConfiguration: UIViewRepresentable {
    func makeUIView(context: Context) -> WindowObserver {
        let observer = WindowObserver()
        observer.isUserInteractionEnabled = false
        return observer
    }
    func updateUIView(_ uiView: WindowObserver, context: Context) {}

    #if DEBUG
    @MainActor
    static func capture(to path: String) {
        let windows = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first(where: { !$0.isHidden }) else { return }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        window.layoutIfNeeded()
        for y in [120.0, 155.0, 190.0, 225.0, 260.0] {
            let target = window.hitTest(CGPoint(x: 60, y: y), with: nil)
            let viewType = target.map { String(describing: type(of: $0)).prefix(32) } ?? "none"
            NSLog("[MacHitTest] sidebar y=\(y): \(viewType)")
        }
        let image = renderer.image { context in
            window.layer.render(in: context.cgContext)
        }
        do {
            try image.pngData()?.write(to: URL(fileURLWithPath: path))
            NSLog("[MacPreview] captured \(window.bounds.size) at \(path)")
        } catch {
            NSLog("[MacPreview] capture failed: \(error)")
        }
    }
    #endif

    final class WindowObserver: UIView {
        private var configured = false
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard !configured, let scene = window?.windowScene else { return }
            configured = true
            scene.sizeRestrictions?.minimumSize = CGSize(width: 820, height: 560)
            scene.titlebar?.titleVisibility = .hidden
            var preferredSize = CGSize(width: 920, height: 640)
            #if DEBUG
            if AppPreviewSession.isActive {
                preferredSize = CGSize(width: max(820, argument("-macWidth").flatMap(Double.init) ?? 920),
                                       height: max(560, argument("-macHeight").flatMap(Double.init) ?? 640))
            }
            #endif
            let initialSize = preferredSize
            Task { @MainActor in
                // Scene restoration happens after didMoveToWindow. Apply first-launch size once active.
                for _ in 0..<40 {
                    if scene.activationState == .foregroundActive { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let defaults = UserDefaults.standard
                if AppPreviewSession.isActive || !defaults.bool(forKey: "mac.window.compactSizeApplied") {
                    let previousMaximum = scene.sizeRestrictions?.maximumSize
                    scene.sizeRestrictions?.maximumSize = initialSize
                    scene.requestGeometryUpdate(.Mac(systemFrame: CGRect(x: 100, y: 80, width: initialSize.width, height: initialSize.height + 28))) { error in
                        NSLog("[MacWindow] resize: \(error)")
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                    if let previousMaximum { scene.sizeRestrictions?.maximumSize = previousMaximum }
                    if !AppPreviewSession.isActive { defaults.set(true, forKey: "mac.window.compactSizeApplied") }
                }
            }
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("-macPreview") else { return }
            if let path = argument("-macCapturePath") {
                Task { @MainActor [weak self] in
                    for _ in 0..<120 {
                        if AppPreviewSession.didFinishStartup { break }
                        try? await Task.sleep(for: .milliseconds(500))
                    }
                    let captureDelay = max(0, Double(self?.argument("-macCaptureDelaySeconds") ?? "5") ?? 5)
                    try? await Task.sleep(for: .seconds(captureDelay))
                    guard self?.window != nil else { return }
                    MacWindowConfiguration.capture(to: path)
                }
            }
            #endif
        }
        #if DEBUG
        private func argument(_ flag: String) -> String? {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        #endif
    }
}
#endif
