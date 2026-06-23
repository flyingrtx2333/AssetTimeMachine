#!/usr/bin/env python3
"""Risk-engine strategy spike for AssetTimeMachine.

Goal: seek a logic breakthrough, not parameter tuning.

This prototype keeps the proven VAA/PAA alpha engine, then adds an
independent OHLC crisis gate per regional risk cluster:
- US equity cluster: Nasdaq + S&P 500 + Dow Jones OHLC
- CN equity cluster: CSI 300 + Shanghai Composite OHLC
- Gold remains close-only because AssetTimeMachine currently lacks full-cycle OHLC.

The gate is event/state based, not a parameter grid:
- detect cluster-level crash/bubble-break using OHLC trend/range/drawdown;
- block a damaged cluster until recovery confirmation;
- move blocked risk to cash, or modestly to gold if gold is healthy.

Run from repo root:
    python3 spikes/001-risk-engine-strategy/risk_engine_strategy.py
"""
from __future__ import annotations

import bisect
import datetime as dt
import importlib.util
import json
import math
import re
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]

spec = importlib.util.spec_from_file_location("vaa", REPO / "tools/search_no_btc_vaa_paa_2002.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load VAA helper")
vaa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(vaa)
nb = vaa.nb
base = vaa.base

SYMS = nb.SYMS
OFF = vaa.OFF
INITIAL = 100_000.0
FEE = 0.001
SLIP = 0.0005

BASE_CFG = {
    "canaries": ["nasdaq", "sp500"],
    "mom_lbs": [20, 60, 120, 240],
    "mom_weights": [12, 4, 2, 1],
    "weak_allowed": 1,
    "top_n": 2,
    "rebalance": 20,
    "canary_ma": 180,
    "asset_ma": 220,
    "gold_ma": 220,
    "canary_mom_th": 0.0,
    "asset_mom_th": 0.0,
    "gold_mom_th": 0.0,
    "eq_vol_cap": 0.45,
    "offensive_weight": 0.40,
    "gold_ballast": 0.30,
    "defensive_gold": 0.20,
    "max_exposure": 0.95,
    "band": 0.02,
}

CLUSTER = {
    "nasdaq": "US",
    "sp500": "US",
    "dowjones": "US",
    "csi300": "CN",
    "shanghai_composite": "CN",
    "gold_cny": "GOLD",
}

SINA_HEADERS = {"User-Agent": "Mozilla/5.0", "Referer": "https://finance.sina.com.cn/"}


def parse_date(text: str) -> dt.date:
    y, m, d = map(int, text.split("-"))
    return dt.date(y, m, d)


def request_text(url: str) -> str:
    last_error: Exception | None = None
    for attempt in range(3):
        try:
            req = urllib.request.Request(url, headers=SINA_HEADERS)
            return urllib.request.urlopen(req, timeout=45).read().decode("utf-8", "ignore")
        except Exception as exc:  # free endpoints occasionally close idle connections
            last_error = exc
            if attempt == 2:
                break
    raise RuntimeError(f"request failed after retries: {url}") from last_error


def parse_jsonp_array(text: str) -> list[dict[str, Any]]:
    m = re.search(r"=\((.*)\);?\s*$", text, re.S)
    if not m:
        raise ValueError("cannot parse JSONP")
    payload = m.group(1)
    obj = json.loads(payload)
    if not isinstance(obj, list):
        raise ValueError("JSONP payload is not list")
    return obj


def load_sina_us_ohlc(symbol: str) -> dict[dt.date, dict[str, float]]:
    url = "https://stock.finance.sina.com.cn/usstock/api/jsonp.php/var%20t=/US_MinKService.getDailyK?" + urllib.parse.urlencode({"symbol": symbol})
    rows = parse_jsonp_array(request_text(url))
    out: dict[dt.date, dict[str, float]] = {}
    for r in rows:
        d = parse_date(r["d"])
        out[d] = {
            "open": float(r["o"]),
            "high": float(r["h"]),
            "low": float(r["l"]),
            "close": float(r["c"]),
            "volume": float(r.get("v") or 0),
        }
    return out


def load_sina_cn_ohlc(symbol: str) -> dict[dt.date, dict[str, float]]:
    url = "https://money.finance.sina.com.cn/quotes_service/api/json_v2.php/CN_MarketData.getKLineData?" + urllib.parse.urlencode({
        "symbol": symbol,
        "scale": "240",
        "ma": "no",
        "datalen": "5000",
    })
    rows = json.loads(request_text(url))
    out: dict[dt.date, dict[str, float]] = {}
    for r in rows:
        d = parse_date(r["day"])
        out[d] = {
            "open": float(r["open"]),
            "high": float(r["high"]),
            "low": float(r["low"]),
            "close": float(r["close"]),
            "volume": float(r.get("volume") or 0),
        }
    return out


def load_ohlc_sources() -> dict[str, dict[dt.date, dict[str, float]]]:
    return {
        "nasdaq": load_sina_us_ohlc(".IXIC"),
        "sp500": load_sina_us_ohlc(".INX"),
        # Dow OHLC from free endpoints is unstable in this environment; US cluster gate uses Nasdaq+S&P.
        "csi300": load_sina_cn_ohlc("sh000300"),
        "shanghai_composite": load_sina_cn_ohlc("sh000001"),
    }


def latest_on_or_before(series: dict[dt.date, dict[str, float]], dates_sorted: list[dt.date], d: dt.date, max_gap_days: int = 7) -> dict[str, float] | None:
    idx = bisect.bisect_right(dates_sorted, d) - 1
    if idx < 0:
        return None
    found = dates_sorted[idx]
    if (d - found).days > max_gap_days:
        return None
    return series[found]


