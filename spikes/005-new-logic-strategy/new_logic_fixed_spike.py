#!/usr/bin/env python3
from __future__ import annotations

import datetime as dt
import importlib.util
import json
import math
import statistics
import sys
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
sc_path = ROOT / "spikes/004-no-btc-app-like-strategy-search/search_canary_app_logic.py"
spec = importlib.util.spec_from_file_location("sc", sc_path)
SC = importlib.util.module_from_spec(spec)
sys.modules["sc"] = SC
spec.loader.exec_module(SC)  # type: ignore

ASSETS = SC.ASSETS
START = 100_000.0
FEE = 0.001
SLIP = 0.0005
BAND = 0.02
OUT = Path("/tmp/atm_new_logic_fixed_spike.json")

STRESS = {
    "2008金融危机": (dt.date(2007, 10, 1), dt.date(2009, 3, 31)),
    "2015A股冲击": (dt.date(2015, 6, 1), dt.date(2016, 2, 29)),
    "2020疫情": (dt.date(2020, 2, 1), dt.date(2020, 4, 30)),
    "2022通胀加息": (dt.date(2022, 1, 1), dt.date(2022, 12, 31)),
    "2026AI波动": (dt.date(2025, 12, 1), None),
}


def pct(x: float | None) -> str:
    return "n/a" if x is None else f"{x*100:.2f}%"


def ma(prices: dict[str, list[float]], s: str, i: int, n: int) -> float | None:
    if i - n + 1 < 0:
        return None
    return sum(prices[s][i - n + 1 : i + 1]) / n


def mom(prices: dict[str, list[float]], s: str, i: int, n: int) -> float | None:
    if i - n < 0 or prices[s][i - n] <= 0:
        return None
    return prices[s][i] / prices[s][i - n] - 1


def dd_from_high(prices: dict[str, list[float]], s: str, i: int, n: int) -> float | None:
    if i - n + 1 < 0:
        return None
    high = max(prices[s][i - n + 1 : i + 1])
    return prices[s][i] / high - 1 if high > 0 else None


def vol(prices: dict[str, list[float]], s: str, i: int, n: int) -> float | None:
    if i - n < 1:
        return None
    rs = []
    arr = prices[s]
    for j in range(i - n + 1, i + 1):
        if arr[j - 1] <= 0:
            return None
        rs.append(arr[j] / arr[j - 1] - 1)
    if len(rs) < 5:
        return None
    mean = sum(rs) / len(rs)
    var = sum((x - mean) ** 2 for x in rs) / len(rs)
    return math.sqrt(max(var, 0)) * math.sqrt(252)


def above(prices: dict[str, list[float]], s: str, i: int, n: int) -> bool:
    m = ma(prices, s, i, n)
    return m is not None and prices[s][i] > m


def gold_healthy(prices: dict[str, list[float]], i: int) -> bool:
    # Store-of-value role is valid only if gold is trending and not breaking after a blowoff.
    m120 = mom(prices, "gold_cny", i, 120)
    m252 = mom(prices, "gold_cny", i, 252)
    d20 = dd_from_high(prices, "gold_cny", i, 20)
    d60 = dd_from_high(prices, "gold_cny", i, 60)
    blowoff_break = (m252 is not None and m252 > 0.25 and d20 is not None and d20 < -0.045) or (
        m120 is not None and m120 > 0.14 and d60 is not None and d60 < -0.09
    )
    return above(prices, "gold_cny", i, 200) and (m120 or -9) > 0 and not blowoff_break


def equity_healthy(prices: dict[str, list[float]], i: int) -> bool:
    return (
        above(prices, "nasdaq", i, 200)
        and above(prices, "sp500", i, 200)
        and (mom(prices, "nasdaq", i, 120) or -9) > 0
        and (mom(prices, "sp500", i, 120) or -9) > 0
        and (vol(prices, "nasdaq", i, 60) or 9) < 0.34
    )


def normalize(w: dict[str, float], cap: float = 0.95) -> dict[str, float]:
    out = {s: max(0.0, v) for s, v in w.items() if v > 0.0001}
    sm = sum(out.values())
    if sm > cap and sm > 0:
        out = {s: v * cap / sm for s, v in out.items()}
    return out


