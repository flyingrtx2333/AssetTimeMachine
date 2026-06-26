#!/usr/bin/env python3
"""Batch-run all App strategy templates and print a summary table."""
from __future__ import annotations

import importlib.util
import math
import sys
from dataclasses import replace
from datetime import date
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / "tools"
sys.path.insert(0, str(TOOLS))

import atm_app_equivalent_backtest as app  # noqa: E402


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"failed to load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def pct(value: float | None, digits: int = 2) -> str:
    if value is None or not math.isfinite(value):
        return "n/a"
    return f"{value * 100:.{digits}f}%"


def sharpe(value: float | None) -> str:
    if value is None or not math.isfinite(value):
        return "n/a"
    return f"{value:.3f}"


def row(
    category: str,
    title: str,
    strategy_id: str,
    annualized: float | None,
    max_dd: float | None,
    vol: float | None,
    sharpe_ratio: float | None,
    coverage: str,
    source: str,
) -> dict[str, Any]:
    return {
        "category": category,
        "title": title,
        "id": strategy_id,
        "annualized": annualized,
        "max_drawdown": max_dd,
        "volatility": vol,
        "sharpe": sharpe_ratio,
        "coverage": coverage,
        "source": source,
    }


def run_app_rotation(name: str) -> app.BacktestResult:
    return app.run_strategy(name)


def run_monthly_heat_capped() -> app.BacktestResult:
    original = app.strategy_config

    def patched(strategy: str) -> app.Config:
        if strategy != "coreGoldSatelliteMonthlyHeatCappedMomentum":
            return original(strategy)
        base = original("coreGoldSatelliteHeatCappedMomentum")
        overlay = base.gold_satellite_overlay
        assert overlay is not None
        cap = overlay.single_asset_exposure_cap
        assert cap is not None
        new_overlay = replace(
            overlay,
            single_asset_exposure_cap=replace(cap, max_weight=0.72),
        )
        return replace(
            base,
            name="coreGoldSatelliteMonthlyHeatCappedMomentum",
            rebalance_sessions=30,
            gold_satellite_overlay=new_overlay,
        )

    app.strategy_config = patched  # type: ignore[assignment]
    try:
        return app._run_strategy_core("coreGoldSatelliteMonthlyHeatCappedMomentum")
    finally:
        app.strategy_config = original  # type: ignore[assignment]


def run_basic_strategies() -> list[dict[str, Any]]:
    basic = load_module("search_basic_advanced", TOOLS / "search_basic_advanced_strategies.py")
    # Match App defaults: 1% fee, 0.05% slippage, 100k initial, 4 assets equal split.
    basic.FEE_RATE = 0.01
    basic.SLIPPAGE_RATE = 0.0005
    basic.COOLDOWN_DAYS = 0
    basic.STOP_LOSS = 0.0
    basic.TAKE_PROFIT = 0.0

    from search_basic_advanced_strategies import RuleKey  # noqa: WPS433

    series = basic.load_data()
    fx = basic.make_fx_lookup(series["usd_per_cny"])
    assets = ("gold_cny", "nasdaq", "sp500", "csi300")
    points = {sym: basic.normalize_asset(sym, series[sym], fx) for sym in assets}
    signals = {sym: basic.precompute_signals(pts) for sym, pts in points.items()}

    templates = [
        ("基础策略", "MA20趋势", "basic-ma20-trend", "priceCrossesAboveMA20", 1, "priceCrossesBelowMA20", 1),
        ("基础策略", "MA60趋势", "basic-ma60-trend", "priceAboveMA60", 1, "priceBelowMA60", 1),
        ("基础策略", "MA金叉死叉", "basic-ma-golden-cross", "ma20CrossesAboveMA60", 1, "ma20CrossesBelowMA60", 1),
        ("基础策略", "BOLL下轨反弹", "basic-boll-mean-reversion", "touchesBollLower", 1, "priceCrossesAboveBollMiddle", 1),
    ]

    out: list[dict[str, Any]] = []
    per_asset_cash = 100_000.0 / len(assets)
    trade_amount = 100_000.0
    for category, title, sid, buy, buy_days, sell, sell_days in templates:
        key = RuleKey(buy, buy_days, buy, sell, sell_days, sell, trade_amount, 100)
        res = [basic.run_single(points[sym], signals[sym], key, per_asset_cash) for sym in assets]
        dates, vals = basic.align_sum(res)
        m = basic.metrics(dates, vals)
        if not m:
            continue
        out.append(
            row(
                category,
                title,
                sid,
                m["annualized"],
                m["max_drawdown"],
                m["volatility"],
                m["sharpe"],
                f"{dates[0]}..{dates[-1]}",
                "python-basic-app-params",
            )
        )
    return out