def normalized_cluster_ohlc(
    aligned_dates: list[dt.date],
    raw: dict[str, dict[dt.date, dict[str, float]]],
    members: list[str],
) -> dict[str, list[float | None]]:
    sorted_dates = {s: sorted(raw[s]) for s in members}
    first_close: dict[str, float] = {}
    out = {"open": [], "high": [], "low": [], "close": [], "range": [], "volume_z_proxy": []}
    for s in members:
        out[f"close__{s}"] = []
    for d in aligned_dates:
        candles: list[tuple[str, dict[str, float]]] = []
        ok = True
        for s in members:
            c = latest_on_or_before(raw[s], sorted_dates[s], d)
            if c is None:
                ok = False
                break
            if s not in first_close:
                first_close[s] = c["close"]
            candles.append((s, c))
        if not ok or len(candles) != len(members):
            for k in out:
                out[k].append(None)
            continue
        vals: dict[str, list[float]] = {"open": [], "high": [], "low": [], "close": [], "range": [], "volume_z_proxy": []}
        member_norm: dict[str, float] = {}
        for s, c in candles:
            base_close = first_close[s]
            if base_close <= 0:
                continue
            norm_close = c["close"] / base_close
            vals["open"].append(c["open"] / base_close)
            vals["high"].append(c["high"] / base_close)
            vals["low"].append(c["low"] / base_close)
            vals["close"].append(norm_close)
            member_norm[f"close__{s}"] = norm_close
            vals["range"].append((c["high"] - c["low"]) / c["close"] if c["close"] > 0 else 0.0)
            vals["volume_z_proxy"].append(math.log(max(c.get("volume") or 1.0, 1.0)))
        for k in out:
            if k.startswith("close__"):
                out[k].append(member_norm.get(k))
            else:
                out[k].append(sum(vals[k]) / len(vals[k]) if vals[k] else None)
    return out


def ma(values: list[float | None], n: int) -> list[float | None]:
    out: list[float | None] = [None] * len(values)
    window: list[float] = []
    s = 0.0
    for i, v in enumerate(values):
        if v is None:
            window = []
            s = 0.0
            continue
        window.append(v)
        s += v
        if len(window) > n:
            s -= window.pop(0)
        if len(window) == n:
            out[i] = s / n
    return out


def ret(values: list[float | None], i: int, n: int) -> float | None:
    if i - n < 0:
        return None
    a, b = values[i - n], values[i]
    if a is None or b is None or a <= 0:
        return None
    return b / a - 1


def rolling_drawdown(values: list[float | None], i: int, n: int) -> float | None:
    if i - n + 1 < 0 or values[i] is None:
        return None
    window = values[i - n + 1 : i + 1]
    if any(v is None for v in window):
        return None
    peak = max(v for v in window if v is not None)
    cur = values[i]
    if peak <= 0 or cur is None:
        return None
    return cur / peak - 1


def rolling_mean(values: list[float | None], i: int, n: int) -> float | None:
    if i - n + 1 < 0:
        return None
    window = values[i - n + 1 : i + 1]
    if any(v is None for v in window):
        return None
    return sum(v for v in window if v is not None) / n


def rolling_max(values: list[float | None], i: int, n: int) -> float | None:
    if i - n + 1 < 0:
        return None
    window = values[i - n + 1 : i + 1]
    if any(v is None for v in window):
        return None
    return max(v for v in window if v is not None)


def cluster_return_dispersion(cluster: dict[str, list[float | None]], members: list[str], i: int, n: int) -> float | None:
    rets: list[float] = []
    for s in members:
        key = f"close__{s}"
        if key not in cluster:
            continue
        r = ret(cluster[key], i, n)
        if r is None:
            return None
        rets.append(r)
    if len(rets) < 2:
        return None
    return max(rets) - min(rets)


class CrisisGate:
    """Stateful regional risk gate.

    The exact numeric thresholds are deliberately simple market-structure rules,
    not optimized parameters:
    - crash: fast drawdown + close below medium trend, or waterfall day after weak week;
    - bubble break: huge 1y advance, then fast break;
    - recovery: back above medium trend and positive 1m return.
    """

    def __init__(self, name: str, cluster: dict[str, list[float | None]]):
        self.name = name
        self.cluster = cluster
        self.ma60 = ma(cluster["close"], 60)
        self.ma120 = ma(cluster["close"], 120)
        self.ma200 = ma(cluster["close"], 200)
        self.blocked = False
        self.reason = ""

    def evaluate(self, i: int) -> tuple[bool, dict[str, Any]]:
        close = self.cluster["close"][i]
        low = self.cluster["low"][i]
        high = self.cluster["high"][i]
        rng = self.cluster["range"][i]
        if close is None or low is None or high is None or rng is None:
            return False, {"blocked": self.blocked, "reason": "missing_ohlc"}
        r5 = ret(self.cluster["close"], i, 5)
        r20 = ret(self.cluster["close"], i, 20)
        r60 = ret(self.cluster["close"], i, 60)
        r252 = ret(self.cluster["close"], i, 252)
        dd20 = rolling_drawdown(self.cluster["close"], i, 20)
        dd60 = rolling_drawdown(self.cluster["close"], i, 60)
        avg_range20 = rolling_mean(self.cluster["range"], i, 20)
        m60 = self.ma60[i]
        m120 = self.ma120[i]
        m200 = self.ma200[i]

        close_near_low = (close - low) / max(high - low, 1e-12) < 0.28
        waterfall = (
            r5 is not None and r5 < -0.035
            and dd20 is not None and dd20 < -0.07
            and avg_range20 is not None and rng > avg_range20 * 1.35
            and close_near_low
        )
        trend_break = (
            dd60 is not None and dd60 < -0.12
            and m120 is not None and close < m120
            and r20 is not None and r20 < -0.02
        )
        bubble_break = (
            self.name == "CN"
            and r252 is not None and r252 > 0.55
            and dd20 is not None and dd20 < -0.08
            and m60 is not None and close < m60
        )
        slow_bear = (
            m200 is not None and close < m200
            and r60 is not None and r60 < -0.08
            and dd60 is not None and dd60 < -0.10
        )
        trigger = waterfall or trend_break or bubble_break or slow_bear
        recovery = (
            m120 is not None and close > m120
            and r20 is not None and r20 > 0.015
            and (dd20 is None or dd20 > -0.035)
        )
        if trigger:
            self.blocked = True
            if bubble_break:
                self.reason = "bubble_break"
            elif waterfall:
                self.reason = "waterfall"
            elif trend_break:
                self.reason = "trend_break"
            else:
                self.reason = "slow_bear"
        elif self.blocked and recovery:
            self.blocked = False
            self.reason = "recovered"
        return self.blocked, {
            "blocked": self.blocked,
            "reason": self.reason,
            "r5": pct(r5),
            "r20": pct(r20),
            "r60": pct(r60),
            "r252": pct(r252),
            "dd20": pct(dd20),
            "dd60": pct(dd60),
            "range": pct(rng),
        }


