import Foundation

nonisolated struct ChinaUSRelay001Bar {
    let close: Double
}

nonisolated enum ChinaUSRelay001Logic {
    /// The China cash session closes before the U.S. cash session opens on the same
    /// calendar date. A risk-on signal is therefore causal for a U.S. open entry when
    /// both same-date China closes have already completed and both rose from their
    /// immediately preceding real sessions.
    static func chinaRiskOn(
        csi300: [ChinaUSRelay001Bar],
        csiIndex: Int,
        shanghai: [ChinaUSRelay001Bar],
        shanghaiIndex: Int
    ) -> Bool? {
        guard csi300.indices.contains(csiIndex),
              shanghai.indices.contains(shanghaiIndex),
              csiIndex > 0,
              shanghaiIndex > 0 else { return nil }
        let csiCurrent = csi300[csiIndex].close
        let csiPrevious = csi300[csiIndex - 1].close
        let shCurrent = shanghai[shanghaiIndex].close
        let shPrevious = shanghai[shanghaiIndex - 1].close
        guard [csiCurrent, csiPrevious, shCurrent, shPrevious].allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return nil
        }
        return csiCurrent > csiPrevious && shCurrent > shPrevious
    }
}
