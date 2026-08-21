#!/usr/bin/env python3
"""Build the stable catalog for AssetTimeMachine's current daily factor zoo."""
from __future__ import annotations

import copy
import importlib.util
import re
import sys
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict, List, Tuple


REPO_ROOT = Path(__file__).resolve().parents[1]
LAB_PATH = REPO_ROOT / "tools/research-results/daily_alpha_factor_lab.py"
SOURCE_PATH = "tools/research-results/daily_alpha_factor_lab.py"
ASSETS = ["gold", "nasdaq", "sp500", "csi300", "shanghai"]
ASSET_NAMES = {
    "gold": "黄金",
    "nasdaq": "纳斯达克",
    "sp500": "标普 500",
    "csi300": "沪深 300",
    "shanghai": "上证指数",
}
FAMILY_NAMES = {
    "momentum": "动量",
    "volatility": "波动率",
    "downside_vol": "下行波动",
    "drawdown": "区间回撤",
    "trend": "均线距离",
    "trend_efficiency": "趋势效率",
    "relative_strength": "相对强弱",
    "breadth": "市场宽度",
    "dispersion": "横截面离散度",
    "strategy_state": "策略状态",
    "vix": "波动率指数",
    "vix_term": "波动率期限结构",
    "real_yield": "实际利率",
    "risk_adjusted_momentum": "风险调整动量",
}


RAM_FACTORS = [
    {
        "factor_key": "risk_adjusted_momentum_60_20",
        "display_name": "风险调整动量 60/20",
        "family": "risk_adjusted_momentum",
        "research_role": "alpha_candidate",
        "formula_text": "return_60 / realized_volatility_20",
        "parameters": {"return_window": 60, "volatility_window": 20},
        "required_inputs": ["close"],
        "applicable_universe": ASSETS,
        "lookback_sessions": 60,
        "lifecycle_status": "candidate",
    },
    {
        "factor_key": "risk_adjusted_momentum_252_60",
        "display_name": "风险调整动量 252/60",
        "family": "risk_adjusted_momentum",
        "research_role": "alpha_candidate",
        "formula_text": "return_252 / realized_volatility_60",
        "parameters": {"return_window": 252, "volatility_window": 60},
        "required_inputs": ["close"],
        "applicable_universe": ASSETS,
        "lookback_sessions": 252,
        "lifecycle_status": "candidate",
    },
]


def _asset_record(prefix: str, key: str, family: str, formula: str) -> Dict[str, Any]:
    match = re.fullmatch(prefix + r"_(gold|nasdaq|sp500|csi300|shanghai)_(\d+)", key)
    if not match:
        raise ValueError("not matched")
    asset, raw_window = match.groups()
    window = int(raw_window)
    return {
        "display_name": "%s%s %d 日" % (ASSET_NAMES[asset], FAMILY_NAMES[family], window),
        "formula_text": formula.format(asset=asset, window=window),
        "parameters": {"asset": asset, "window": window},
        "required_inputs": ["price_%s" % asset],
        "applicable_universe": [asset],
        "lookback_sessions": window,
    }