def pct(x: float | None) -> float | None:
    return None if x is None else round(x * 100, 2)


def gold_is_healthy(prices: dict[str, list[float]], c: dict[str, Any], i: int) -> bool:
    gmm = vaa.multi_mom(c, "gold_cny", i, BASE_CFG["mom_lbs"], BASE_CFG["mom_weights"])
    gma = c["ma"][("gold_cny", BASE_CFG["gold_ma"])][i]
    if gmm is None or gma is None:
        return False
    # Gold must be in positive trend; if its own 60d return is sharply negative, prefer cash.
    g60 = prices["gold_cny"][i] / prices["gold_cny"][max(i - 60, 0)] - 1 if i >= 60 else 0
    return gmm > 0 and prices["gold_cny"][i] > gma and g60 > -0.06


def base_target(prices: dict[str, list[float]], c: dict[str, Any], i: int) -> tuple[dict[str, float], dict[str, Any]]:
    weak = 0
    for s in BASE_CFG["canaries"]:
        mm = vaa.multi_mom(c, s, i, BASE_CFG["mom_lbs"], BASE_CFG["mom_weights"])
        ma_v = c["ma"][(s, BASE_CFG["canary_ma"] )][i]
        if mm is None or ma_v is None or mm < 0 or prices[s][i] < ma_v:
            weak += 1
    risk_on = weak <= BASE_CFG["weak_allowed"]
    target = {s: 0.0 for s in SYMS}
    selected: list[str] = []
    if risk_on:
        ranked: list[tuple[float, str]] = []
        for s in OFF:
            mm = vaa.multi_mom(c, s, i, BASE_CFG["mom_lbs"], BASE_CFG["mom_weights"])
            ma_v = c["ma"][(s, BASE_CFG["asset_ma"] )][i]
            vv = c["vol"][(s, 60)][i]
            if mm is None or ma_v is None:
                continue
            if mm > 0 and prices[s][i] > ma_v and (vv is None or vv < BASE_CFG["eq_vol_cap"]):
                ranked.append((mm / max(vv or 0.18, 0.05), s))
        ranked.sort(reverse=True)
        selected = [s for _, s in ranked[: BASE_CFG["top_n"]]]
        if selected:
            inv = {s: 1 / max(c["vol"][(s, 60)][i] or 0.18, 0.05) for s in selected}
            sm = sum(inv.values())
            for s in selected:
                target[s] = BASE_CFG["offensive_weight"] * inv[s] / sm
        if gold_is_healthy(prices, c, i):
            target["gold_cny"] = BASE_CFG["gold_ballast"]
    else:
        if gold_is_healthy(prices, c, i):
            target["gold_cny"] = BASE_CFG["defensive_gold"]
    return target, {"weak": weak, "risk_on": risk_on, "selected": selected}


def eligible_ranked_assets_for_cluster(prices: dict[str, list[float]], c: dict[str, Any], i: int, cluster_name: str) -> list[tuple[float, str]]:
    ranked: list[tuple[float, str]] = []
    for s in OFF:
        if CLUSTER[s] != cluster_name:
            continue
        mm = vaa.multi_mom(c, s, i, BASE_CFG["mom_lbs"], BASE_CFG["mom_weights"])
        ma_v = c["ma"][(s, BASE_CFG["asset_ma"] )][i]
        vv = c["vol"][(s, 60)][i]
        if mm is None or ma_v is None:
            continue
        if mm > 0 and prices[s][i] > ma_v and (vv is None or vv < BASE_CFG["eq_vol_cap"]):
            ranked.append((mm / max(vv or 0.18, 0.05), s))
    ranked.sort(reverse=True)
    return ranked


def apply_overextension_cluster_cap(
    target: dict[str, float],
    clusters: dict[str, dict[str, list[float | None]]],
    prices: dict[str, list[float]],
    c: dict[str, Any],
    i: int,
) -> tuple[dict[str, float], dict[str, Any]]:
    """Cap equity clusters when price is far above long-term trend.

    This tries to catch bubble asymmetry before return-based crash signals.
    The idea: after an index trades extremely far above its 200-session trend,
    the next unit of exposure has poor left-tail payoff, so the engine harvests
    exposure rather than doubling down on momentum.
    """
    out = target.copy()
    events: list[dict[str, Any]] = []
    for cluster_name, members in {"US": ["nasdaq", "sp500", "dowjones"], "CN": ["csi300", "shanghai_composite"]}.items():
        cluster = clusters[cluster_name]
        close = cluster["close"][i]
        m200 = cluster.get("ma200", [None] * len(cluster["close"]))[i]
        r60 = ret(cluster["close"], i, 60)
        dd20 = rolling_drawdown(cluster["close"], i, 20)
        total = sum(out.get(s, 0.0) for s in members)
        if total <= 0 or close is None or m200 is None or m200 <= 0:
            continue
        extension = close / m200 - 1
        cap = None
        reason = None
        if cluster_name == "CN":
            if extension > 0.70:
                cap, reason = 0.10, "extreme_extension"
            elif extension > 0.45:
                cap, reason = 0.20, "extension_cap"
        else:
            if extension > 0.35:
                cap, reason = 0.18, "extreme_extension"
            elif extension > 0.25:
                cap, reason = 0.25, "extension_cap"
        # If overextension already starts rolling over, exit the cluster.
        if cap is not None and r60 is not None and r60 < -0.03 and dd20 is not None and dd20 < -0.04:
            cap, reason = 0.0, "extension_rollover_block"
        if cap is not None and total > cap:
            scale = cap / total if total > 0 else 0.0
            cut = 0.0
            for s in members:
                old = out.get(s, 0.0)
                out[s] = old * scale
                cut += old - out[s]
            if cut > 0 and gold_is_healthy(prices, c, i):
                out["gold_cny"] = min(out.get("gold_cny", 0.0) + cut * 0.35, 0.45)
            events.append({"cluster": cluster_name, "reason": reason, "extension": pct(extension), "r60": pct(r60), "dd20": pct(dd20), "old": round(total, 4), "new": round(cap, 4), "cut": round(cut, 4)})
    return out, {"extension_events": events}


