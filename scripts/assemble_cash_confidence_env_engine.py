#!/usr/bin/env python3
"""Create a temporary BacktestEngine with env-tunable cash-confidence parameters.

The production source is never modified. Defaults exactly match the shipping strategy.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match, found {count}: {old!r}")
    return text.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", default="AssetTimeMachine/Backtest/BacktestEngine.swift")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    text = Path(args.base).read_text(encoding="utf-8")
    replacements = [
        (
            "            growthStateScale: 1.05,",
            '            growthStateScale: Double(ProcessInfo.processInfo.environment["ATM_CC_GROWTH_SCALE"] ?? "1.05") ?? 1.05,',
        ),
        (
            "            fastBridgeRatio: 0.15,",
            '            fastBridgeRatio: Double(ProcessInfo.processInfo.environment["ATM_CC_FAST_BRIDGE"] ?? "0.15") ?? 0.15,',
        ),
        (
            "            sleeveCap: 0.2075",
            '            sleeveCap: Double(ProcessInfo.processInfo.environment["ATM_CC_SLEEVE_CAP"] ?? "0.2075") ?? 0.2075',
        ),
        (
            "                    let totalWeight = min(sleeveCap, availableCash, availableGross)",
            '''                    let dynamicSleeveVolThreshold = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_DYNAMIC_SLEEVE_VOL_THRESHOLD"] ?? "99"
                    ) ?? 99
                    let dynamicSleeveLowCap = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_DYNAMIC_SLEEVE_LOW_CAP"] ?? String(sleeveCap)
                    ) ?? sleeveCap
                    let dynamicSleeveHighVolThreshold = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_DYNAMIC_SLEEVE_HIGH_VOL_THRESHOLD"] ?? "99"
                    ) ?? 99
                    let dynamicSleeveHighVolCap = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_DYNAMIC_SLEEVE_HIGH_VOL_CAP"] ?? String(dynamicSleeveLowCap)
                    ) ?? dynamicSleeveLowCap
                    let singleIndexSleeveCap = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_SINGLE_INDEX_SLEEVE_CAP"] ?? String(sleeveCap)
                    ) ?? sleeveCap
                    let shallowDrawdownThreshold = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_SHALLOW_DD_THRESHOLD"] ?? "0"
                    ) ?? 0
                    let shallowDrawdownSleeveCap = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_SHALLOW_DD_SLEEVE_CAP"] ?? String(sleeveCap)
                    ) ?? sleeveCap
                    var effectiveSleeveCap = sleeveCap
                    if signalIndex >= 60 {
                        var recentBaseReturns: [Double] = []
                        recentBaseReturns.reserveCapacity(60)
                        for cursor in (signalIndex - 59)...signalIndex {
                            guard cursor > 0,
                                  let previousValue = alignedBaseValues[cursor - 1],
                                  let currentValue = alignedBaseValues[cursor],
                                  previousValue > 0 else { continue }
                            recentBaseReturns.append(currentValue / previousValue - 1)
                        }
                        if recentBaseReturns.count > 1 {
                            let mean = recentBaseReturns.reduce(0, +) / Double(recentBaseReturns.count)
                            let variance = recentBaseReturns.reduce(0.0) {
                                $0 + pow($1 - mean, 2)
                            } / Double(recentBaseReturns.count - 1)
                            let annualizedVolatility = sqrt(max(variance, 0)) * sqrt(252)
                            if annualizedVolatility >= dynamicSleeveHighVolThreshold {
                                effectiveSleeveCap = min(sleeveCap, dynamicSleeveHighVolCap)
                            } else if annualizedVolatility >= dynamicSleeveVolThreshold {
                                effectiveSleeveCap = min(sleeveCap, dynamicSleeveLowCap)
                            }
                        }
                    }
                    if shallowDrawdownThreshold > 0, baseDrawdown < shallowDrawdownThreshold {
                        effectiveSleeveCap = min(effectiveSleeveCap, shallowDrawdownSleeveCap)
                    }
                    let recoveryEvidenceLookback = Int(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_EVIDENCE_LOOKBACK"] ?? "0"
                    ) ?? 0
                    let recoveryEvidenceGapThreshold = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_EVIDENCE_GAP_THRESHOLD"] ?? "0"
                    ) ?? 0
                    let recoveryWeakEvidenceSleeveCap = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_WEAK_EVIDENCE_SLEEVE_CAP"] ?? String(sleeveCap)
                    ) ?? sleeveCap
                    if recoveryEvidenceLookback > 0,
                       let nasdaqEvidenceMomentum = priceMomentum(
                        values: nasdaqPrices,
                        at: signalIndex,
                        lookback: recoveryEvidenceLookback
                       ),
                       let sp500EvidenceMomentum = priceMomentum(
                        values: sp500Prices,
                        at: signalIndex,
                        lookback: recoveryEvidenceLookback
                       ),
                       abs(nasdaqEvidenceMomentum - sp500EvidenceMomentum) < recoveryEvidenceGapThreshold {
                        effectiveSleeveCap = min(effectiveSleeveCap, recoveryWeakEvidenceSleeveCap)
                    }
                    if nasdaqPositive != sp500Positive {
                        effectiveSleeveCap = min(effectiveSleeveCap, singleIndexSleeveCap)
                    }
                    let totalWeight = min(effectiveSleeveCap, availableCash, availableGross)''',
        ),
        (
            "                    var eligible: [(String, Double)] = []",
            '''                    let recoveryMomentumScale = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_MOMENTUM_SCALE"] ?? "0"
                    ) ?? 0
                    let recoveryMomentumLookback = Int(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_MOMENTUM_LOOKBACK"] ?? "60"
                    ) ?? 60
                    let recoveryVolatilityExponent = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_VOL_EXPONENT"] ?? "1"
                    ) ?? 1
                    let recoveryShortMomentumLookback = Int(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_SHORT_MOMENTUM_LOOKBACK"] ?? "0"
                    ) ?? 0
                    let recoveryShortMomentumWeight = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_SHORT_MOMENTUM_WEIGHT"] ?? "0"
                    ) ?? 0
                    let nasdaqAllocationMomentum = priceMomentum(
                        values: nasdaqPrices,
                        at: signalIndex,
                        lookback: recoveryMomentumLookback
                    ) ?? nasdaqMomentum
                    let sp500AllocationMomentum = priceMomentum(
                        values: sp500Prices,
                        at: signalIndex,
                        lookback: recoveryMomentumLookback
                    ) ?? sp500Momentum
                    let nasdaqShortMomentum = recoveryShortMomentumLookback > 0
                        ? (priceMomentum(
                            values: nasdaqPrices,
                            at: signalIndex,
                            lookback: recoveryShortMomentumLookback
                        ) ?? 0)
                        : 0
                    let sp500ShortMomentum = recoveryShortMomentumLookback > 0
                        ? (priceMomentum(
                            values: sp500Prices,
                            at: signalIndex,
                            lookback: recoveryShortMomentumLookback
                        ) ?? 0)
                        : 0
                    let nasdaqQualityMomentum = max(
                        nasdaqAllocationMomentum + recoveryShortMomentumWeight * nasdaqShortMomentum,
                        0
                    )
                    let sp500QualityMomentum = max(
                        sp500AllocationMomentum + recoveryShortMomentumWeight * sp500ShortMomentum,
                        0
                    )
                    let recoveryTrendEfficiencyScale = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_TREND_EFFICIENCY_SCALE"] ?? "0"
                    ) ?? 0
                    func recoveryTrendEfficiency(_ prices: [Double]) -> Double {
                        guard recoveryMomentumLookback > 0,
                              signalIndex >= recoveryMomentumLookback,
                              prices[signalIndex - recoveryMomentumLookback] > 0 else { return 0 }
                        var pathLength = 0.0
                        for cursor in (signalIndex - recoveryMomentumLookback + 1)...signalIndex {
                            guard prices[cursor - 1] > 0 else { continue }
                            pathLength += abs(prices[cursor] / prices[cursor - 1] - 1)
                        }
                        guard pathLength > 0 else { return 0 }
                        let netReturn = max(
                            prices[signalIndex] / prices[signalIndex - recoveryMomentumLookback] - 1,
                            0
                        )
                        return min(max(netReturn / pathLength, 0), 1)
                    }
                    let nasdaqTrendEfficiency = recoveryTrendEfficiency(nasdaqPrices)
                    let sp500TrendEfficiency = recoveryTrendEfficiency(sp500Prices)
                    let recoveryQualityExponent = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_EXPONENT"] ?? "1"
                    ) ?? 1
                    let recoveryHighQualityExponent = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_HIGH_QUALITY_EXPONENT"] ?? String(recoveryQualityExponent)
                    ) ?? recoveryQualityExponent
                    let recoveryQualityGapThreshold = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_QUALITY_GAP_THRESHOLD"] ?? "99"
                    ) ?? 99
                    let recoveryQualityGap = abs(nasdaqQualityMomentum - sp500QualityMomentum)
                    let activeRecoveryQualityExponent = recoveryQualityGap >= recoveryQualityGapThreshold
                        ? recoveryHighQualityExponent
                        : recoveryQualityExponent
                    let recoveryDowScoreScale = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_DOW_SCORE_SCALE"] ?? "0"
                    ) ?? 0
                    let recoveryDownsideVolBlend = Double(
                        ProcessInfo.processInfo.environment["ATM_CC_RECOVERY_DOWNSIDE_VOL_BLEND"] ?? "0"
                    ) ?? 0
                    func recoveryEffectiveVolatility(
                        _ prices: [Double],
                        totalVolatility: Double
                    ) -> Double {
                        guard recoveryDownsideVolBlend > 0,
                              signalIndex >= 40 else { return totalVolatility }
                        var downsideSquares = 0.0
                        var observations = 0
                        for cursor in (signalIndex - 39)...signalIndex {
                            guard cursor > 0, prices[cursor - 1] > 0 else { continue }
                            let dailyReturn = prices[cursor] / prices[cursor - 1] - 1
                            downsideSquares += pow(min(dailyReturn, 0), 2)
                            observations += 1
                        }
                        guard observations > 1 else { return totalVolatility }
                        let downsideVolatility = sqrt(downsideSquares / Double(observations)) * sqrt(252)
                        let blend = min(max(recoveryDownsideVolBlend, 0), 1)
                        return (1 - blend) * totalVolatility + blend * max(downsideVolatility, 0.03)
                    }
                    var eligible: [(String, Double)] = []''',
        ),
        (
            '                        eligible.append(("nasdaq", 1 / max(volatility, 0.05)))',
            '''                        let effectiveVolatility = recoveryEffectiveVolatility(
                            nasdaqPrices,
                            totalVolatility: volatility
                        )
                        let quality = pow(
                            max(
                                (1 + recoveryMomentumScale * nasdaqQualityMomentum)
                                    * (1 + recoveryTrendEfficiencyScale * nasdaqTrendEfficiency),
                                0.0001
                            ),
                            max(activeRecoveryQualityExponent, 0.05)
                        )
                        eligible.append(("nasdaq", quality / pow(max(effectiveVolatility, 0.05), recoveryVolatilityExponent)))''',
        ),
        (
            '                        eligible.append(("sp500", 1 / max(volatility, 0.05)))',
            '''                        let effectiveVolatility = recoveryEffectiveVolatility(
                            sp500Prices,
                            totalVolatility: volatility
                        )
                        let quality = pow(
                            max(
                                (1 + recoveryMomentumScale * sp500QualityMomentum)
                                    * (1 + recoveryTrendEfficiencyScale * sp500TrendEfficiency),
                                0.0001
                            ),
                            max(activeRecoveryQualityExponent, 0.05)
                        )
                        eligible.append(("sp500", quality / pow(max(effectiveVolatility, 0.05), recoveryVolatilityExponent)))''',
        ),
        (
            "                    var nextRecoveryWeights: [String: Double] = [:]",
            '''                    if recoveryDowScoreScale > 0,
                       let dowPrices = data.pricesBySymbol["dowjones"],
                       dowPrices.indices.contains(signalIndex),
                       signalIndex >= max(trendMA, recoveryMomentumLookback),
                       let dowMA = movingAverageAt(
                        values: dowPrices,
                        at: signalIndex,
                        period: trendMA
                       ),
                       let dowMomentum = priceMomentum(
                        values: dowPrices,
                        at: signalIndex,
                        lookback: momentumLookback
                       ),
                       dowPrices[signalIndex] >= dowMA,
                       dowMomentum > 0,
                       let volatility = annualizedVolatilityAt(
                        values: dowPrices,
                        at: signalIndex,
                        lookback: 40
                       ) {
                        let dowAllocationMomentum = priceMomentum(
                            values: dowPrices,
                            at: signalIndex,
                            lookback: recoveryMomentumLookback
                        ) ?? dowMomentum
                        let effectiveVolatility = recoveryEffectiveVolatility(
                            dowPrices,
                            totalVolatility: volatility
                        )
                        let quality = pow(
                            max(1 + recoveryMomentumScale * max(dowAllocationMomentum, 0), 0.0001),
                            max(recoveryQualityExponent, 0.05)
                        )
                        eligible.append((
                            "dowjones",
                            recoveryDowScoreScale * quality
                                / pow(max(effectiveVolatility, 0.05), recoveryVolatilityExponent)
                        ))
                    }
                    var nextRecoveryWeights: [String: Double] = [:]''',
        ),
        (
            "        let tradeBand = 0.20",
            '        let tradeBand = Double(ProcessInfo.processInfo.environment["ATM_CC_TRADE_BAND"] ?? "0.20") ?? 0.20',
        ),
        (
            "        let matureNasdaqMAPeriod = 40",
            '        let matureNasdaqMAPeriod = Int(ProcessInfo.processInfo.environment["ATM_CC_NASDAQ_MA"] ?? "40") ?? 40',
        ),
        (
            "        let matureNasdaqScale = 0.88",
            '        let matureNasdaqScale = Double(ProcessInfo.processInfo.environment["ATM_CC_NASDAQ_SCALE"] ?? "0.88") ?? 0.88',
        ),
        (
            "        let matureOtherAssetScale = 0.80",
            '        let matureOtherAssetScale = Double(ProcessInfo.processInfo.environment["ATM_CC_OTHER_SCALE"] ?? "0.80") ?? 0.80',
        ),
        (
            "        let leadershipEvaluationSessions = 10",
            '        let leadershipEvaluationSessions = Int(ProcessInfo.processInfo.environment["ATM_CC_LEADERSHIP_EVAL"] ?? "10") ?? 10',
        ),
        (
            "        let leadershipPriorEvidence = 2.0",
            '        let leadershipPriorEvidence = Double(ProcessInfo.processInfo.environment["ATM_CC_LEADERSHIP_PRIOR"] ?? "2.0") ?? 2.0',
        ),
        (
            "        let minimumLeadershipMigration = 0.50",
            '        let minimumLeadershipMigration = Double(ProcessInfo.processInfo.environment["ATM_CC_MIN_MIGRATION"] ?? "0.50") ?? 0.50\n        let leadershipSuccessEdge = Double(ProcessInfo.processInfo.environment["ATM_CC_SUCCESS_EDGE"] ?? "0") ?? 0\n        let leadershipEdgeExponent = Double(ProcessInfo.processInfo.environment["ATM_CC_EDGE_EXPONENT"] ?? "1") ?? 1',
        ),
        (
            "                        if targetReturn > priorReturn {",
            "                        if targetReturn > priorReturn + leadershipSuccessEdge {",
        ),
        (
            "                        let leadershipEdge = min(max(2 * posteriorMean - 1, 0), 1)\n                        let migration = minimumLeadershipMigration\n                            + (1 - minimumLeadershipMigration) * leadershipEdge",
            "                        let rawLeadershipEdge = min(max(2 * posteriorMean - 1, 0), 1)\n                        let leadershipEdge = pow(rawLeadershipEdge, max(leadershipEdgeExponent, 0.05))\n                        let migration = minimumLeadershipMigration\n                            + (1 - minimumLeadershipMigration) * leadershipEdge",
        ),
    ]

    for old, new in replacements:
        text = replace_once(text, old, new)

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text, encoding="utf-8")
    print(f"assembled={output} bytes={len(text.encode('utf-8'))}")


if __name__ == "__main__":
    main()
