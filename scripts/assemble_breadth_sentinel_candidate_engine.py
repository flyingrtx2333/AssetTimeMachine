#!/usr/bin/env python3
"""Assemble the latest App engine with the breadth/sentinel candidate.

Research-only: writes a temporary Swift engine and never edits production source.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected one replacement, found {count}: {old[:80]!r}")
    return text.replace(old, new, 1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--base",
        default="AssetTimeMachine/Backtest/BacktestEngine.swift",
    )
    parser.add_argument(
        "--output",
        default="/private/tmp/BacktestEngineBreadthSentinelCandidate.swift",
    )
    args = parser.parse_args()

    text = Path(args.base).read_text(encoding="utf-8")

    # Reduce the three micro breadth brakes to 80% of their production force.
    text = replace_once(
        text,
        "pendingWeights = pendingWeights.mapValues { $0 * 0.91 }",
        "pendingWeights = pendingWeights.mapValues { $0 * 0.928 }",
    )
    text = replace_once(
        text,
        "pendingWeights = pendingWeights.mapValues { $0 * 0.90 }",
        "pendingWeights = pendingWeights.mapValues { $0 * 0.92 }",
    )
    text = replace_once(
        text,
        "pendingWeights = pendingWeights.mapValues { $0 * 0.94 }",
        "pendingWeights = pendingWeights.mapValues { $0 * 0.952 }",
    )

    anchor = """                let gross = pendingWeights.values.reduce(0, +)
                if gross > grossCap, gross > 0 {
"""
    candidate = """                if !previousWeights.isEmpty,
                   baseTargetChanged,
                   pendingWeights.values.reduce(0, +) < 0.05 {
                    let priorGross = previousWeights.values.reduce(0, +)
                    let priorLeader = leaderName(previousWeights)
                    if priorGross >= 0.40,
                       priorGross < 1.01,
                       priorLeader == \"china\",
                       alignedBaseValues.indices.contains(signalIndex),
                       let currentBaseValue = alignedBaseValues[signalIndex],
                       currentBaseValue > 0 {
                        let peakStart = max(0, signalIndex - 251)
                        let peakValue = alignedBaseValues[peakStart...signalIndex]
                            .compactMap { $0 }
                            .max() ?? currentBaseValue
                        let baseDrawdown = peakValue > 0
                            ? max(1 - currentBaseValue / peakValue, 0)
                            : 0
                        var recentBaseReturns: [Double] = []
                        if signalIndex >= 60 {
                            for cursor in (signalIndex - 59)...signalIndex {
                                guard cursor > 0,
                                      let priorValue = alignedBaseValues[cursor - 1],
                                      let value = alignedBaseValues[cursor],
                                      priorValue > 0 else { continue }
                                recentBaseReturns.append(value / priorValue - 1)
                            }
                        }
                        let recentBaseVolatility: Double = {
                            guard recentBaseReturns.count > 1 else { return 0 }
                            let mean = recentBaseReturns.reduce(0, +)
                                / Double(recentBaseReturns.count)
                            let variance = recentBaseReturns.reduce(0.0) {
                                $0 + pow($1 - mean, 2)
                            } / Double(recentBaseReturns.count - 1)
                            return sqrt(max(variance, 0)) * sqrt(252)
                        }()
                        if baseDrawdown < 0.02,
                           recentBaseVolatility >= 0.06,
                           recentBaseVolatility < 0.08 {
                            let priorCSI = previousWeights[\"csi300\"] ?? 0
                            let priorShanghai = previousWeights[\"shanghai_composite\"] ?? 0
                            let priorChina = priorCSI + priorShanghai
                            if priorChina > 0 {
                                let sentinelGross = min(0.05, priorGross)
                                pendingWeights[\"csi300\", default: 0] += sentinelGross
                                    * priorCSI / priorChina
                                pendingWeights[\"shanghai_composite\", default: 0] += sentinelGross
                                    * priorShanghai / priorChina
                            }
                        }
                    }
                }

                let gross = pendingWeights.values.reduce(0, +)
                if gross > grossCap, gross > 0 {
"""
    text = replace_once(text, anchor, candidate)

    output = Path(args.output)
    output.write_text(text, encoding="utf-8")
    print(f"assembled={output} bytes={output.stat().st_size}")


if __name__ == "__main__":
    main()