def apply_mania_cluster_cap(
    target: dict[str, float],
    clusters: dict[str, dict[str, list[float | None]]],
    prices: dict[str, list[float]],
    c: dict[str, Any],
    i: int,
) -> tuple[dict[str, float], dict[str, Any]]:
    """Proactive cluster risk control for bubble/manic advances.

    This is a logic rule, not a tuned parameter search: when a regional equity
    cluster has already doubled-ish in a year (China) or rallied far beyond a
    normal broad-index trend (US), do not allow the alpha engine to double-stack
    the same cluster. The objective is to avoid 2007/2015-style same-region
    concentration before the crash signal arrives.
    """
    out = target.copy()
    events: list[dict[str, Any]] = []
    for cluster_name, members in {"US": ["nasdaq", "sp500", "dowjones"], "CN": ["csi300", "shanghai_composite"]}.items():
        cluster = clusters[cluster_name]
        r252 = ret(cluster["close"], i, 252)
        r60 = ret(cluster["close"], i, 60)
        dd20 = rolling_drawdown(cluster["close"], i, 20)
        total = sum(out.get(s, 0.0) for s in members)
        if total <= 0:
            continue
        mania_threshold = 0.80 if cluster_name == "CN" else 0.45
        cap = None
        reason = None
        if r252 is not None and r252 > mania_threshold:
            cap = 0.20 if cluster_name == "CN" else 0.25
            reason = "mania_cap"
        # If a manic cluster has already started wobbling, cut harder even before full crisis gate.
        if r252 is not None and r252 > mania_threshold and dd20 is not None and dd20 < -0.055:
            cap = 0.10
            reason = "mania_wobble_cap"
        # If medium momentum turned negative after a huge run, avoid re-entry whipsaw.
        if r252 is not None and r252 > mania_threshold and r60 is not None and r60 < -0.04:
            cap = 0.0
            reason = "mania_rollover_block"
        if cap is not None and total > cap:
            scale = cap / total if total > 0 else 0.0
            cut = 0.0
            for s in members:
                old = out.get(s, 0.0)
                out[s] = old * scale
                cut += old - out[s]
            if cut > 0 and gold_is_healthy(prices, c, i):
                out["gold_cny"] = min(out.get("gold_cny", 0.0) + cut * 0.35, 0.45)
            events.append({"cluster": cluster_name, "reason": reason, "r252": pct(r252), "r60": pct(r60), "dd20": pct(dd20), "old": round(total, 4), "new": round(cap, 4), "cut": round(cut, 4)})
    return out, {"mania_events": events}


def cluster_fragility_score(cluster_name: str, cluster: dict[str, list[float | None]], members: list[str], i: int) -> tuple[int, dict[str, Any]]:
    close = cluster["close"][i]
    rng = cluster["range"][i]
    r10 = ret(cluster["close"], i, 10)
    r20 = ret(cluster["close"], i, 20)
    r60 = ret(cluster["close"], i, 60)
    r120 = ret(cluster["close"], i, 120)
    r252 = ret(cluster["close"], i, 252)
    dd20 = rolling_drawdown(cluster["close"], i, 20)
    dd60 = rolling_drawdown(cluster["close"], i, 60)
    dd120 = rolling_drawdown(cluster["close"], i, 120)
    peak60 = rolling_max(cluster["close"], i, 60)
    avg_range20 = rolling_mean(cluster["range"], i, 20)
    avg_range120 = rolling_mean(cluster["range"], i, 120)
    avg_vol20 = rolling_mean(cluster["volume_z_proxy"], i, 20)
    avg_vol60 = rolling_mean(cluster["volume_z_proxy"], i, 60)
    disp20 = cluster_return_dispersion(cluster, members, i, 20)
    disp60 = cluster_return_dispersion(cluster, members, i, 60)
    ma60_series = cluster.get("ma60") or ma(cluster["close"], 60)
    ma120_series = cluster.get("ma120") or ma(cluster["close"], 120)
    m60 = ma60_series[i]
    m120 = ma120_series[i]

    score = 0
    reasons: list[str] = []
    mania = False
    if cluster_name == "CN":
        mania = (r252 is not None and r252 > 0.70) or (r120 is not None and r120 > 0.40)
        divergence = (disp20 is not None and disp20 > 0.07) or (disp60 is not None and disp60 > 0.12)
    else:
        mania = (r252 is not None and r252 > 0.40) or (r120 is not None and r120 > 0.24)
        divergence = (disp20 is not None and disp20 > 0.045) or (disp60 is not None and disp60 > 0.075)
    if mania:
        score += 2
        reasons.append("blowoff_advance")
    range_expansion = (
        avg_range20 is not None and avg_range120 is not None and avg_range20 > avg_range120 * 1.32
    ) or (
        rng is not None and avg_range20 is not None and rng > avg_range20 * 1.55
    )
    if range_expansion:
        score += 1
        reasons.append("range_expansion")
    volume_expansion = avg_vol20 is not None and avg_vol60 is not None and avg_vol20 > avg_vol60 + 0.18
    if volume_expansion:
        score += 1
        reasons.append("volume_expansion")
    if divergence:
        score += 1
        reasons.append("internal_divergence")
    failed_rebound = (
        dd60 is not None and dd60 < -0.08
        and r10 is not None and r10 > 0.018
        and close is not None
        and ((m60 is not None and close < m60) or (peak60 is not None and close < peak60 * 0.945))
    )
    if failed_rebound:
        score += 2
        reasons.append("failed_rebound")
    trend_crack = (
        close is not None and m60 is not None and close < m60
        and r20 is not None and r20 < -0.015
        and dd20 is not None and dd20 < -0.045
    )
    if trend_crack:
        score += 1
        reasons.append("trend_crack")
    long_trend_loss = (
        close is not None and m120 is not None and close < m120
        and dd120 is not None and dd120 < -0.10
        and r60 is not None and r60 < -0.03
    )
    if long_trend_loss:
        score += 1
        reasons.append("long_trend_loss")

    return score, {
        "score": score,
        "reasons": reasons,
        "mania": mania,
        "r20": pct(r20),
        "r60": pct(r60),
        "r120": pct(r120),
        "r252": pct(r252),
        "dd20": pct(dd20),
        "dd60": pct(dd60),
        "dd120": pct(dd120),
        "range20_vs_120": None if avg_range20 is None or avg_range120 in (None, 0) else round(avg_range20 / avg_range120, 2),
        "vol20_minus_60_log": None if avg_vol20 is None or avg_vol60 is None else round(avg_vol20 - avg_vol60, 3),
        "disp20": pct(disp20),
        "disp60": pct(disp60),
    }