def run_canary() -> dict[str, Any]:
    canary = load_module("canary_app_logic", ROOT / "spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py")
    canary.RAW = ["gold_cny", "nasdaq_composite", "sp500", "dow_jones", "csi300", "shanghai_composite", "usd_per_cny"]
    canary.FEE = 0.01
    canary.SLIP = 0.0005
    dates, prices = canary.align(canary.fetch())
    cfg = canary.base_cfg()
    vals, _, _ = canary.simulate(dates, prices, cfg)
    m = canary.metrics(dates, vals)
    return row(
        "高级策略",
        "双金丝雀动量防守",
        "canary-momentum-defense",
        m["ann"],
        m["dd"],
        m["vol"],
        m["sharpe"],
        f"{dates[0]}..{dates[-1]}",
        "spike-canary-app-logic",
    )


def run_spike_best(module_path: Path, runner_name: str, category: str, title: str, sid: str, source: str) -> dict[str, Any]:
    mod = load_module(module_path.stem, module_path)
    data = mod.t47.precompute_targets() if hasattr(mod, "t47") else None
    if data is None and hasattr(mod, "s062"):
        data = mod.s062.t47.precompute_targets()
    if hasattr(mod, runner_name):
        result = getattr(mod, runner_name)()
    else:
        raise RuntimeError(f"{module_path} missing {runner_name}")
    if isinstance(result, dict) and "full" in result:
        full = result["full"]
        coverage = result.get("coverage", {})
        cov = f"{coverage.get('start', '?')}..{coverage.get('end', '?')}"
        return row(category, title, sid, full["annualized"], full["max_drawdown"], full.get("annual_volatility"), full["sharpe"], cov, source)
    raise RuntimeError(f"unexpected result from {module_path}")


def run_dynamic_sleeve() -> dict[str, Any]:
    spike_dir = ROOT / "spikes/047-dynamic-sleeve-selector"
    sys.path.insert(0, str(spike_dir))
    verify = load_module("verify_best_target_selector", spike_dir / "verify_best_target_selector.py")
    search = load_module("target_replay_search", spike_dir / "target_replay_search.py")
    original_fetch = search.app.fetch_public_history
    cached_fetch = search.cached_public_history_factory(original_fetch)
    search.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    search.replay.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    search.s35.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    search.s30.app.fetch_public_history = cached_fetch  # type: ignore[assignment]
    search.replay.SHARED_DATA = None
    try:
        data = search.precompute_targets()
        values, extra, trades = search.simulate(data, verify.BEST_SELECTOR)
        result = search.row_for(data, verify.BEST_SELECTOR, values, extra, trades)
    finally:
        search.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        search.replay.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        search.s35.app.fetch_public_history = original_fetch  # type: ignore[assignment]
        search.s30.app.fetch_public_history = original_fetch  # type: ignore[assignment]
    full = result["full"]
    return row(
        "高级策略",
        "动态袖套夏普策略",
        "core-gold-satellite-dynamic-sleeve-momentum",
        full["annualized"],
        full["max_drawdown"],
        full.get("annual_volatility"),
        full["sharpe"],
        f"{data['dates'][0]}..{data['dates'][-1]}",
        "spike-047-target-replay",
    )


def run_contagion_chain() -> list[dict[str, Any]]:
    s060 = load_module("contagion_060", ROOT / "spikes/060-contagion-controlled-global-repair/contagion_controlled_global_repair.py")
    s061 = load_module("currency_061", ROOT / "spikes/061-currency-cash-selector/currency_cash_selector.py")
    s062 = load_module("gold_panic_062", ROOT / "spikes/062-gold-panic-premium-lock/gold_panic_premium_lock.py")
    s063 = load_module("risk_eff_063", ROOT / "spikes/063-risk-efficiency-governor/risk_efficiency_governor.py")

    original_fetch = s060.app.fetch_public_history
    cached_fetch = s060.t47.cached_public_history_factory(original_fetch)
    for mod in (s060, s060.replay, s060.s35, s060.s30, s060.repair, s060.repair.replay, s060.repair.s35, s060.repair.s30, s060.phase, s060.phase.replay, s060.phase.s35, s060.phase.s30, s060.g59, s060.g59.replay, s060.g59.s35, s060.g59.s30):
        if hasattr(mod, "fetch_public_history"):
            mod.fetch_public_history = cached_fetch  # type: ignore[assignment]
    try:
        data = s060.t47.precompute_targets()
        data = s060.g59.add_extra_series(data, ["hang_seng", "nikkei225", "oil_wti_cny"])
        data_with_usd_cash = s061.add_usd_cash_series(data)
        rows = []
        best_060 = s060.specs()[0]
        values, extra, trades, _ = s060.simulate(data, best_060)
        r060 = s060.row_for(data, best_060, values, extra, trades, [])
        rows.append(row("高级策略", "全球修复传染控制", "core-gold-satellite-contagion-repair-momentum", r060["full"]["annualized"], r060["full"]["max_drawdown"], r060["full"].get("annual_volatility"), r060["full"]["sharpe"], f"{data['dates'][0]}..{data['dates'][-1]}", "spike-060-live"))

        cspec = s062.currency_best()
        r061 = s061.run_currency_spec(data_with_usd_cash, cspec)
        rows.append(row("高级策略", "美元现金修复策略", "core-gold-satellite-currency-cash-momentum", r061["full"]["annualized"], r061["full"]["max_drawdown"], r061["full"].get("annual_volatility"), r061["full"]["sharpe"], f"{data_with_usd_cash['dates'][0]}..{data_with_usd_cash['dates'][-1]}", "spike-061-live"))

        gspec = s063.gold_best()
        r062 = s062.run_gold_spec(data_with_usd_cash, gspec)
        rows.append(row("高级策略", "黄金恐慌锁盈策略", "core-gold-satellite-gold-panic-lock-momentum", r062["full"]["annualized"], r062["full"]["max_drawdown"], r062["full"].get("annual_volatility"), r062["full"]["sharpe"], f"{data_with_usd_cash['dates'][0]}..{data_with_usd_cash['dates'][-1]}", "spike-062-live"))

        r063 = s063.run_governor_spec(data_with_usd_cash, s063.specs()[0])
        rows.append(row("高级策略", "风险效率增强策略", "core-gold-satellite-risk-efficiency-momentum", r063["full"]["annualized"], r063["full"]["max_drawdown"], r063["full"].get("annual_volatility"), r063["full"]["sharpe"], f"{data_with_usd_cash['dates'][0]}..{data_with_usd_cash['dates'][-1]}", "spike-063-live"))
        return rows
    finally:
        for mod in (s060, s060.replay, s060.s35, s060.s30):
            mod.fetch_public_history = original_fetch  # type: ignore[assignment]


