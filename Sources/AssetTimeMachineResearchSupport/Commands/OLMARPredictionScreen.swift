import Foundation
import AssetTimeMachineBacktestCore

/// Fixed OLMAR learning rule. Outputs prediction evidence, never a funded account.
public enum OLMARPredictionScreen {
    public typealias Series = SectorMonthstartScreen.Series
    public struct Forecast: Codable, Equatable {
        public let signalDate: String?
        public let eligible: Bool
        public let prediction: [Double]
        public let weights: [Double]
        public let multiplier: Double
        public let constraintFeasible: Bool
        public let switchL1: Double
    }
    struct Input: Decodable { let schema: String; let series: [Series] }
    public struct Label: Codable {
        public let entryDate: String
        public let exitDate: String
        public let signalDate: String
        public let outcomesCNY: [Double]
        public let unitAdvantage: Double
        public let rankCorrelation: Double?
    }
    public struct Score: Codable {
        public let observations: Int
        public let meanUnitAdvantage: Double
        public let hac5T: Double?
        public let meanRankCorrelation: Double?
    }

    /// Euclidean simplex projection. Shift first to avoid subtracting huge thresholds.
    public static func project(_ values: [Double]) -> [Double] {
        precondition(!values.isEmpty && values.allSatisfy(\.isFinite))
        let shifted = values.map { $0 - values.max()! }, sorted = shifted.sorted(by: >)
        var sum = 0.0, threshold = -1.0
        for (index,value) in sorted.enumerated() {
            sum += value
            let candidate = (sum - 1) / Double(index + 1)
            if value > candidate { threshold = candidate }
        }
        let result = shifted.map { max(0,$0 - threshold) }, total = result.reduce(0,+)
        precondition(total.isFinite && total > 0)
        return result.map { $0 / total }
    }
    public static func update(previous: [Double], prediction: [Double]) throws -> ([Double],Double) {
        guard previous.count == prediction.count, previous.count > 1,
              previous.allSatisfy({ $0.isFinite && $0 >= 0 }),
              abs(previous.reduce(0,+)-1) <= 1e-12,
              prediction.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            throw BacktestConfigurationError.invalidParameter("OLMAR positive prediction/unit weights")
        }
        let average = prediction.reduce(0,+)/Double(prediction.count)
        let direction = prediction.map { $0 - average }
        let norm = direction.reduce(0) { $0 + $1*$1 }
        guard norm > 0 else { return (previous,0) }
        let expected = zip(previous,prediction).reduce(0) { $0 + $1.0*$1.1 }
        let multiplier = max(0,(10 - expected)/norm)
        let candidate = zip(previous,direction).map { $0 + multiplier*$1 }
        guard multiplier.isFinite, candidate.allSatisfy(\.isFinite) else {
            throw BacktestConfigurationError.invalidParameter("OLMAR finite update")
        }
        return (project(candidate),multiplier)
    }
    public static func forecasts(series: [Series]) throws -> [Forecast] {
        guard series.map(\.symbol) == SectorMonthstartScreen.symbols,
              let first = series.first, first.bars.count > 5,
              zip(first.bars,first.bars.dropFirst()).allSatisfy({ $0.date < $1.date }),
              series.allSatisfy({ s in s.bars.map(\.date) == first.bars.map(\.date)
                  && s.bars.allSatisfy({ b in
                      BacktestSeriesAlignment.historicalSeriesDate(from: b.date) != nil
                          && [b.open,b.high,b.low,b.close].allSatisfy({ $0.isFinite && $0 > 0 })
                          && b.high >= max(b.open,b.close) && b.low <= min(b.open,b.close)
                  }) }) else { throw BacktestConfigurationError.missingData("fixed nine real sector series") }
        var previous = Array(repeating: 1.0/9,count: 9), out: [Forecast] = []
        for i in first.bars.indices {
            let signalDate = i > 0 ? first.bars[i - 1].date : nil
            guard i >= 5 else {
                out.append(.init(signalDate: signalDate,eligible: false,prediction: [],weights: previous,
                    multiplier: 0,constraintFeasible: false,switchL1: 0))
                continue
            }
            let prediction = series.map { s in
                ((i - 5)..<i).reduce(0.0) { $0 + s.bars[$1].close } / 5 / s.bars[i - 1].close
            }
            let (weights,multiplier) = try update(previous: previous,prediction: prediction)
            let l1 = zip(weights,previous).reduce(0) { $0 + abs($1.0 - $1.1) }
            out.append(.init(signalDate: signalDate,eligible: true,prediction: prediction,weights: weights,
                multiplier: multiplier,constraintFeasible: prediction.max()! >= 10,switchL1: l1))
            previous = weights
        }
        return out
    }
    static func ranks(_ values: [Double]) -> [Double] {
        let indices = values.indices.sorted { values[$0] < values[$1] }
        var result = Array(repeating: 0.0,count: values.count), first = 0
        while first < indices.count {
            var end = first + 1
            while end < indices.count && values[indices[end]] == values[indices[first]] { end += 1 }
            for j in first..<end { result[indices[j]] = Double(first + end - 1)/2 }
            first = end
        }
        return result
    }
    static func correlation(_ a: [Double],_ b: [Double]) -> Double? {
        let a = ranks(a), b = ranks(b), mean = Double(a.count - 1)/2
        let numerator = zip(a,b).reduce(0) { $0 + ($1.0 - mean)*($1.1 - mean) }
        let denominator = sqrt(a.reduce(0) { $0 + pow($1 - mean,2) } * b.reduce(0) { $0 + pow($1 - mean,2) })
        return denominator > 0 ? numerator/denominator : nil
    }
    public static func score(_ values: [Double], correlations: [Double] = []) -> Score {
        precondition(values.count > 5 && values.allSatisfy(\.isFinite))
        let n = Double(values.count), mean = values.reduce(0,+)/n
        let centered = values.map { $0 - mean }
        var longVariance = centered.reduce(0) { $0 + $1*$1 }/n
        for lag in 1...5 {
            let covariance = (lag..<centered.count).reduce(0.0) { $0 + centered[$1]*centered[$1 - lag] }/n
            longVariance += 2*(1 - Double(lag)/6)*covariance
        }
        let error = sqrt(max(0,longVariance)/n)
        return .init(observations: values.count,meanUnitAdvantage: mean,hac5T: error > 0 ? mean/error : nil,
            meanRankCorrelation: correlations.isEmpty ? nil : correlations.reduce(0,+)/Double(correlations.count))
    }
    public static func run(pricesPath: String,historyPath: String,outputPath: String,sourceCommit: String) throws {
        let output = URL(fileURLWithPath: outputPath)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
        let raw = try Data(contentsOf: URL(fileURLWithPath: pricesPath))
        let history = try Data(contentsOf: URL(fileURLWithPath: historyPath))
        let input = try JSONDecoder().decode(Input.self,from: raw)
        guard input.schema == "sector-session-price-v1" else { throw BacktestConfigurationError.invalidParameter("OLMAR frozen schema") }
        let forecasts = try forecasts(series: input.series), days = input.series[0].bars.map(\.date)
        guard days.first == "2003-01-02", days.last == "2026-10-02",
              let fx = try IndustryTrendScreen.loadControlSeries(from: history)["usd_per_cny"] else {
            throw BacktestConfigurationError.missingData("frozen dates and historical FX")
        }
        let factors = try days.map { 1 / (try SectorMonthstartScreen.priorFX(dates: fx.dates,prices: fx.prices,asOf: $0)) }
        var labels: [Label] = []
        for i in days.indices where days[i] >= "2003-01-10" && days[i] <= "2026-10-01" && i + 1 < days.count {
            let f = forecasts[i]
            guard f.eligible, let signal = f.signalDate, signal < days[i] else { throw BacktestConfigurationError.missingData("known prediction") }
            let returns = input.series.map { $0.bars[i + 1].open*factors[i + 1]/($0.bars[i].open*factors[i]) - 1 }
            let advantage = zip(f.weights,returns).reduce(0) { $0 + ($1.0 - 1.0/9)*$1.1 }
            labels.append(.init(entryDate: days[i],exitDate: days[i + 1],signalDate: signal,outcomesCNY: returns,
                unitAdvantage: advantage,rankCorrelation: correlation(f.prediction,returns)))
        }
        let intervals = [("full","2003-01-10","2026-10-01"),("2003to2011","2003-01-10","2011-12-31"),
            ("2012to2019","2012-01-01","2019-12-31"),("since2020","2020-01-01","2026-10-01"),("since2022","2022-01-01","2026-10-01")]
        var scores: [String:Score] = [:]
        for (name,lower,upper) in intervals {
            let slice = labels.filter { $0.entryDate >= lower && $0.entryDate <= upper }
            guard slice.count > 5 else { throw BacktestConfigurationError.missingData("OLMAR label window") }
            scores[name] = score(slice.map(\.unitAdvantage),correlations: slice.compactMap(\.rankCorrelation))
        }
        let gates = ["full_mean_advantage_positive":scores["full"]!.meanUnitAdvantage > 0,
            "full_hac5_t_at_least_1_96":(scores["full"]!.hac5T ?? -Double.infinity) >= 1.96,
            "since2020_mean_advantage_positive":scores["since2020"]!.meanUnitAdvantage > 0,
            "since2022_mean_advantage_positive":scores["since2022"]!.meanUnitAdvantage > 0]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
        let predictions = try encoder.encode(forecasts), outcomes = try encoder.encode(labels)
        let metrics = try JSONSerialization.jsonObject(with: encoder.encode(scores))
        let result: [String:Any] = ["study_id":"D0-OLMAR-SECTOR-PREDICTABILITY-20261008",
            "completed_at":ISO8601DateFormatter().string(from: Date()),"source_commit":sourceCommit,
            "funded_accounts":0,"parameter_searches":0,"primary_count":1,"formal_validation":false,
            "primary_screen_passed":gates.values.allSatisfy { $0 },"gates":gates,"scores":metrics,
            "disposition":gates.values.allSatisfy { $0 } ? "PREDICTION_SCREEN_ONLY_REQUIRES_FUNDED_VERIFICATION" : "PREDICTION_SCREEN_FAILED_NO_FUNDING",
            "predictions_sha256":ResearchRunEvidence.sha256(predictions),"labels_sha256":ResearchRunEvidence.sha256(outcomes),
            "input_sha256":ResearchRunEvidence.sha256(raw),"history_sha256":ResearchRunEvidence.sha256(history),
            "binary_sha256":ResearchRunEvidence.sha256(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))),
            "labels":labels.count,"mean_target_switch_l1":forecasts.filter(\.eligible).map(\.switchL1).reduce(0,+)/Double(forecasts.filter(\.eligible).count),
            "infeasible_forecast_constraint_count":forecasts.filter { $0.eligible && !$0.constraintFeasible }.count,
            "account_metrics":NSNull(),"costs_applied":false,"recommendation_eligible":false,
            "limitations":["Unit prediction scores are not funded returns, CAGR, drawdown, Sharpe, or actual turnover.",
                "Raw price-only signals/labels omit distributions; current corrected quotes not original PIT vintages.",
                "Fixed ETF and next-open adaptation differs from paper's historical stock datasets and ideal close trading.",
                "No pristine OOS, parameter sweep, formal multiple-testing certification, or best-strategy outperformance proof."]]
        try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
        try predictions.write(to: output.appendingPathComponent("PREDICTIONS.json"),options: .atomic)
        try outcomes.write(to: output.appendingPathComponent("LABELS.json"),options: .atomic)
        try JSONSerialization.data(withJSONObject: result,options: [.prettyPrinted,.sortedKeys])
            .write(to: output.appendingPathComponent("RESULT.json"),options: .atomic)
        print("OLMAR fixed causal prediction screen saved; zero funded accounts.")
    }
}