def apply_fragility_score_cap(
    target: dict[str, float],
    clusters: dict[str, dict[str, list[float | None]]],
    prices: dict[str, list[float]],
    c: dict[str, Any],
    i: int,
    mode: str,
) -> tuple[dict[str, float], dict[str, Any]]:
    out = target.copy()
    events: list[dict[str, Any]] = []
    for cluster_name, members in {"US": ["nasdaq", "sp500", "dowjones"], "CN": ["csi300", "shanghai_composite"]}.items():
        score, info = cluster_fragility_score(cluster_name, clusters[cluster_name], members if cluster_name == "CN" else ["nasdaq", "sp500"], i)
        total = sum(out.get(s, 0.0) for s in members)
        if total <= 0:
            continue
        cap = None
        reason = None
        if mode == "hard":
            if score >= 5:
                cap, reason = 0.0, "fragility_block"
            elif score >= 4:
                cap, reason = 0.10, "fragility_deep_cut"
            elif score >= 3:
                cap, reason = 0.18, "fragility_cut"
            elif score >= 2 and info.get("mania"):
                cap, reason = 0.25, "fragility_mania_cap"
        else:
            if score >= 5:
                cap, reason = 0.12, "soft_fragility_deep_cut"
            elif score >= 4:
                cap, reason = 0.18, "soft_fragility_cut"
            elif score >= 3:
                cap, reason = 0.25, "soft_fragility_cap"
        if cap is None or total <= cap:
            continue
        scale = cap / total if total > 0 else 0.0
        cut = 0.0
        for s in members:
            old = out.get(s, 0.0)
            out[s] = old * scale
            cut += old - out[s]
        if cut > 0 and gold_is_healthy(prices, c, i):
            out["gold_cny"] = min(out.get("gold_cny", 0.0) + cut * 0.30, 0.45)
        events.append({"cluster": cluster_name, "reason": reason, "old": round(total, 4), "new": round(cap, 4), "cut": round(cut, 4), **info})
    return out, {"fragility_events": events}


def apply_mania_substitution_cap(
    target: dict[str, float],
    clusters: dict[str, dict[str, list[float | None]]],
    prices: dict[str, list[float]],
    c: dict[str, Any],
    i: int,
) -> tuple[dict[str, float], dict[str, Any]]:
    """Cap manic clusters, then migrate some freed risk to a healthy opposite cluster.

    Key logic difference vs `mania_aware`: do not turn every cut into cash.
    If China is manic but US trend is healthy/non-fragile, let US absorb a small
    sleeve. If US is manic, only migrate to China when China itself is healthy.
    """
    out = target.copy()
    events: list[dict[str, Any]] = []
    cluster_members = {"US": ["nasdaq", "sp500", "dowjones"], "CN": ["csi300", "shanghai_composite"]}
    signal_members = {"US": ["nasdaq", "sp500"], "CN": ["csi300", "shanghai_composite"]}
    for cluster_name, members in cluster_members.items():
        cluster = clusters[cluster_name]
        r252 = ret(cluster["close"], i, 252)
        r60 = ret(cluster["close"], i, 60)
        dd20 = rolling_drawdown(cluster["close"], i, 20)
        total = sum(out.get(s, 0.0) for s in members)
        if total <= 0:
            continue
        mania_threshold = 0.80 if cluster_name == "CN" else 0.45
        cap = None
        reason = None
        if r252 is not None and r252 > mania_threshold:
            cap = 0.22 if cluster_name == "CN" else 0.25
            reason = "mania_cap_with_substitution"
        if r252 is not None and r252 > mania_threshold and dd20 is not None and dd20 < -0.055:
            cap = 0.10
            reason = "mania_wobble_with_substitution"
        if r252 is not None and r252 > mania_threshold and r60 is not None and r60 < -0.04:
            cap = 0.0
            reason = "mania_rollover_block"
        if cap is None or total <= cap:
            continue
        scale = cap / total if total > 0 else 0.0
        cut = 0.0
        for s in members:
            old = out.get(s, 0.0)
            out[s] = old * scale
            cut += old - out[s]

        other = "US" if cluster_name == "CN" else "CN"
        other_score, other_info = cluster_fragility_score(other, clusters[other], signal_members[other], i)
        substituted = 0.0
        substitute_asset = None
        # Only migrate to the other equity cluster if it is not itself in a fragile/manic regime.
        if other_score <= 1 and not other_info.get("mania"):
            ranked = eligible_ranked_assets_for_cluster(prices, c, i, other)
            if ranked:
                substitute_asset = ranked[0][1]
                room = max(BASE_CFG["max_exposure"] - sum(out.values()), 0.0)
                substituted = min(cut * 0.55, 0.16, room)
                if substituted > 0:
                    out[substitute_asset] = out.get(substitute_asset, 0.0) + substituted
        remaining = max(cut - substituted, 0.0)
        if remaining > 0 and gold_is_healthy(prices, c, i):
            out["gold_cny"] = min(out.get("gold_cny", 0.0) + remaining * 0.30, 0.45)
        events.append({
            "cluster": cluster_name,
            "reason": reason,
            "r252": pct(r252),
            "r60": pct(r60),
            "dd20": pct(dd20),
            "old": round(total, 4),
            "new": round(cap, 4),
            "cut": round(cut, 4),
            "substitute_asset": substitute_asset,
            "substituted": round(substituted, 4),
            "other_score": other_score,
            "other_reasons": other_info.get("reasons"),
        })
    return out, {"substitution_events": events}