class State:
    def __init__(self) -> None:
        self.in_crisis = False
        self.crisis_until = -1
        self.last_label = "cash"
        self.current_value = START
        self.peak_value = START


def lifecycle_target(dates: list[dt.date], prices: dict[str, list[float]], i: int, st: State) -> dict[str, float]:
    ndd60 = dd_from_high(prices, "nasdaq", i, 60) or 0
    ndd252 = dd_from_high(prices, "nasdaq", i, 252) or 0
    nv60 = vol(prices, "nasdaq", i, 60) or 0
    # Crisis is a structural regime, not a one-day signal.
    crisis_trigger = (not above(prices, "nasdaq", i, 200)) or ndd60 < -0.12 or nv60 > 0.36
    if crisis_trigger:
        st.in_crisis = True
        st.crisis_until = max(st.crisis_until, i + 40)
    recover = above(prices, "nasdaq", i, 120) and (mom(prices, "nasdaq", i, 60) or -9) > 0.05 and nv60 < 0.30
    if st.in_crisis and i > st.crisis_until and recover:
        st.in_crisis = False
    if not st.in_crisis and equity_healthy(prices, i):
        # Healthy lifecycle: growth dominates, but leave cash because drawdown target is strict.
        if (mom(prices, "nasdaq", i, 120) or 0) > (mom(prices, "sp500", i, 120) or 0):
            w = {"nasdaq": 0.52, "sp500": 0.18}
        else:
            w = {"sp500": 0.55, "nasdaq": 0.15}
        if gold_healthy(prices, i):
            w["gold_cny"] = 0.15
        return normalize(w, 0.85)
    if st.in_crisis and recover:
        return normalize({"nasdaq": 0.28, "sp500": 0.22, "gold_cny": 0.20 if gold_healthy(prices, i) else 0.0}, 0.70)
    if gold_healthy(prices, i):
        return normalize({"gold_cny": 0.55}, 0.55)
    return {}


def crash_reentry_target(dates: list[dt.date], prices: dict[str, list[float]], i: int, st: State) -> dict[str, float]:
    nd252 = dd_from_high(prices, "nasdaq", i, 252) or 0
    sd252 = dd_from_high(prices, "sp500", i, 252) or 0
    n20 = mom(prices, "nasdaq", i, 20) or -9
    s20 = mom(prices, "sp500", i, 20) or -9
    nv20 = vol(prices, "nasdaq", i, 20) or 9
    broad_damage = nd252 < -0.14 or sd252 < -0.12
    falling_knife = n20 < -0.03 or s20 < -0.025 or nv20 > 0.55
    reentry = broad_damage and not falling_knife and above(prices, "sp500", i, 60) and n20 > 0.02
    healthy = equity_healthy(prices, i)
    if reentry:
        return normalize({"nasdaq": 0.50, "sp500": 0.25}, 0.75)
    if healthy:
        return normalize({"sp500": 0.30, "nasdaq": 0.20, "gold_cny": 0.15 if gold_healthy(prices, i) else 0.0}, 0.65)
    if gold_healthy(prices, i):
        return normalize({"gold_cny": 0.45}, 0.45)
    return {}


def role_switch_target(dates: list[dt.date], prices: dict[str, list[float]], i: int, st: State) -> dict[str, float]:
    candidates = []
    for s in ["nasdaq", "sp500", "gold_cny"]:
        m120 = mom(prices, s, i, 120)
        m252 = mom(prices, s, i, 252)
        v60 = vol(prices, s, i, 60) or 0.18
        if m120 is None or m252 is None or not above(prices, s, i, 200):
            continue
        if s in ("nasdaq", "sp500") and v60 > 0.36:
            continue
        if s == "gold_cny" and not gold_healthy(prices, i):
            continue
        score = 0.65 * m120 + 0.35 * m252 - 0.35 * v60
        candidates.append((score, s))
    candidates.sort(reverse=True)
    if not candidates or candidates[0][0] <= 0:
        return {}
    s = candidates[0][1]
    if s == "nasdaq":
        return normalize({"nasdaq": 0.62, "sp500": 0.13}, 0.75)
    if s == "sp500":
        return normalize({"sp500": 0.65}, 0.65)
    return normalize({"gold_cny": 0.60}, 0.60)