def parse_factor_definition(factor_key: str, family: str) -> Dict[str, Any]:
    parsers = [
        ("mom", "momentum", "return({asset}, {window})"),
        ("vol", "volatility", "std(daily_return({asset}), {window})"),
        ("downvol", "downside_vol", "std(min(daily_return({asset}), 0), {window})"),
        ("dd", "drawdown", "price({asset}) / rolling_max(price({asset}), {window}) - 1"),
        ("ma_dist", "trend", "price({asset}) / mean(price({asset}), {window}) - 1"),
        (
            "eff",
            "trend_efficiency",
            "abs(return({asset}, {window})) / sum(abs(daily_return({asset})), {window})",
        ),
    ]
    for prefix, expected_family, formula in parsers:
        if re.fullmatch(prefix + r"_(gold|nasdaq|sp500|csi300|shanghai)_\d+", factor_key):
            if family != expected_family:
                raise ValueError("因子分类与编号不一致: %s" % factor_key)
            return _asset_record(prefix, factor_key, family, formula)

    relative = re.fullmatch(r"rel_(us_gold|us_china|gold_china)_(\d+)", factor_key)
    if relative:
        pair, raw_window = relative.groups()
        window = int(raw_window)
        formulas = {
            "us_gold": "mean(return(nasdaq, {w}), return(sp500, {w})) - return(gold, {w})",
            "us_china": "mean(return(nasdaq, {w}), return(sp500, {w})) - mean(return(csi300, {w}), return(shanghai, {w}))",
            "gold_china": "return(gold, {w}) - mean(return(csi300, {w}), return(shanghai, {w}))",
        }
        inputs = {
            "us_gold": ["price_nasdaq", "price_sp500", "price_gold"],
            "us_china": ["price_nasdaq", "price_sp500", "price_csi300", "price_shanghai"],
            "gold_china": ["price_gold", "price_csi300", "price_shanghai"],
        }
        return {
            "display_name": "%s %d 日" % (FAMILY_NAMES[family], window),
            "formula_text": formulas[pair].format(w=window),
            "parameters": {"pair": pair, "window": window},
            "required_inputs": inputs[pair],
            "applicable_universe": ASSETS,
            "lookback_sessions": window,
        }

    cross_sectional = re.fullmatch(r"(breadth|dispersion)_(\d+)", factor_key)
    if cross_sectional:
        kind, raw_window = cross_sectional.groups()
        window = int(raw_window)
        formula = (
            "share(return(asset, {w}) > 0, five_asset_universe)"
            if kind == "breadth"
            else "std(cross_sectional_return(five_asset_universe, {w}))"
        )
        return {
            "display_name": "%s %d 日" % (FAMILY_NAMES[family], window),
            "formula_text": formula.format(w=window),
            "parameters": {"window": window, "assets": ASSETS},
            "required_inputs": ["price_%s" % asset for asset in ASSETS],
            "applicable_universe": ASSETS,
            "lookback_sessions": window,
        }

    state = re.fullmatch(r"state_(cash_ratio|target_gross|actual_gross|target_gold|target_nasdaq|target_sp500|target_csi300|target_shanghai)", factor_key)
    if state:
        state_key = state.group(1)
        return {
            "display_name": "策略状态 · %s" % state_key.replace("_", " "),
            "formula_text": "strategy_state(%s)" % state_key,
            "parameters": {"state_key": state_key},
            "required_inputs": [state_key],
            "applicable_universe": ["portfolio"],
            "lookback_sessions": 0,
        }

    level_specs = {
        "vix_level": ("VIX 水平", "vix", ["VIXCLS"], 0),
        "vix3m_level": ("VIX3M 水平", "vix3m", ["VXVCLS"], 0),
        "vix_term_ratio": ("VIX 期限比率", "vix / vix3m", ["VIXCLS", "VXVCLS"], 0),
        "vix_term_spread": ("VIX 期限价差", "vix - vix3m", ["VIXCLS", "VXVCLS"], 0),
        "vix_z252": ("VIX 252 日标准分", "zscore(vix, 252)", ["VIXCLS"], 252),
        "vix_pct252": ("VIX 252 日分位", "percentile(vix, 252)", ["VIXCLS"], 252),
        "vixterm_z252": ("VIX 期限比率 252 日标准分", "zscore(vix / vix3m, 252)", ["VIXCLS", "VXVCLS"], 252),
        "real10_level": ("10 年期实际利率", "real_yield_10y", ["DFII10"], 0),
        "real10_z252": ("10 年期实际利率 252 日标准分", "zscore(real_yield_10y, 252)", ["DFII10"], 252),
    }
    if factor_key in level_specs:
        name, formula, inputs, lookback = level_specs[factor_key]
        return {
            "display_name": name,
            "formula_text": formula,
            "parameters": {"window": lookback} if lookback else {},
            "required_inputs": inputs,
            "applicable_universe": ASSETS,
            "lookback_sessions": lookback,
        }

    change = re.fullmatch(r"chg_(vix|vix3m|real10)_(1|5|10|20|60)", factor_key)
    if change:
        source, raw_window = change.groups()
        window = int(raw_window)
        input_key = {"vix": "VIXCLS", "vix3m": "VXVCLS", "real10": "DFII10"}[source]
        source_name = {"vix": "vix", "vix3m": "vix3m", "real10": "real_yield_10y"}[source]
        return {
            "display_name": "%s %d 日变化" % (FAMILY_NAMES[family], window),
            "formula_text": "change(%s, %d)" % (source_name, window),
            "parameters": {"source": source, "window": window},
            "required_inputs": [input_key],
            "applicable_universe": ASSETS,
            "lookback_sessions": window,
        }

    raise ValueError("无法识别因子编号: %s" % factor_key)


@lru_cache(maxsize=1)
def _current_factor_inventory() -> Tuple[Tuple[str, str], ...]:
    spec = importlib.util.spec_from_file_location("asset_time_machine_daily_alpha_factor_lab", LAB_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("无法加载日频因子研究脚本")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    dates, columns = module.read_panel()
    factors, families = module.build_factors(dates, columns)
    if len(factors) != 182 or set(factors) != set(families):
        raise RuntimeError("日频因子目录与分类不完整")
    return tuple(sorted((key, families[key]) for key in factors))


def _decorate_record(factor_key: str, family: str, parsed: Dict[str, Any]) -> Dict[str, Any]:
    role = "control" if family == "strategy_state" else "alpha_candidate"
    return {
        "factor_key": factor_key,
        "display_name": parsed["display_name"],
        "family": family,
        "description": "%s研究因子。" % FAMILY_NAMES[family],
        "tags": [family],
        "research_role": role,
        "owner_name": "AssetTimeMachine",
        "source_project": "AssetTimeMachine",
        "formula_text": parsed["formula_text"],
        "parameters": parsed["parameters"],
        "required_inputs": parsed["required_inputs"],
        "applicable_universe": parsed["applicable_universe"],
        "frequency": "daily",
        "lookback_sessions": parsed["lookback_sessions"],
        "observation_lag_sessions": 1,
        "source_path": SOURCE_PATH,
        "lifecycle_status": "research",
        "materialization_policy": "none",
    }


@lru_cache(maxsize=1)
def _cached_catalog() -> Tuple[Dict[str, Any], ...]:
    records = [
        _decorate_record(key, family, parse_factor_definition(key, family))
        for key, family in _current_factor_inventory()
    ]
    for raw in RAM_FACTORS:
        record = dict(raw)
        record.update(
            {
                "description": "收益动量与已实现波动率之比。",
                "tags": ["risk_adjusted_momentum"],
                "owner_name": "AssetTimeMachine",
                "source_project": "AssetTimeMachine",
                "frequency": "daily",
                "observation_lag_sessions": 1,
                "source_path": "tools/research-results/daily_cross_sectional_factor_lab.py",
                "materialization_policy": "none",
            }
        )
        records.append(record)
    records.sort(key=lambda row: row["factor_key"])
    if len(records) != 184 or len({row["factor_key"] for row in records}) != 184:
        raise RuntimeError("因子目录必须包含 184 个唯一编号")
    return tuple(records)


def build_factor_catalog() -> List[Dict[str, Any]]:
    return copy.deepcopy(list(_cached_catalog()))


if __name__ == "__main__":
    print(len(build_factor_catalog()))