def apply_mania_safe_haven_cap(
    target: dict[str, float],
    clusters: dict[str, dict[str, list[float | None]]],
    prices: dict[str, list[float]],
    c: dict[str, Any],
    i: int,
) -> tuple[dict[str, float], dict[str, Any]]:
    """Harvest manic equity exposure into gold/cash instead of another equity cluster."""
    out = target.copy()
    events: list[dict[str, Any]] = []
    for cluster_name, members in {"US": ["nasdaq", "sp500", "dowjones"], "CN": ["csi300", "shanghai_composite"]}.items():
        cluster = clusters[cluster_name]
        r252 = ret(cluster["close"], i, 252)
        r60 = ret(cluster["close"], i, 60)
        dd20 = rolling_drawdown(cluster["close"], i, 20)
        total = sum(out.get(s, 0.0) for s in members)
        if total <= 0:
            continue
        mania_threshold = 0.80 if cluster_name == "CN" else 0.45
        cap = None
        reason = None
        if r252 is not None and r252 > mania_threshold:
            cap = 0.20 if cluster_name == "CN" else 0.25
            reason = "mania_harvest_to_safe_haven"
        if r252 is not None and r252 > mania_threshold and dd20 is not None and dd20 < -0.055:
            cap = 0.10
            reason = "mania_wobble_harvest"
        if r252 is not None and r252 > mania_threshold and r60 is not None and r60 < -0.04:
            cap = 0.0
            reason = "mania_rollover_block"
        if cap is None or total <= cap:
            continue
        scale = cap / total if total > 0 else 0.0
        cut = 0.0
        for s in members:
            old = out.get(s, 0.0)
            out[s] = old * scale
            cut += old - out[s]
        added_gold = 0.0
        if cut > 0 and gold_is_healthy(prices, c, i):
            room = max(0.55 - out.get("gold_cny", 0.0), 0.0)
            added_gold = min(cut * 0.85, room)
            out["gold_cny"] = out.get("gold_cny", 0.0) + added_gold
        events.append({"cluster": cluster_name, "reason": reason, "r252": pct(r252), "r60": pct(r60), "dd20": pct(dd20), "old": round(total, 4), "new": round(cap, 4), "cut": round(cut, 4), "added_gold": round(added_gold, 4)})
    return out, {"safe_haven_events": events}


def apply_cluster_gate(
    target: dict[str, float],
    blocked: dict[str, tuple[bool, dict[str, Any]]],
    prices: dict[str, list[float]],
    c: dict[str, Any],
    i: int,
) -> tuple[dict[str, float], dict[str, Any]]:
    out = target.copy()
    cut = 0.0
    blocked_clusters: list[str] = []
    for cluster in ["US", "CN"]:
        is_blocked, info = blocked[cluster]
        if not is_blocked:
            continue
        blocked_clusters.append(cluster)
        for s in OFF:
            if CLUSTER[s] == cluster and out.get(s, 0.0) > 0:
                cut += out[s]
                out[s] = 0.0
    # If a cluster is blocked, do not blindly push all risk into gold. Gold is only a partial refuge.
    if cut > 0 and gold_is_healthy(prices, c, i):
        out["gold_cny"] = min(out.get("gold_cny", 0.0) + cut * 0.45, 0.45)
    gross = sum(out.values())
    if gross > BASE_CFG["max_exposure"] and gross > 0:
        scale = BASE_CFG["max_exposure"] / gross
        for s in out:
            out[s] *= scale
    return out, {"blocked_clusters": blocked_clusters, "cut": round(cut, 4)}


def execute_rebalance(cash: float, units: dict[str, float], prices: dict[str, list[float]], i: int, target: dict[str, float]) -> tuple[float, dict[str, float], int]:
    trades = 0
    def pv() -> float:
        return cash + sum(units[s] * prices[s][i] for s in SYMS)
    total = pv()
    for s in SYMS:
        cur = units[s] * prices[s][i]
        tgt = total * target[s]
        if cur > tgt * (1 + BASE_CFG["band"]):
            su = min(units[s], (cur - tgt) / prices[s][i])
            if su > 0:
                cash += su * prices[s][i] * (1 - SLIP) * (1 - FEE)
                units[s] -= su
                trades += 1
    total = pv()
    for s in SYMS:
        cur = units[s] * prices[s][i]
        tgt = total * target[s]
        if cur < tgt * (1 - BASE_CFG["band"]):
            amt = min(cash, tgt - cur)
            if amt > 1:
                units[s] += amt * (1 - FEE) / (prices[s][i] * (1 + SLIP))
                cash -= amt
                trades += 1
    return cash, units, trades


