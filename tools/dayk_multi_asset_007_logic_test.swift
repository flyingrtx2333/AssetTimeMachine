import Foundation

@main
struct DayKMultiAsset007LogicTestMain {
    static func syntheticPrices(
        count: Int = 280,
        dailyDrift: Double,
        wave: Double,
        phase: Double = 0
    ) -> [Double] {
        (0..<count).map { index in
            let trend = 100 * pow(1 + dailyDrift, Double(index))
            return trend * (1 + wave * sin(Double(index) * 0.31 + phase))
        }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            FileHandle.standardError.write(Data(("TEST_FAILED: " + message + "\n").utf8))
            exit(1)
        }
    }

    static func main() {
        let index = 250
        var prices: [String: [Double]] = [
            "gold_cny": syntheticPrices(dailyDrift: 0.0007, wave: 0.007),
            "nasdaq": syntheticPrices(dailyDrift: 0.0010, wave: 0.012),
            "sp500": syntheticPrices(dailyDrift: 0.0006, wave: 0.006, phase: 0.4),
            "csi300": syntheticPrices(dailyDrift: -0.0005, wave: 0.010),
            "shanghai_composite": syntheticPrices(dailyDrift: 0.0005, wave: 0.008, phase: 0.8),
        ]

        let selected = DayKMultiAsset007Logic.selectedSignals(
            pricesBySymbol: prices, signalIndex: index
        )
        require(selected.count == 3, "one eligible asset should be selected from each role")
        require(selected.filter { ["nasdaq", "sp500"].contains($0.symbol) }.count == 1,
                "US role must never contain both indices")
        require(selected.filter { ["csi300", "shanghai_composite"].contains($0.symbol) }.count == 1,
                "China role must never contain both indices")
        require(!selected.contains { $0.symbol == "csi300" }, "negative-trend CSI300 must be excluded")

        let candidate = DayKMultiAsset007Logic.candidateTarget(
            pricesBySymbol: prices, signalIndex: index
        )
        let control = DayKMultiAsset007Logic.matchedEqualWeightTarget(
            pricesBySymbol: prices, signalIndex: index
        )
        require(candidate.values.reduce(0, +) <= 1.0000000001, "candidate gross exceeds 100%")
        require(candidate.values.allSatisfy { $0 >= 0 && $0 <= 0.5000000001 },
                "candidate weight violates bounds")
        require(abs(control.values.reduce(0, +) - 1) < 1e-10,
                "three-role equal-weight control should be fully invested")

        let frozenCandidate = candidate
        for symbol in prices.keys {
            prices[symbol]![index + 1] *= symbol == "nasdaq" ? 5 : 0.2
        }
        let repeated = DayKMultiAsset007Logic.candidateTarget(
            pricesBySymbol: prices, signalIndex: index
        )
        require(frozenCandidate.keys == repeated.keys, "future data changed selected symbols")
        for symbol in frozenCandidate.keys {
            require(abs((frozenCandidate[symbol] ?? 0) - (repeated[symbol] ?? 0)) < 1e-12,
                    "future data changed a frozen target weight")
        }

        let oneRolePrices = [
            "gold_cny": syntheticPrices(dailyDrift: 0.0007, wave: 0.007),
            "nasdaq": syntheticPrices(dailyDrift: -0.0010, wave: 0.005),
            "sp500": syntheticPrices(dailyDrift: -0.0008, wave: 0.005),
            "csi300": syntheticPrices(dailyDrift: -0.0009, wave: 0.005),
            "shanghai_composite": syntheticPrices(dailyDrift: -0.0007, wave: 0.005),
        ]
        let oneRole = DayKMultiAsset007Logic.matchedEqualWeightTarget(
            pricesBySymbol: oneRolePrices, signalIndex: index
        )
        require(oneRole.count == 1 && abs((oneRole["gold_cny"] ?? 0) - 0.5) < 1e-12,
                "single active role must retain 50% cash")

        print("DAYK_MULTI_ASSET_007_LOGIC_TEST_OK")
    }
}
