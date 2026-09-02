#!/usr/bin/env python3
"""Build strategy-library-v2 manifests for the three 2026-09-02 formal FAIL trials."""
from __future__ import annotations

import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT / "tools/research-results/strategy-validation"

CONFIG = {
    "ATM-SVP2-GNR5-001": {
        "candidate_id": "GNR-5",
        "display_name": "黄金纳指冲击反转 GNR-5",
        "family": "gold-nasdaq-reversal",
        "description": "黄金与纳指共同观察日价差收益达到 ±2σ 后切换至单一资产并持有五个共同观察日。",
        "mechanism": "以前60个共同观察价差收益估计样本均值与标准差；当前 z>=2 配置100%纳指，z<=-2配置100%黄金，事件持有五个后续共同观察日。",
        "assets": ["gold_cny", "nasdaq"],
        "source_path": "AssetTimeMachine/Backtest/GNR5ReversalStrategy.swift",
        "metric_key": "app_product_stress",
        "parameters": {"lookback": 60, "z_threshold": 2.0, "hold_common_observations": 5},
    },
    "ATM-SVP2-GOR-QREG-001": {
        "candidate_id": "GOR-QREG-252-63",
        "display_name": "金油比季度状态轮动 252/63",
        "family": "gold-oil-regime-rotation",
        "description": "以金油比相对过去252个共同观察均值的状态，在黄金与纳指之间按63个共同观察日复核轮动。",
        "mechanism": "R=gold_cny/oil_wti_cny；固定共同观察序号每63期复核，R高于前252期均值配黄金，否则配纳指。",
        "assets": ["gold_cny", "nasdaq", "oil_wti_cny", "usd_per_cny"],
        "source_path": "AssetTimeMachine/Backtest/GORQREG25263Strategy.swift",
        "metric_key": "app_product_cost",
        "parameters": {"lookback": 252, "review_step": 63, "threshold": "prior_mean"},
    },
    "ATM-SVP2-MACRO-SAHM-CPI-001": {
        "candidate_id": "MACRO-SAHM-CPI-001",
        "display_name": "Sahm-CPI 月度宏观轮动",
        "family": "macro-regime-allocation",
        "description": "用实时首发 Sahm Rule 与 CPI 同比划分衰退、通胀和增长状态，在黄金、标普与纳指间月度配置。",
        "mechanism": "仅使用冻结的初值发布数据；Sahm>=0.50配标普，非衰退且CPI同比>=2%配黄金，否则配纳指；发布后严格T-1执行。",
        "assets": ["gold_cny", "nasdaq", "sp500", "usd_per_cny", "SAHMREALTIME", "CPIAUCSL"],
        "source_path": "AssetTimeMachine/Backtest/MacroSahmCPIStrategy.swift",
        "metric_key": "app_product_cost",
        "parameters": {"sahm_threshold": 0.5, "cpi_yoy_threshold_percent": 2.0, "freshness_days": 62},
    },
}


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected object: {path}")
    return value


def ledger_results() -> dict[str, tuple[dict[str, Any], str]]:
    found: dict[str, tuple[dict[str, Any], str]] = {}
    for line in (BASE / "trial-ledger.jsonl").read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        payload = record.get("payload") or {}
        trial_id = payload.get("trial_id")
        if record.get("event") == "RESULT" and trial_id in CONFIG:
            found[trial_id] = (payload, record["timestamp"])
    if set(found) != set(CONFIG):
        raise ValueError(f"missing RESULT records: {sorted(set(CONFIG) - set(found))}")
    return found


