#!/usr/bin/env python3
"""Summarize the ATM-SVP-2 formal return-seeking research frontier.

This is a diagnostic report only. It does not generate signals, rerun strategies, select
new parameters, or create a new formal trial. It reads already-recorded result JSON files.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
RESULTS = ROOT / "tools/research-results/strategy-validation/results"
V11 = {"candidate_id": "V11-CONTROL", "trial_id": "FROZEN-V11", "cagr_percent": 14.345615, "sharpe": 1.522263, "mdd_percent": 7.689054, "status": "CONTROL", "robust_factor_pass": None}
SKIP_TRIALS = {
    "ATM-SVP2-FACTOR-ROBUST-001",  # duplicates candidates already represented by their originating formal trials
}


def finite_number(value: Any) -> float | None:
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    return number if math.isfinite(number) else None


def load_rows() -> list[dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for path in sorted(RESULTS.glob("ATM-SVP2-*.json")):
        document = json.loads(path.read_text(encoding="utf-8"))
        trial_id = str(document.get("trial_id") or path.stem)
        if trial_id in SKIP_TRIALS:
            continue
        status = str(document.get("status") or "")
        for result in document.get("candidate_results") or []:
            candidate_id = str(result.get("candidate_id") or "")
            metrics = result.get("metrics") or {}
            cagr = finite_number(metrics.get("cagr_percent"))
            sharpe = finite_number(metrics.get("sharpe"))
            mdd = finite_number(metrics.get("mdd_percent"))
            if not candidate_id or cagr is None or sharpe is None or mdd is None:
                continue
            row = {
                "candidate_id": candidate_id,
                "trial_id": trial_id,
                "cagr_percent": cagr,
                "sharpe": sharpe,
                "mdd_percent": mdd,
                "status": status,
                "robust_factor_pass": bool(metrics.get("robust_factor_pass")) if "robust_factor_pass" in metrics else None,
                "bootstrap_probability_cagr_gt_v11": finite_number(metrics.get("bootstrap_probability_cagr_gt_v11")),
                "bootstrap_probability_sharpe_gt_matched": finite_number(metrics.get("bootstrap_probability_sharpe_gt_matched")),
                "global_dsr_probability": finite_number(metrics.get("global_post_protocol_dsr_probability")),
            }
            # Candidate IDs are immutable identities. If a later pure statistical audit appears,
            # it is skipped above; otherwise duplicate formal identities are an error rather than
            # an invitation to select the nicer result.
            if candidate_id in rows:
                raise RuntimeError(f"duplicate candidate_id outside skipped audits: {candidate_id}")
            rows[candidate_id] = row
    return list(rows.values())


def pareto(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    result = []
    for row in rows:
        dominated = False
        for other in rows:
            if other is row:
                continue
            at_least_as_good = (
                other["cagr_percent"] >= row["cagr_percent"]
                and other["sharpe"] >= row["sharpe"]
                and other["mdd_percent"] <= row["mdd_percent"]
            )
            strictly_better = (
                other["cagr_percent"] > row["cagr_percent"]
                or other["sharpe"] > row["sharpe"]
                or other["mdd_percent"] < row["mdd_percent"]
            )
            if at_least_as_good and strictly_better:
                dominated = True
                break
        if not dominated:
            result.append(row)
    return sorted(result, key=lambda row: (row["mdd_percent"], -row["cagr_percent"]))


def best_under(rows: list[dict[str, Any]], mdd_limit: float) -> dict[str, Any] | None:
    eligible = [row for row in rows if row["mdd_percent"] <= mdd_limit]
    return max(eligible, key=lambda row: row["cagr_percent"], default=None)


def pct(value: float | None, digits: int = 3) -> str:
    return "—" if value is None else f"{value:.{digits}f}%"


def num(value: float | None, digits: int = 3) -> str:
    return "—" if value is None else f"{value:.{digits}f}"


def build_report(rows: list[dict[str, Any]]) -> tuple[dict[str, Any], str]:
    universe = [V11, *rows]
    front = pareto(universe)
    risk_limits = {str(limit): best_under(universe, limit) for limit in (8.0, 10.0, 12.0, 15.0, 20.0)}
    max_cagr = max(universe, key=lambda row: row["cagr_percent"])
    max_sharpe = max(universe, key=lambda row: row["sharpe"])
    robust_passes = [row for row in rows if row.get("robust_factor_pass") is True]
    target_20_under_10 = [row for row in universe if row["cagr_percent"] >= 20.0 and row["mdd_percent"] <= 10.0]
    target_18_under_10 = [row for row in universe if row["cagr_percent"] >= 18.0 and row["mdd_percent"] <= 10.0]

    summary = {
        "formal_unique_candidates": len(rows),
        "frozen_control": V11,
        "pareto_frontier": front,
        "best_cagr_by_mdd_limit": risk_limits,
        "max_cagr": max_cagr,
        "max_sharpe": max_sharpe,
        "robust_factor_passes": robust_passes,
        "candidates_ge_20_cagr_and_le_10_mdd": target_20_under_10,
        "candidates_ge_18_cagr_and_le_10_mdd": target_18_under_10,
    }

    ordered = sorted(universe, key=lambda row: (-row["cagr_percent"], row["mdd_percent"], -row["sharpe"]))
    lines = [
        "# ATM-SVP-2 正式研究收益-风险前沿诊断 — 2026-08-22",
        "",
        "状态：**DIAGNOSTIC ONLY — 不构成新 trial，不允许据此回头调已失败候选。**",
        "",
        "本报告只读取已经落账的正式结果 JSON，并加入冻结 V11 控制线。它用于回答“当前正式证据距离高收益目标还有多远”，不生成新信号、不搜索参数。",
        "",
        "## 核心结论",
        "",
        f"- 唯一正式候选数：**{len(rows)}**；另加冻结 V11 控制。",
        f"- 全部正式记录中最高 CAGR：**{pct(max_cagr['cagr_percent'])}**（{max_cagr['candidate_id']}），对应 MDD **{pct(max_cagr['mdd_percent'])}**、Sharpe **{num(max_cagr['sharpe'])}**。",
        f"- 最高 Sharpe：**{num(max_sharpe['sharpe'])}**（{max_sharpe['candidate_id']}），CAGR **{pct(max_sharpe['cagr_percent'])}**、MDD **{pct(max_sharpe['mdd_percent'])}**。",
        f"- `CAGR >=20% 且 MDD <=10%`：**{len(target_20_under_10)} 个**。",
        f"- `CAGR >=18% 且 MDD <=10%`：**{len(target_18_under_10)} 个**。",
        f"- 当前 formal result 中 `robust_factor_pass=true`：**{len(robust_passes)} 个**。",
        "",
        "## 最大回撤约束下的最高历史 CAGR",
        "",
        "| MDD 上限 | 最高 CAGR | 候选 | MDD | Sharpe |",
        "|---:|---:|---|---:|---:|",
    ]
    for limit in (8.0, 10.0, 12.0, 15.0, 20.0):
        row = risk_limits[str(limit)]
        if row is None:
            lines.append(f"| {limit:.0f}% | — | — | — | — |")
        else:
            lines.append(f"| {limit:.0f}% | {pct(row['cagr_percent'])} | {row['candidate_id']} | {pct(row['mdd_percent'])} | {num(row['sharpe'])} |")

    lines.extend([
        "",
        "## 三维 Pareto 前沿（高 CAGR / 高 Sharpe / 低 MDD）",
        "",
        "| 候选 | CAGR | MDD | Sharpe | Trial |",
        "|---|---:|---:|---:|---|",
    ])
    for row in front:
        lines.append(f"| {row['candidate_id']} | {pct(row['cagr_percent'])} | {pct(row['mdd_percent'])} | {num(row['sharpe'])} | {row['trial_id']} |")

    lines.extend([
        "",
        "## 全部正式候选（按 CAGR 降序）",
        "",
        "| 候选 | CAGR | MDD | Sharpe | Robust | Trial |",
        "|---|---:|---:|---:|---|---|",
    ])
    for row in ordered:
        robust = "CONTROL" if row["candidate_id"] == "V11-CONTROL" else ("PASS" if row.get("robust_factor_pass") else "NO")
        lines.append(f"| {row['candidate_id']} | {pct(row['cagr_percent'])} | {pct(row['mdd_percent'])} | {num(row['sharpe'])} | {robust} | {row['trial_id']} |")

    lines.extend([
        "",
        "## 解释",
        "",
        "正式研究样本里，没有任何候选同时达到 18%/20% 年化与 <=10% 最大回撤。这个事实不证明数学上绝无可能，但它说明在当前资产集合、long-only/无融资约束、现有 V11 周边 overlay 架构下，继续做小参数变化缺乏证据基础。",
        "",
        "下一轮应优先研究**新的独立收益源或新数据域**，而不是再扩大原有事件保留比例、lookback、threshold 或 gross 微调。任何新候选仍需按 ATM-SVP-2 先冻结再运行。",
        "",
    ])
    return summary, "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json-output", required=True)
    parser.add_argument("--md-output", required=True)
    args = parser.parse_args()
    rows = load_rows()
    summary, markdown = build_report(rows)
    json_path = ROOT / args.json_output
    md_path = ROOT / args.md_output
    json_path.parent.mkdir(parents=True, exist_ok=True)
    md_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    md_path.write_text(markdown, encoding="utf-8")
    print(json.dumps({
        "formal_unique_candidates": summary["formal_unique_candidates"],
        "max_cagr": summary["max_cagr"],
        "max_sharpe": summary["max_sharpe"],
        "ge20_under10": len(summary["candidates_ge_20_cagr_and_le_10_mdd"]),
        "ge18_under10": len(summary["candidates_ge_18_cagr_and_le_10_mdd"]),
    }, ensure_ascii=False, sort_keys=True))
    print("FORMAL_RESEARCH_FRONTIER_COMPLETE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