def simulate(
    name: str,
    dates: list[dt.date],
    prices: dict[str, list[float]],
    c: dict[str, Any],
    us_cluster: dict[str, list[float | None]],
    cn_cluster: dict[str, list[float | None]],
    start_date: dt.date,
) -> dict[str, Any]:
    cash = INITIAL
    units = {s: 0.0 for s in SYMS}
    vals: list[float] = []
    out_dates: list[dt.date] = []
    trades = 0
    exposure = 0.0
    last_rebalance = -10**9
    us_gate = CrisisGate("US", us_cluster)
    cn_gate = CrisisGate("CN", cn_cluster)
    gate_events: list[dict[str, Any]] = []
    started = False
    for i, d in enumerate(dates):
        if d < start_date:
            continue
        if not started:
            # reset portfolio on first included date
            cash = INITIAL
            units = {s: 0.0 for s in SYMS}
            vals = []
            out_dates = []
            last_rebalance = -10**9
            started = True
        def pv() -> float:
            return cash + sum(units[s] * prices[s][i] for s in SYMS)
        if i > 0 and i - last_rebalance >= BASE_CFG["rebalance"]:
            sig = i - 1
            target, meta = base_target(prices, c, sig)
            if name == "vaa_ohlc_crisis_gate":
                us_blocked = us_gate.evaluate(sig)
                cn_blocked = cn_gate.evaluate(sig)
                gated, gate_meta = apply_cluster_gate(target, {"US": us_blocked, "CN": cn_blocked}, prices, c, sig)
                if gate_meta["blocked_clusters"]:
                    gate_events.append({"date": str(d), "signal": str(dates[sig]), **gate_meta, "selected": meta["selected"], "us": us_blocked[1], "cn": cn_blocked[1]})
                target = gated
            elif name == "vaa_mania_aware_crisis_gate":
                clusters = {"US": us_cluster, "CN": cn_cluster}
                target, mania_meta = apply_mania_cluster_cap(target, clusters, prices, c, sig)
                us_blocked = us_gate.evaluate(sig)
                cn_blocked = cn_gate.evaluate(sig)
                target, gate_meta = apply_cluster_gate(target, {"US": us_blocked, "CN": cn_blocked}, prices, c, sig)
                if mania_meta["mania_events"] or gate_meta["blocked_clusters"]:
                    gate_events.append({"date": str(d), "signal": str(dates[sig]), **mania_meta, **gate_meta, "selected": meta["selected"], "us": us_blocked[1], "cn": cn_blocked[1]})
            elif name == "vaa_extension_aware_crisis_gate":
                clusters = {"US": us_cluster, "CN": cn_cluster}
                target, extension_meta = apply_overextension_cluster_cap(target, clusters, prices, c, sig)
                us_blocked = us_gate.evaluate(sig)
                cn_blocked = cn_gate.evaluate(sig)
                target, gate_meta = apply_cluster_gate(target, {"US": us_blocked, "CN": cn_blocked}, prices, c, sig)
                if extension_meta["extension_events"] or gate_meta["blocked_clusters"]:
                    gate_events.append({"date": str(d), "signal": str(dates[sig]), **extension_meta, **gate_meta, "selected": meta["selected"], "us": us_blocked[1], "cn": cn_blocked[1]})
            elif name in ("vaa_fragility_hard_crisis_gate", "vaa_fragility_soft_crisis_gate"):
                clusters = {"US": us_cluster, "CN": cn_cluster}
                fragility_mode = "hard" if name == "vaa_fragility_hard_crisis_gate" else "soft"
                target, fragility_meta = apply_fragility_score_cap(target, clusters, prices, c, sig, fragility_mode)
                us_blocked = us_gate.evaluate(sig)
                cn_blocked = cn_gate.evaluate(sig)
                target, gate_meta = apply_cluster_gate(target, {"US": us_blocked, "CN": cn_blocked}, prices, c, sig)
                if fragility_meta["fragility_events"] or gate_meta["blocked_clusters"]:
                    gate_events.append({"date": str(d), "signal": str(dates[sig]), "mode": fragility_mode, **fragility_meta, **gate_meta, "selected": meta["selected"], "us": us_blocked[1], "cn": cn_blocked[1]})
            elif name == "vaa_mania_substitution_crisis_gate":
                clusters = {"US": us_cluster, "CN": cn_cluster}
                target, substitution_meta = apply_mania_substitution_cap(target, clusters, prices, c, sig)
                us_blocked = us_gate.evaluate(sig)
                cn_blocked = cn_gate.evaluate(sig)
                target, gate_meta = apply_cluster_gate(target, {"US": us_blocked, "CN": cn_blocked}, prices, c, sig)
                if substitution_meta["substitution_events"] or gate_meta["blocked_clusters"]:
                    gate_events.append({"date": str(d), "signal": str(dates[sig]), **substitution_meta, **gate_meta, "selected": meta["selected"], "us": us_blocked[1], "cn": cn_blocked[1]})
            elif name == "vaa_mania_safe_haven_crisis_gate":
                clusters = {"US": us_cluster, "CN": cn_cluster}
                target, safe_meta = apply_mania_safe_haven_cap(target, clusters, prices, c, sig)
                us_blocked = us_gate.evaluate(sig)
                cn_blocked = cn_gate.evaluate(sig)
                target, gate_meta = apply_cluster_gate(target, {"US": us_blocked, "CN": cn_blocked}, prices, c, sig)
                if safe_meta["safe_haven_events"] or gate_meta["blocked_clusters"]:
                    gate_events.append({"date": str(d), "signal": str(dates[sig]), **safe_meta, **gate_meta, "selected": meta["selected"], "us": us_blocked[1], "cn": cn_blocked[1]})
            elif name == "vaa_region_cluster_one_per_region":
                # Different idea: prevent same-region double exposure by clipping each equity cluster to one representative.
                selected_by_cluster: dict[str, str] = {}
                for s in sorted(OFF, key=lambda x: target[x], reverse=True):
                    if target[s] <= 0:
                        continue
                    cl = CLUSTER[s]
                    if cl not in selected_by_cluster:
                        selected_by_cluster[cl] = s
                    else:
                        target[selected_by_cluster[cl]] += target[s] * 0.25
                        target[s] = 0.0
                # leftover stays cash; this is an explicit concentration-control idea.
            elif name == "vaa_core_satellite_state_machine":
                # Separate stable core from tactical sleeve. Use VAA only for the tactical part.
                core_gold = 0.25 if gold_is_healthy(prices, c, sig) else 0.0
                tactical = target.copy()
                for s in tactical:
                    tactical[s] *= 0.65
                tactical["gold_cny"] = max(tactical.get("gold_cny", 0.0), core_gold)
                target = tactical
            cash, units, n = execute_rebalance(cash, units, prices, i, target)
            trades += n
            last_rebalance = i
        v = pv()
        vals.append(v)
        out_dates.append(d)
        exposure += sum(units[s] * prices[s][i] for s in SYMS) / v if v > 0 else 0.0
    slices = {
        "full": base.metrics(out_dates, vals),
        "post_2020": base.slice_metrics(out_dates, vals, dt.date(2020, 1, 1)),
        "last_10y": base.slice_metrics(out_dates, vals, out_dates[-1].replace(year=out_dates[-1].year - 10)),
        "post_2022": base.slice_metrics(out_dates, vals, dt.date(2022, 1, 1)),
    }
    return {
        "name": name,
        "start": str(out_dates[0]),
        "end": str(out_dates[-1]),
        "trades": trades,
        "exposure": exposure / len(vals),
        "slices": slices,
        "gate_events_sample": gate_events[:8],
        "gate_events_count": len(gate_events),
    }