def dominant_asset(prices: dict[str, list[float]], i: int) -> str | None:
    candidates = []
    for s in ["nasdaq", "sp500", "gold_cny"]:
        if not above(prices, s, i, 200):
            continue
        if s == "gold_cny" and not gold_healthy(prices, i):
            continue
        if s in ("nasdaq", "sp500") and (vol(prices, s, i, 60) or 9) > 0.38:
            continue
        m120 = mom(prices, s, i, 120)
        m252 = mom(prices, s, i, 252)
        if m120 is None or m252 is None or m120 <= 0:
            continue
        score = 0.70 * m120 + 0.30 * m252 - 0.20 * (vol(prices, s, i, 60) or 0.18)
        candidates.append((score, s))
    candidates.sort(reverse=True)
    return candidates[0][1] if candidates and candidates[0][0] > 0 else None


def capital_floor_target(dates: list[dt.date], prices: dict[str, list[float]], i: int, st: State) -> dict[str, float]:
    # 完全不同机制：先维护 90% 高水位本金地板，再用“地板之上”的 cushion 决定仓位。
    # 亏损扩大时不是等信号慢慢变坏，而是仓位机械收缩。
    st.peak_value = max(st.peak_value, st.current_value)
    floor = 0.90 * st.peak_value
    cushion = max(st.current_value - floor, 0.0) / max(st.current_value, 1.0)
    risk_budget = min(0.85, 5.0 * cushion)
    if risk_budget < 0.08:
        return {}
    asset = dominant_asset(prices, i)
    if asset is None:
        return {}
    if asset == "gold_cny":
        return normalize({"gold_cny": min(risk_budget, 0.55)}, 0.55)
    if asset == "nasdaq":
        return normalize({"nasdaq": risk_budget * 0.78, "sp500": risk_budget * 0.22}, 0.85)
    return normalize({"sp500": risk_budget}, 0.85)


def volatility_budget_target(dates: list[dt.date], prices: dict[str, list[float]], i: int, st: State) -> dict[str, float]:
    # 完全不同机制：先选唯一有效角色，再按该资产波动率消耗固定风险预算。
    asset = dominant_asset(prices, i)
    if asset is None:
        return {}
    v = max(vol(prices, asset, i, 60) or 0.18, 0.06)
    target_vol = 0.075
    weight = min(0.85, target_vol / v)
    if asset == "gold_cny":
        return normalize({"gold_cny": min(weight, 0.60)}, 0.60)
    if asset == "nasdaq":
        return normalize({"nasdaq": weight * 0.75, "sp500": weight * 0.25}, 0.85)
    return normalize({"sp500": weight}, 0.85)


def repair_window_target(dates: list[dt.date], prices: dict[str, list[float]], i: int, st: State) -> dict[str, float]:
    # 新机制：事件窗口收割。
    # 不长期持有趋势；只在“权益修复窗口”或“黄金健康上升窗口”下注。
    # 修复窗口定义：经历过足够下跌，但短中期已经停止恶化，适合吃反弹/修复，而不是抄正在下落的刀。
    n_dd252 = dd_from_high(prices, "nasdaq", i, 252) or 0
    s_dd252 = dd_from_high(prices, "sp500", i, 252) or 0
    n20 = mom(prices, "nasdaq", i, 20) or -9
    n60 = mom(prices, "nasdaq", i, 60) or -9
    s20 = mom(prices, "sp500", i, 20) or -9
    n_vol = vol(prices, "nasdaq", i, 20) or 9
    n_break = dd_from_high(prices, "nasdaq", i, 20) or 0
    damaged = n_dd252 < -0.18 or s_dd252 < -0.14
    repair = damaged and n20 > 0.035 and s20 > 0.02 and n60 > -0.03 and n_vol < 0.45 and n_break > -0.055
    # 平稳牛市窗口：只在指数处于健康推进且近期没有急跌时参与，不在模糊横盘里消耗回撤。
    smooth_bull = equity_healthy(prices, i) and n_break > -0.045 and n_vol < 0.28
    if repair:
        return normalize({"nasdaq": 0.48, "sp500": 0.27}, 0.75)
    if smooth_bull:
        return normalize({"nasdaq": 0.38, "sp500": 0.27}, 0.65)
    # 黄金只作为独立收益窗口，不作为无脑防守；一旦自身短期破坏就不用。
    g20dd = dd_from_high(prices, "gold_cny", i, 20) or 0
    g60 = mom(prices, "gold_cny", i, 60) or -9
    if gold_healthy(prices, i) and g20dd > -0.035 and g60 > 0.02:
        return normalize({"gold_cny": 0.50}, 0.50)
    return {}