def build(trial_id: str, cfg: dict[str, Any], result: dict[str, Any], finished_at: str) -> dict[str, Any]:
    run_dir = BASE / "runs" / trial_id
    metrics = load_json(run_dir / "candidate-metrics.json")
    product = metrics[cfg["metric_key"]]
    windows = product["metrics"]
    full = windows["full_history"]
    if result.get("status") != "FAIL" or metrics.get("candidate_id") != cfg["candidate_id"]:
        raise ValueError(f"unexpected trial identity/status: {trial_id}")
    for field in ("cagr_percent", "sharpe", "mdd_percent"):
        if field not in full:
            raise ValueError(f"missing App full-history {field}: {trial_id}")
    execution_path = run_dir / "execution.json"
    started_at = load_json(execution_path).get("started_at") if execution_path.exists() else None
    constraints = product.get("constraints") or {}
    fingerprint = product.get("target_fingerprint") or product.get("schedule_fingerprint")
    prereg = load_json(BASE / "preregistrations" / f"{trial_id}.json")
    manifest = {
        "schema_version": "strategy-library-v2",
        "batch_key": f"{trial_id}-strategy-library-v2",
        "source_repository": "AssetTimeMachine",
        "source_commit": result["execution_git_commit"],
        "run": {
            "run_key": trial_id,
            "title": f"{cfg['display_name']}正式验证",
            "protocol_id": metrics.get("protocol_id") or "ATM-SVP-2",
            "evidence_class": prereg.get("evidence_class"),
            "dataset_manifest": result["dataset_manifest"],
            "artifact_manifest": result["artifact_manifest"],
            "preregistration_hash": result["preregistration_record_hash"],
            "execution_commit": result["execution_git_commit"],
            "status": "FAIL",
            "decision": result["decision"],
            "methodology": {
                "metric_display_basis": "App product cost: 1.00% fee + 0.05% slippage",
                "formal_result_source": "hash-chained trial-ledger RESULT and committed candidate-metrics.json",
                "no_parameter_rescue": True,
            },
            "started_at": started_at,
            "finished_at": finished_at,
        },
        "strategies": [{
            "strategy_key": cfg["candidate_id"],
            "display_name": cfg["display_name"],
            "family": cfg["family"],
            "strategy_kind": "allocation",
            "description": cfg["description"],
            "tags": ["formal", "failed", "permanently-closed", "app-cost"],
            "source_project": "AssetTimeMachine",
            "version": {
                "version_key": f"{cfg['candidate_id'].lower()}-v1",
                "mechanism_text": cfg["mechanism"],
                "parameters": cfg["parameters"],
                "assets": cfg["assets"],
                "source_path": cfg["source_path"],
                "target_fingerprint": fingerprint,
                "lifecycle_status": "rejected",
                "max_gross_limit": 1.0,
                "leverage_allowed": False,
                "shorting_allowed": False,
                "financing_allowed": False,
            },
            "result": {
                "candidate_id": cfg["candidate_id"],
                "result_status": "FAIL",
                "robust_strategy_pass": False,
                "cagr_percent": full["cagr_percent"],
                "sharpe": full["sharpe"],
                "mdd_percent": full["mdd_percent"],
                "since2020_cagr_percent": windows["since_2020"]["cagr_percent"],
                "since2022_cagr_percent": windows["since_2022"]["cagr_percent"],
                "max_gross": constraints.get("max_actual_gross"),
                "metrics": {
                    "strategy_library_validation": {"status": "FAIL", "basis": "formal App-cost product gates"},
                    "display_cost_regime": "App 1.00% fee + 0.05% slippage",
                    "windows": windows,
                },
                "gates": product.get("mechanical_product_gate") or {},
                "constraints": constraints,
                "artifacts": [
                    {"path": str((run_dir / "candidate-metrics.json").relative_to(ROOT))},
                    {"path": result["artifact_manifest"]},
                    {"path": "tools/research-results/strategy-validation/trial-ledger.jsonl"},
                ],
                "conclusion": result["decision"],
            },
        }],
    }
    return manifest


def main() -> int:
    results = ledger_results()
    for trial_id, cfg in CONFIG.items():
        payload, finished_at = results[trial_id]
        manifest = build(trial_id, cfg, payload, finished_at)
        output = BASE / "runs" / trial_id / "strategy-library-import-v2.json"
        output.write_text(json.dumps(manifest, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
        print(output.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