def sm_metrics(m: dict[str, Any] | None) -> dict[str, Any] | None:
    if m is None:
        return None
    return {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def print_result(r: dict[str, Any]) -> None:
    f = r["slices"]["full"]
    p20 = r["slices"]["post_2020"]
    y10 = r["slices"]["last_10y"]
    p22 = r["slices"]["post_2022"]
    print(
        f"{r['name']:32s} {r['start']}..{r['end']} "
        f"ann={f['annualized']*100:5.2f}% mdd={f['max_drawdown']*100:5.2f}% sharpe={(f['sharpe'] or 0):4.2f} "
        f"trades={r['trades']:4d} expo={r['exposure']*100:5.1f}% | "
        f"p20 {p20['annualized']*100:5.2f}/{p20['max_drawdown']*100:5.2f} "
        f"y10 {y10['annualized']*100:5.2f}/{y10['max_drawdown']*100:5.2f} "
        f"p22 {p22['annualized']*100:5.2f}/{p22['max_drawdown']*100:5.2f}"
    )


def main() -> None:
    print("Loading close-only execution data from AssetTimeMachine public history helpers...")
    dates, prices, cov = nb.load_aligned()
    c = vaa.build_cache(prices)

    print("Fetching real OHLC for equity crisis gates...")
    raw_ohlc = load_ohlc_sources()
    for s, series in raw_ohlc.items():
        ds = sorted(series)
        print(f"OHLC {s:20s} rows={len(ds):5d} {ds[0]}..{ds[-1]}")
    us_cluster = normalized_cluster_ohlc(dates, raw_ohlc, ["nasdaq", "sp500"])
    cn_cluster = normalized_cluster_ohlc(dates, raw_ohlc, ["csi300", "shanghai_composite"])
    us_cluster["ma60"] = ma(us_cluster["close"], 60)
    us_cluster["ma120"] = ma(us_cluster["close"], 120)
    us_cluster["ma200"] = ma(us_cluster["close"], 200)
    cn_cluster["ma60"] = ma(cn_cluster["close"], 60)
    cn_cluster["ma120"] = ma(cn_cluster["close"], 120)
    cn_cluster["ma200"] = ma(cn_cluster["close"], 200)

    # Start where all key OHLC clusters are meaningful and after warmup for 200d trend.
    start_date = dt.date(2006, 1, 4)
    results = []
    for name in [
        "current_vaa_same_window",
        "vaa_ohlc_crisis_gate",
        "vaa_mania_aware_crisis_gate",
        "vaa_extension_aware_crisis_gate",
        "vaa_fragility_hard_crisis_gate",
        "vaa_fragility_soft_crisis_gate",
        "vaa_mania_substitution_crisis_gate",
        "vaa_mania_safe_haven_crisis_gate",
        "vaa_region_cluster_one_per_region",
        "vaa_core_satellite_state_machine",
    ]:
        if name == "current_vaa_same_window":
            sim_name = "baseline"
        elif name == "baseline":
            sim_name = "baseline"
        else:
            sim_name = name
        # baseline path: no overlay, but same simulator uses name mismatch to skip overlays.
        actual_name = "baseline" if name == "current_vaa_same_window" else name
        r = simulate(actual_name, dates, prices, c, us_cluster, cn_cluster, start_date)
        r["name"] = name
        results.append(r)
        print_result(r)

    serial = {
        "coverage_close_execution": cov,
        "ohlc_coverage": {s: {"count": len(v), "start": str(sorted(v)[0]), "end": str(sorted(v)[-1])} for s, v in raw_ohlc.items()},
        "results": [
            {
                "name": r["name"],
                "start": r["start"],
                "end": r["end"],
                "trades": r["trades"],
                "exposure": round(r["exposure"], 6),
                "gate_events_count": r.get("gate_events_count"),
                "gate_events_sample": r.get("gate_events_sample"),
                "slices": {k: sm_metrics(v) for k, v in r["slices"].items()},
            }
            for r in results
        ],
    }
    out = Path("/tmp/atm_risk_engine_strategy_results.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2, default=str))
    print("WROTE", out)


if __name__ == "__main__":
    main()
