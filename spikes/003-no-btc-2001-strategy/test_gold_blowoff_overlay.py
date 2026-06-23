#!/usr/bin/env python3
"""Targeted test: gold blowoff cap on previous expanded-universe top candidates."""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("exp", HERE / "search_no_btc_2001_expanded_universe.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load expanded search module")
exp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exp)

prev_path = Path("/tmp/atm_no_btc_2001_expanded_universe.json")
prev = json.loads(prev_path.read_text())
base_cfgs = [x["config"] for x in prev.get("score_top", [])[:30]]
# De-dupe base configs stripped of any previous gold_hot_cap.
seen = set()
cfgs: list[dict[str, Any]] = []
for cfg in base_cfgs:
    c = dict(cfg)
    c.pop("gold_hot_cap", None)
    key = json.dumps(c, sort_keys=True, ensure_ascii=False)
    if key not in seen:
        seen.add(key)
        cfgs.append(c)


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    return None if m is None else {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def score(m: dict[str, Any], sl: dict[str, Any]) -> float:
    ann = m["annualized"] or 0
    d = m["max_drawdown"]
    sh = m["sharpe"] or 0
    return ann * 2.2 + (sl["post_2020"]["annualized"] or 0) * 0.2 + (sl["last_10y"]["annualized"] or 0) * 0.2 + sh * 0.20 - d * 2.2 - max(d - 0.10, 0) * 12


def main() -> None:
    dates, prices, coverage = exp.load_expanded()
    cache = exp.build_cache(prices)
    results = []
    for base_cfg in cfgs:
        for gold_hot_cap in [0.0, 0.10, 0.20, 0.30, 0.35, 0.70]:
            for cut_to_gold in [0.0, 0.35, base_cfg.get("cut_to_gold", 0.65)]:
                cfg = dict(base_cfg)
                cfg["gold_hot_cap"] = gold_hot_cap
                cfg["cut_to_gold"] = cut_to_gold
                sim = exp.simulate(dates, prices, cache, cfg)
                vals = sim["values"]
                m = exp.base.metrics(dates, vals)
                sl = {
                    "post_2020": exp.base.slice_metrics(dates, vals, dt.date(2020, 1, 1)),
                    "last_10y": exp.base.slice_metrics(dates, vals, dates[-1].replace(year=dates[-1].year - 10)),
                    "post_2022": exp.base.slice_metrics(dates, vals, dt.date(2022, 1, 1)),
                }
                results.append({
                    "score": score(m, sl),
                    "config": cfg,
                    "metrics": m,
                    "slices": sl,
                    "trades": sim["trades"],
                    "exposure": sim["exposure"],
                    "max_dd_episode": exp.mdd_episode(dates, vals),
                })
    results.sort(key=lambda x: (x["score"], x["metrics"]["annualized"] or 0), reverse=True)
    under10 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.10], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under11 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.11], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under12 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.12], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    def simp(x: dict[str, Any]) -> dict[str, Any]:
        return {"score": round(x["score"], 6), "trades": x["trades"], "exposure": round(x["exposure"], 4), "config": x["config"], "metrics": sm(x["metrics"]), "slices": {k: sm(v) for k, v in x["slices"].items()}, "max_dd_episode": x["max_dd_episode"]}
    serial = {"coverage": coverage, "evaluated": len(results), "score_top": [simp(x) for x in results[:30]], "under10_by_return": [simp(x) for x in under10[:30]], "under11_by_return": [simp(x) for x in under11[:30]], "under12_by_return": [simp(x) for x in under12[:30]]}
    out = Path("/tmp/atm_no_btc_2001_gold_blowoff_targeted.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2, default=str))
    print("COVERAGE", coverage["aligned_dynamic"], "EVALUATED", len(results), "WROTE", out)
    for sec in ["under10_by_return", "under11_by_return", "under12_by_return", "score_top"]:
        print("\n==", sec, "==")
        for i, x in enumerate(serial[sec][:10], 1):
            m=x["metrics"]; p20=x["slices"]["post_2020"]; y10=x["slices"]["last_10y"]
            print(i, "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", round(m['sharpe'] or 0,2), "p20", f"{p20['annualized']*100:.2f}/{p20['max_drawdown']*100:.2f}", "y10", f"{y10['annualized']*100:.2f}/{y10['max_drawdown']*100:.2f}", "dd", x["max_dd_episode"], "cfg", x["config"])

if __name__ == "__main__":
    main()
