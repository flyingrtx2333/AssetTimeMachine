import Foundation

nonisolated struct MacroInitialReleaseRow: Equatable {
    let seriesID: String
    let referenceMonth: String
    let releaseDate: Date
    let initialValue: Double
    let snapshotSHA256: String

    var rowHash: String {
        let canonical = "\(seriesID)|\(referenceMonth)|\(MacroInitialReleaseCSVLoader.dateString(releaseDate))|\(String(format: "%.12g", initialValue))|\(snapshotSHA256)"
        var hash: UInt64 = 1469598103934665603
        for byte in canonical.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(format: "%016llx", hash)
    }
}

nonisolated enum MacroInitialReleaseError: Error, Equatable {
    case unreadableFile(String)
    case invalidHeader(String)
    case malformedRow(String)
    case invalidSeries(String)
    case invalidReferenceMonth(String)
    case invalidReleaseDate(String)
    case nonFiniteValue(String)
    case invalidSnapshotHash(String)
    case conflictingDuplicate(String)
}

/// Validated immutable initial-release rows keyed by reference month.
nonisolated struct MacroInitialReleaseDataset: Equatable {
    let unrateByMonth: [String: MacroInitialReleaseRow]
    let cpiByMonth: [String: MacroInitialReleaseRow]
    let invalidUNRATEMonths: Set<String>
    let invalidCPIMonths: Set<String>

    init(unrateRows: [MacroInitialReleaseRow], cpiRows: [MacroInitialReleaseRow]) throws {
        let unrate = try Self.index(unrateRows, expectedSeries: "UNRATE")
        let cpi = try Self.index(cpiRows, expectedSeries: "CPIAUCSL")
        self.unrateByMonth = unrate.rows
        self.cpiByMonth = cpi.rows
        self.invalidUNRATEMonths = unrate.invalidMonths
        self.invalidCPIMonths = cpi.invalidMonths
    }

    private static func index(
        _ rows: [MacroInitialReleaseRow],
        expectedSeries: String
    ) throws -> (rows: [String: MacroInitialReleaseRow], invalidMonths: Set<String>) {
        var result: [String: MacroInitialReleaseRow] = [:]
        var invalidMonths: Set<String> = []
        for row in rows {
            guard row.seriesID == expectedSeries else {
                throw MacroInitialReleaseError.invalidSeries(row.seriesID)
            }
            guard MacroSahmCPIStrategy.monthDate(row.referenceMonth) != nil else {
                throw MacroInitialReleaseError.invalidReferenceMonth(row.referenceMonth)
            }

            guard row.snapshotSHA256.count == 64,
                  row.snapshotSHA256.allSatisfy({ $0.isHexDigit }) else {
                throw MacroInitialReleaseError.invalidSnapshotHash("\(row.seriesID):\(row.referenceMonth)")
            }
            if !row.initialValue.isFinite {
                invalidMonths.insert(row.referenceMonth)
            }
            if let existing = result[row.referenceMonth], existing != row {
                invalidMonths.insert(row.referenceMonth)
                if row.releaseDate > existing.releaseDate {
                    result[row.referenceMonth] = row
                }
                continue
            }
            result[row.referenceMonth] = row
        }
        return (result, invalidMonths)
    }
}

/// Production CSV loader for the committed ALFRED initial-release freeze.
nonisolated enum MacroInitialReleaseCSVLoader {
    private static var shanghaiCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    static func load(directory: URL) throws -> MacroInitialReleaseDataset {
        let unrate = try loadFile(
            directory.appendingPathComponent("UNRATE_initial_release.csv"),
            expectedSeries: "UNRATE"
        )
        let cpi = try loadFile(
            directory.appendingPathComponent("CPIAUCSL_initial_release.csv"),
            expectedSeries: "CPIAUCSL"
        )
        return try MacroInitialReleaseDataset(unrateRows: unrate, cpiRows: cpi)
    }

    static func dateString(_ date: Date) -> String {
        let components = shanghaiCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private static func loadFile(_ url: URL, expectedSeries: String) throws -> [MacroInitialReleaseRow] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw MacroInitialReleaseError.unreadableFile(url.path)
        }
        let lines = content.split(whereSeparator: \.isNewline).map(String.init)
        let header = "series_id,reference_month,release_date,initial_value,source,vintage_id,snapshot_sha256"
        guard lines.first == header else { throw MacroInitialReleaseError.invalidHeader(url.path) }
        return try lines.dropFirst().enumerated().map { offset, line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 7 else {
                throw MacroInitialReleaseError.malformedRow("\(url.lastPathComponent):\(offset + 2)")
            }
            guard fields[0] == expectedSeries else { throw MacroInitialReleaseError.invalidSeries(fields[0]) }
            guard let releaseDate = parseDate(fields[2]) else {
                throw MacroInitialReleaseError.invalidReleaseDate(fields[2])
            }
            guard let value = Double(fields[3]) else {
                throw MacroInitialReleaseError.malformedRow("\(url.lastPathComponent):\(offset + 2)")
            }
            return MacroInitialReleaseRow(
                seriesID: fields[0],
                referenceMonth: fields[1],
                releaseDate: releaseDate,
                initialValue: value,
                snapshotSHA256: fields[6]
            )
        }
    }

    private static func parseDate(_ value: String) -> Date? {
        let values = value.split(separator: "-").compactMap { Int(String($0)) }
        guard values.count == 3 else { return nil }
        return shanghaiCalendar.date(from: DateComponents(
            timeZone: shanghaiCalendar.timeZone,
            year: values[0], month: values[1], day: values[2]
        ))
    }
}

