import Foundation

nonisolated enum RecentWindowFrozenCandidateSchedules {
    private struct Spec {
        let file: String
        let expectedRows: Int
    }

    private static let targetSymbols = [
        "gold_cny", RecentWindowOverlayStrategy.moneySymbol,
        "sp500", RecentWindowOverlayStrategy.spySymbol,
        "nasdaq", RecentWindowOverlayStrategy.oneqSymbol,
        "shanghai_composite", RecentWindowOverlayStrategy.sseETFSymbol,
        "csi300", RecentWindowOverlayStrategy.csiETFSymbol,
    ]

    static func load(mode: RecentWindowOverlayStrategy.Mode, executionDates: [Date]) -> FrozenTargetSchedule? {
        let spec: Spec
        switch mode {
        case .volatilityManagedIdleCash:
            spec = Spec(file: "volatility-targets", expectedRows: 2266)
        case .pairSpreadZ252Shift25:
            spec = Spec(file: "pair-targets", expectedRows: 525)
        case .goldEquityRelativeZ252Shift25:
            spec = Spec(file: "gold-equity-targets", expectedRows: 522)
        }
        guard let url = resourceURL(named: spec.file),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        guard let headerLine = lines.first else { return nil }
        let headers = headerLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let column = Dictionary(uniqueKeysWithValues: headers.enumerated().map { ($1, $0) })
        guard let dateColumn = column["date"] else { return nil }
        let executionDateTexts = executionDates.map(\.backtestDateString)
        var eventBySignalIndex: [Int: FrozenTargetEvent] = [:]
        var processedRows = 0
        var previousDate = ""
        for line in lines.dropFirst() {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.indices.contains(dateColumn) else { return nil }
            let dateText = fields[dateColumn]
            guard dateText > previousDate else { return nil }
            var low = 0
            var high = executionDateTexts.count
            while low < high {
                let mid = (low + high) / 2
                if executionDateTexts[mid] < dateText { low = mid + 1 } else { high = mid }
            }
            let executionIndex = low
            guard executionDates.indices.contains(executionIndex), executionIndex > 0 else { return nil }
            var target: [String: Double] = [:]
            for symbol in targetSymbols {
                guard let index = column[symbol], fields.indices.contains(index),
                      let weight = Double(fields[index]), weight.isFinite, weight >= -1e-10 else { continue }
                target[symbol] = max(weight, 0)
            }
            let gross = target.values.reduce(0, +)
            guard !target.isEmpty, gross.isFinite, gross >= 0 else { return nil }
            if gross > 1 { target = target.mapValues { $0 / gross } }
            func signal(_ name: String) -> String? {
                guard let index = column[name], fields.indices.contains(index), !fields[index].isEmpty else { return nil }
                return fields[index]
            }
            let reason: String
            let insufficient = AppLocalization.string("尚不足")
            switch mode {
            case .volatilityManagedIdleCash:
                reason = AppLocalization.format(
                    "T-1 63日组合波动 %@，仓位倍数 %@",
                    signal("realized_volatility") ?? insufficient,
                    signal("multiplier") ?? "1"
                )
            case .pairSpreadZ252Shift25:
                reason = AppLocalization.format(
                    "T-1 配对Z分数：ONEQ/SPY %@，510300/510210 %@；阈值±1",
                    signal("us_oneq_spy_z252") ?? insufficient,
                    signal("china_510300_510210_z252") ?? insufficient
                )
            case .goldEquityRelativeZ252Shift25:
                reason = AppLocalization.format(
                    "T-1 黄金/权益Z分数 %@，黄金转移比例 %@",
                    signal("z_score") ?? insufficient,
                    signal("gold_transfer_positive_toward_gold") ?? "0"
                )
            }
            eventBySignalIndex[executionIndex - 1] = FrozenTargetEvent(
                signalIndex: executionIndex - 1,
                signalDate: executionDates[executionIndex - 1],
                targetWeights: target,
                reason: reason
            )
            processedRows += 1
            previousDate = dateText
        }
        guard processedRows == spec.expectedRows else { return nil }
        let events = eventBySignalIndex.values.sorted { $0.signalIndex < $1.signalIndex }
        return FrozenTargetSchedule(events: events)
    }

    private static func resourceURL(named name: String) -> URL? {
#if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: name, withExtension: "csv", subdirectory: "BacktestData/RecentWindow") { return url }
#endif
        if let url = Bundle.main.url(forResource: name, withExtension: "csv", subdirectory: "BacktestData/RecentWindow") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: "csv") { return url }
        let repoRelative = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("AssetTimeMachine/Backtest/BacktestData/RecentWindow/\(name).csv")
        return FileManager.default.fileExists(atPath: repoRelative.path) ? repoRelative : nil
    }
}