def dual_mandate_target(dates: list[dt.date], prices: dict[str, list[float]], i: int, st: State) -> dict[str, float]:
    # 新机制：先判断“收益任务”还是“保本任务”。组合距离高水位>6% 时进入保本任务，
    # 只允许现金或黄金健康窗口；恢复高水位附近后才重新寻找权益窗口。
    st.peak_value = max(st.peak_value, st.current_value)
    pf_dd = st.current_value / st.peak_value - 1 if st.peak_value > 0 else 0
    if pf_dd < -0.06:
        g20dd = dd_from_high(prices, "gold_cny", i, 20) or 0
        if gold_healthy(prices, i) and g20dd > -0.035:
            return normalize({"gold_cny": 0.35}, 0.35)
        return {}
    # 收益任务下，也只吃明确窗口。
    return repair_window_target(dates, prices, i, st)


def simulate(name: str, dates: list[dt.date], prices: dict[str, list[float]], target_fn: Callable) -> dict:
    cash = START
    units = {s: 0.0 for s in ASSETS}
    values: list[float] = []
    weights_after: list[dict[str, float]] = []
    trades = 0
    st = State()
    state_counts: dict[str, int] = {}

    def pv(i: int) -> float:
        return cash + sum(units[s] * prices[s][i] for s in ASSETS)

    for i, day in enumerate(dates):
        if i > 0 and cash > 0:
            cash += cash * SC.cash_daily(dates[i - 1])
        if i > 260:
            sig = i - 1
            st.current_value = pv(i)
            st.peak_value = max(st.peak_value, st.current_value)
            target = target_fn(dates, prices, sig, st)
            state_counts[st.last_label] = state_counts.get(st.last_label, 0) + 1
            cur_val = pv(i)
            # Sell first.
            for s in ASSETS:
                cur = units[s] * prices[s][i]
                tgt = cur_val * target.get(s, 0.0)
                if cur > tgt * (1 + BAND):
                    sell_units = min(units[s], (cur - tgt) / prices[s][i])
                    if sell_units > 1e-12:
                        gross = sell_units * prices[s][i] * (1 - SLIP)
                        cash += gross * (1 - FEE)
                        units[s] -= sell_units
                        trades += 1
            # Buy after sell.
            cur_val = pv(i)
            for s in ASSETS:
                cur = units[s] * prices[s][i]
                tgt = cur_val * target.get(s, 0.0)
                if cur < tgt * (1 - BAND):
                    amount = min(cash, max(tgt - cur, 0.0))
                    if amount > 1:
                        units[s] += amount * (1 - FEE) / (prices[s][i] * (1 + SLIP))
                        cash -= amount
                        trades += 1
        val = pv(i)
        values.append(val)
        weights_after.append({s: units[s] * prices[s][i] / val for s in ASSETS if val > 0 and units[s] * prices[s][i] / val > 0.0001})
    return {
        "name": name,
        "values": values,
        "weights": weights_after,
        "trades": trades,
        "latest": weights_after[-1],
        "cash_pct": max(0, 1 - sum(weights_after[-1].values())),
        "state_counts": state_counts,
    }


def metrics(dates: list[dt.date], values: list[float], start: dt.date | None = None, end: dt.date | None = None) -> dict | None:
    if start is None:
        start = dates[0]
    if end is None:
        end = dates[-1]
    lo = 0
    while lo < len(dates) and dates[lo] < start:
        lo += 1
    hi = len(dates)
    while hi > 0 and dates[hi - 1] > end:
        hi -= 1
    if hi - lo < 30:
        return None
    ds = dates[lo:hi]
    vs = values[lo:hi]
    peak = vs[0]
    dd = 0.0
    rs = []
    for a, b in zip(vs, vs[1:]):
        if a > 0 and b > 0:
            rs.append(b / a - 1)
        peak = max(peak, b)
        dd = max(dd, 1 - b / peak)
    years = max((ds[-1] - ds[0]).days, 1) / 365.25
    ann = (vs[-1] / vs[0]) ** (1 / years) - 1
    vol_ann = statistics.stdev(rs) * math.sqrt(252) if len(rs) > 1 else 0
    sh = (statistics.mean(rs) * 252) / vol_ann if vol_ann > 0 else 0
    return {"start": str(ds[0]), "end": str(ds[-1]), "ann": ann, "dd": dd, "total": vs[-1] / vs[0] - 1, "vol": vol_ann, "sharpe": sh, "calmar": ann / dd if dd else 0}