def main() -> None:
    # Cache market history once for app-equivalent runs.
    cache: dict[date | None, dict[str, list[tuple[date, float]]]] = {}
    original_fetch = app.fetch_public_history

    def cached_fetch(end_date: date | None = None):
        key = end_date
        if key not in cache:
            cache[key] = original_fetch(end_date=end_date)
        return cache[key]

    app.fetch_public_history = cached_fetch  # type: ignore[assignment]

    results: list[dict[str, Any]] = []

    rotation_templates = [
        ("高级策略", "热度上限元策略", "core-gold-satellite-heat-capped-momentum", "coreGoldSatelliteHeatCappedMomentum"),
        ("高级策略", "黄金交接保护", "core-gold-satellite-gold-handoff-momentum", "coreGoldSatelliteGoldHandoffMomentum"),
        ("高级策略", "单向控波元策略", "core-gold-satellite-one-way-vol-managed-momentum", "coreGoldSatelliteOneWayVolManagedMomentum"),
    ]
    for category, title, sid, mode in rotation_templates:
        r = run_app_rotation(mode)
        results.append(row(category, title, sid, r.annualized_return, r.max_drawdown, r.annualized_volatility, r.sharpe_ratio, f"{r.coverage_start}..{r.coverage_end}", "atm_app_equivalent_backtest"))

    monthly = run_monthly_heat_capped()
    results.append(row("高级策略", "月度热度上限元", "core-gold-satellite-monthly-heat-capped-momentum", monthly.annualized_return, monthly.max_drawdown, monthly.annualized_volatility, monthly.sharpe_ratio, f"{monthly.coverage_start}..{monthly.coverage_end}", "atm_app_equivalent-monthly-proxy"))

    results.extend(run_basic_strategies())
    results.append(run_canary())
    results.append(run_dynamic_sleeve())
    results.extend(run_contagion_chain())

    # Confirmed excess has no Python parity yet.
    results.append(
        row(
            "高级策略",
            "增强热度上限元",
            "core-gold-satellite-confirmed-excess-momentum",
            None,
            None,
            None,
            None,
            "n/a",
            "App-only (no python parity)",
        )
    )

    app.fetch_public_history = original_fetch  # type: ignore[assignment]

    # Sort: advanced first by sharpe desc, then basics
    advanced = [r for r in results if r["category"] == "高级策略" and r["sharpe"] is not None]
    basic = [r for r in results if r["category"] == "基础策略"]
    missing = [r for r in results if r["sharpe"] is None and r not in basic]
    advanced.sort(key=lambda r: r["sharpe"] or -999, reverse=True)
    basic.sort(key=lambda r: r["sharpe"] or -999, reverse=True)

    print("STRATEGY_SUMMARY")
    print(f"{'类别':<8} {'策略':<18} {'年化':>8} {'最大回撤':>8} {'波动':>8} {'夏普':>7} {'区间'}")
    print("-" * 100)
    for r in advanced + basic + missing:
        print(
            f"{r['category']:<8} {r['title']:<18} {pct(r['annualized']):>8} {pct(r['max_drawdown']):>8} "
            f"{pct(r['volatility']):>8} {sharpe(r['sharpe']):>7} {r['coverage']}"
        )


if __name__ == "__main__":
    main()
