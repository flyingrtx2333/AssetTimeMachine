import AppKit
import Foundation
import SwiftUI

enum MacMemoryRelief {
    static func scheduleAfterHeavyOperation() {}
}

// Presentation adapters for shared backtest models; native charts live in NativeQuantView.
enum BacktestChartValueStyle: Equatable {
    case multiple
    case currency(code: String)
}

struct BacktestChartComparisonSeries: Identifiable {
    let id: String
    let title: String
    let points: [BacktestSeriesPoint]
    let color: Color
}

enum AdvancedBacktestPresentation {
    nonisolated static func comparisonSeries(from report: AdvancedBacktestReport) -> [BacktestChartComparisonSeries] {
        report.benchmarkSeries.enumerated().compactMap { index, series in
            guard let first = series.points.first?.portfolioValue, first > 0,
                  let start = report.points.first?.portfolioValue else { return nil }
            return BacktestChartComparisonSeries(id: series.id, title: series.title,
                points: series.points.map { .init(date: $0.date, portfolioValue: $0.portfolioValue / first * start, sequence: $0.id) },
                color: [AssetTheme.accentBlue, AssetTheme.gold, AssetTheme.positive][index % 3])
        }
    }
}

enum AppTypography {
    static let meta = Font.system(size: 11)
    static let chartAxisStrip = Font.system(size: 11).monospacedDigit()
}

/// End native text editing on outside clicks without consuming buttons or other text fields.
struct NativeOutsideClickDismissal: NSViewRepresentable {
    func makeNSView(context: Context) -> DismissalView { DismissalView() }
    func updateNSView(_ nsView: DismissalView, context: Context) {}
    static func dismantleNSView(_ nsView: DismissalView, coordinator: ()) { nsView.stopMonitoring() }

    final class DismissalView: NSView {
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let window = self?.window, event.window === window,
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                      let content = window.contentView else { return event }
                var hit = content.hitTest(content.convert(event.locationInWindow, from: nil))
                while let view = hit {
                    if let field = view as? NSTextField, field.isEditable { return event }
                    if let text = view as? NSTextView, text.isEditable { return event }
                    hit = view.superview
                }
                window.makeFirstResponder(nil)
                return event
            }
        }
        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