/// Frozen ATM-SVP2-MACRO-SAHM-CPI-001 target schedule.
/// Schedule construction reads only immutable macro rows and real-observation market masks.
nonisolated enum MacroSahmCPIStrategy {
    static let trialID = "ATM-SVP2-MACRO-SAHM-CPI-001"
    static let candidateID = "MACRO-SAHM-CPI-001"
    static let goldSymbol = "gold_cny"
    static let nasdaqSymbol = "nasdaq"
    static let fxSymbol = "usd_per_cny"
    static let tradableSymbols: Set<String> = [goldSymbol, nasdaqSymbol]
    static let signalSymbols = [goldSymbol, nasdaqSymbol, fxSymbol]
    static let cashTarget = [goldSymbol: 0.0, nasdaqSymbol: 0.0]
    static let freshnessDays = 62
    static let sahmThreshold = 0.50
    static let cpiThreshold = 2.00

    enum Variant: String {
        case candidate
        case naturallyDrifting5050Control
        case swapPlacebo
    }

    struct Classification: Equatable {
        let targetWeights: [String: Double]
        let reason: String
        let sahmValue: Double
        let inflationPercent: Double
    }

    private struct Pair {
        let referenceMonth: String
        let unrate: MacroInitialReleaseRow
        let cpi: MacroInitialReleaseRow
        let availableAt: Date
    }

    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }

    static func monthDate(_ value: String) -> Date? {
        let values = value.split(separator: "-").compactMap { Int(String($0)) }
        guard values.count == 2, (1...12).contains(values[1]) else { return nil }
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: values[0], month: values[1], day: 1
        ))
    }

    static func classify(
        referenceMonth: String,
        dataset: MacroInitialReleaseDataset,
        variant: Variant
    ) -> Classification? {
        guard let currentMonth = monthDate(referenceMonth) else { return nil }
        let unrateMonths = (-14...0).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .month, value: offset, to: currentMonth) else { return nil }
            return monthString(date)
        }
        let cpiMonths = (-12...0).compactMap { offset -> String? in
            guard let date = calendar.date(byAdding: .month, value: offset, to: currentMonth) else { return nil }
            return monthString(date)
        }
        guard unrateMonths.count == 15, cpiMonths.count == 13,
              unrateMonths.allSatisfy({ !dataset.invalidUNRATEMonths.contains($0) }),
              cpiMonths.allSatisfy({ !dataset.invalidCPIMonths.contains($0) }),
              unrateMonths.allSatisfy({ dataset.unrateByMonth[$0]?.initialValue.isFinite == true }),
              cpiMonths.allSatisfy({ dataset.cpiByMonth[$0]?.initialValue.isFinite == true }) else { return nil }

        let unemployment = unrateMonths.compactMap { dataset.unrateByMonth[$0]?.initialValue }
        var averages: [Double] = []
        for end in 2..<unemployment.count {
            let average = (unemployment[end] + unemployment[end - 1] + unemployment[end - 2]) / 3
            guard average.isFinite else { return nil }
            averages.append(average)
        }
        guard averages.count == 13, let currentAverage = averages.last,
              let previousMinimum = averages.dropLast().min() else { return nil }
        let sahm = currentAverage - previousMinimum
        guard sahm.isFinite,
              let currentCPI = dataset.cpiByMonth[referenceMonth]?.initialValue,
              let priorCPI = dataset.cpiByMonth[cpiMonths[0]]?.initialValue,
              currentCPI > 0, priorCPI > 0 else { return nil }
        let inflation = 100 * (currentCPI / priorCPI - 1)
        guard inflation.isFinite else { return nil }

        if variant == .naturallyDrifting5050Control {
            return Classification(
                targetWeights: [goldSymbol: 0.5, nasdaqSymbol: 0.5],
                reason: "first_warm_control_50_50_no_rebalance",
                sahmValue: sahm,
                inflationPercent: inflation
            )
        }
        if sahm >= sahmThreshold {
            return Classification(
                targetWeights: cashTarget,
                reason: "sahm_ge_0_50_cash",
                sahmValue: sahm,
                inflationPercent: inflation
            )
        }
        let ordinaryGold = inflation >= cpiThreshold
        let gold = variant == .candidate ? ordinaryGold : !ordinaryGold
        return Classification(
            targetWeights: gold ? [goldSymbol: 1] : [nasdaqSymbol: 1],
            reason: variant == .candidate
                ? (ordinaryGold ? "non_recession_cpi_ge_2_gold" : "non_recession_cpi_lt_2_nasdaq")
                : (gold ? "swap_placebo_non_recession_gold" : "swap_placebo_non_recession_nasdaq"),
            sahmValue: sahm,
            inflationPercent: inflation
        )
    }

    /// `feeRateIgnored` exists only as a contract probe: cost is intentionally outside the pure schedule.
    static func makeSchedule(
        frame: MarketDataFrame,
        dataset: MacroInitialReleaseDataset,
        variant: Variant = .candidate,
        feeRateIgnored: Double = 0
    ) -> FrozenTargetSchedule? {
        _ = feeRateIgnored
        guard Set(frame.tradableSymbols) == tradableSymbols,
              !frame.dates.isEmpty,
              signalSymbols.allSatisfy({
                  frame.pricesBySymbol[$0]?.count == frame.dates.count
                      && frame.observedBySymbol[$0]?.count == frame.dates.count
              }) else { return nil }

        let commonIndices = frame.dates.indices.filter { index in
            signalSymbols.allSatisfy { symbol in
                frame.observedBySymbol[symbol]?[index] == true
                    && (frame.pricesBySymbol[symbol]?[index] ?? .nan).isFinite
                    && (frame.pricesBySymbol[symbol]?[index] ?? 0) > 0
            }
        }
        let pairs = Set(dataset.unrateByMonth.keys).intersection(dataset.cpiByMonth.keys).sorted().compactMap { month -> Pair? in
            guard let unrate = dataset.unrateByMonth[month], let cpi = dataset.cpiByMonth[month],
                  let available = availableAt(releaseDate: max(unrate.releaseDate, cpi.releaseDate)) else { return nil }
            return Pair(referenceMonth: month, unrate: unrate, cpi: cpi, availableAt: available)
        }

        var events: [FrozenTargetEvent] = []
        var priorTarget: [String: Double]? = cashTarget
        var pairCursor = 0
        var latestAvailablePair: Pair?
        var controlEstablished = false
        var reviewClockHash: UInt64 = 1469598103934665603

        func recordReview(index: Int, pair: Pair) {
            let row = "\(index)|\(frame.dates[index].recordDateString)|\(pair.referenceMonth)|\(pair.unrate.rowHash)|\(pair.cpi.rowHash)\n"
            for byte in row.utf8 {
                reviewClockHash ^= UInt64(byte)
                reviewClockHash &*= 1099511628211
            }
        }

        func appendEvent(
            index: Int,
            target: [String: Double],
            reason: String,
            pair: Pair?
        ) {
            guard target != priorTarget else { return }
            let event = FrozenTargetEvent(
                signalIndex: index,
                signalDate: frame.dates[index],
                targetWeights: target,
                reason: reason,
                referenceMonth: pair?.referenceMonth,
                macroRowHashes: pair.map { ["UNRATE": $0.unrate.rowHash, "CPIAUCSL": $0.cpi.rowHash] } ?? [:]
            )
            if events.last?.signalIndex == index {
                events[events.count - 1] = event
            } else {
                events.append(event)
            }
            priorTarget = target
        }

        for index in commonIndices {
            let boundary = calendar.startOfDay(for: frame.dates[index])
            var pendingDecision: (target: [String: Double], reason: String, pair: Pair?)?
            while pairCursor < pairs.count, boundary > pairs[pairCursor].availableAt {
                let pair = pairs[pairCursor]
                latestAvailablePair = pair
                pairCursor += 1
                recordReview(index: index, pair: pair)
                if variant == .naturallyDrifting5050Control, controlEstablished { continue }
                if let classification = classify(referenceMonth: pair.referenceMonth, dataset: dataset, variant: variant) {
                    pendingDecision = (classification.targetWeights, classification.reason, pair)
                    if variant == .naturallyDrifting5050Control {
                        controlEstablished = true
                    }
                } else {
                    pendingDecision = (cashTarget, "incomplete_continuous_warmup_cash", pair)
                }
            }

            if !(variant == .naturallyDrifting5050Control && controlEstablished),
               let latest = latestAvailablePair,
               let end = monthEnd(latest.referenceMonth),
               let expiry = calendar.date(byAdding: .day, value: freshnessDays, to: end),
               boundary > expiry {
                pendingDecision = (cashTarget, "complete_pair_stale_gt_62_days_cash", latest)
            }
            if let decision = pendingDecision {
                appendEvent(
                    index: index,
                    target: decision.target,
                    reason: decision.reason,
                    pair: decision.pair
                )
            }
        }
        return FrozenTargetSchedule(
            events: events,
            reviewClockFingerprint: String(format: "%016llx", reviewClockHash)
        )
    }

    private static func availableAt(releaseDate: Date) -> Date? {
        guard let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: releaseDate)) else { return nil }
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: next)
    }

    private static func monthEnd(_ month: String) -> Date? {
        guard let start = monthDate(month),
              let next = calendar.date(byAdding: .month, value: 1, to: start) else { return nil }
        return calendar.date(byAdding: .day, value: -1, to: next)
    }

    private static func monthString(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year!, components.month!)
    }
}
