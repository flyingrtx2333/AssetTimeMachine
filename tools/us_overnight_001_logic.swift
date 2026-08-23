import Foundation

nonisolated enum USOvernight001Logic {
    /// Adjust a previous-session USD close so that, after the existing backtest
    /// preparer applies the *current* session FX multiplier to the synthetic bar,
    /// the synthetic open is exactly the previous close valued at the previous FX.
    static func fxAdjustedSyntheticOpen(
        previousClose: Double,
        previousCNYMultiplier: Double,
        currentCNYMultiplier: Double
    ) -> Double? {
        guard previousClose.isFinite, previousClose > 0,
              previousCNYMultiplier.isFinite, previousCNYMultiplier > 0,
              currentCNYMultiplier.isFinite, currentCNYMultiplier > 0 else { return nil }
        let adjusted = previousClose * previousCNYMultiplier / currentCNYMultiplier
        return adjusted.isFinite && adjusted > 0 ? adjusted : nil
    }

    static func syntheticHighLow(open: Double, close: Double) -> (high: Double, low: Double)? {
        guard open.isFinite, close.isFinite, open > 0, close > 0 else { return nil }
        return (max(open, close), min(open, close))
    }
}