def top_drawdowns(dates: list[dt.date], values: list[float], weights: list[dict[str, float]], n=5):
    peak = trough = 0
    out = []
    for i in range(1, len(values)):
        if values[i] > values[peak]:
            if values[trough] < values[peak] * 0.985:
                out.append((peak, trough, 1 - values[trough] / values[peak], weights[trough]))
            peak = trough = i
        elif values[i] < values[trough]:
            trough = i
    if values[trough] < values[peak] * 0.985:
        out.append((peak, trough, 1 - values[trough] / values[peak], weights[trough]))
    out.sort(key=lambda x: x[2], reverse=True)
    return [{"peak": str(dates[a]), "trough": str(dates[b]), "dd": c, "weights": {k: round(v * 100, 1) for k, v in w.items()}} for a, b, c, w in out[:n]]


def main():
    dates, prices = SC.align(SC.fetch())
    runs = [
        simulate("A_lifecycle_trend_engine", dates, prices, lifecycle_target),
        simulate("B_crash_reentry_ladder", dates, prices, crash_reentry_target),
        simulate("C_role_switch_engine", dates, prices, role_switch_target),
        simulate("D_capital_floor_risk_budget", dates, prices, capital_floor_target),
        simulate("E_volatility_budget_role", dates, prices, volatility_budget_target),
        simulate("F_repair_window_harvester", dates, prices, repair_window_target),
        simulate("G_dual_mandate_drawdown_mode", dates, prices, dual_mandate_target),
    ]
    out = []
    for r in runs:
        vals = r.pop("values")
        weights = r.pop("weights")
        try:
            ten_start = dates[-1].replace(year=dates[-1].year - 10)
        except ValueError:
            ten_start = dates[-1] - dt.timedelta(days=3652)
        row = {
            **r,
            "metrics": {
                "full": metrics(dates, vals),
                "post2020": metrics(dates, vals, dt.date(2020, 1, 1)),
                "teny": metrics(dates, vals, ten_start),
                "2024+": metrics(dates, vals, dt.date(2024, 1, 1)),
                "2002-2012": metrics(dates, vals, dt.date(2002, 1, 1), dt.date(2012, 12, 31)),
                "2013-2023": metrics(dates, vals, dt.date(2013, 1, 1), dt.date(2023, 12, 31)),
            },
            "stress": {k: metrics(dates, vals, st, en) for k, (st, en) in STRESS.items()},
            "top_dd": top_drawdowns(dates, vals, weights),
        }
        out.append(row)
    OUT.write_text(json.dumps({"coverage": {"start": str(dates[0]), "end": str(dates[-1]), "n": len(dates)}, "rows": out}, ensure_ascii=False, indent=2, default=str))
    print("WROTE", OUT)
    for r in out:
        print("\n##", r["name"])
        for k in ["full", "post2020", "teny", "2024+", "2002-2012", "2013-2023"]:
            m = r["metrics"][k]
            print(f"{k:10s} ann={pct(m['ann'])} dd={pct(m['dd'])} total={pct(m['total'])} sh={m['sharpe']:.2f} calmar={m['calmar']:.2f}")
        print("latest", {k: round(v*100, 1) for k, v in r["latest"].items()}, "cash", pct(r["cash_pct"]), "trades", r["trades"])
        print("stress", " | ".join(f"{k}:{pct(v['ann'])}/{pct(v['dd'])}" for k, v in r["stress"].items() if v))
        print("topdd", " ; ".join(f"{e['peak']}->{e['trough']} {pct(e['dd'])} W={e['weights']}" for e in r["top_dd"][:3]))

if __name__ == "__main__":
    main()
