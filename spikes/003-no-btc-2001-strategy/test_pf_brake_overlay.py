#!/usr/bin/env python3
"""Targeted portfolio-brake test on gold-blowoff candidates."""
from __future__ import annotations

import datetime as dt
import importlib.util
import json
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("exp", HERE / "search_no_btc_2001_expanded_universe.py")
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load expanded module")
exp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exp)

prev = json.loads(Path("/tmp/atm_no_btc_2001_gold_blowoff_targeted.json").read_text())
base_cfgs = [x["config"] for x in (prev.get("under12_by_return") or prev.get("score_top") or [])[:20]]


def sm(m: dict[str, Any] | None) -> dict[str, Any] | None:
    return None if m is None else {k: (round(v, 6) if isinstance(v, float) else v) for k, v in m.items()}


def score(m: dict[str, Any], sl: dict[str, Any]) -> float:
    ann = m["annualized"] or 0
    d = m["max_drawdown"]
    sh = m["sharpe"] or 0
    return ann * 2.5 + (sl["post_2020"]["annualized"] or 0) * 0.2 + (sl["last_10y"]["annualized"] or 0) * 0.2 + sh * 0.2 - d * 2.5 - max(d - 0.10, 0) * 16


def main() -> None:
    dates, prices, coverage = exp.load_expanded()
    cache = exp.build_cache(prices)
    results = []
    seen = set()
    for base_cfg in base_cfgs:
        for pf_brake_dd in [0.035, 0.045, 0.055, 0.065]:
            for pf_brake_scale in [0.35, 0.50, 0.65]:
                for pf_brake_gold_add in [0.0, 0.05, 0.10]:
                    cfg = dict(base_cfg)
                    cfg["pf_brake_dd"] = pf_brake_dd
                    cfg["pf_brake_scale"] = pf_brake_scale
                    cfg["pf_brake_gold_add"] = pf_brake_gold_add
                    key = json.dumps(cfg, sort_keys=True, ensure_ascii=False)
                    if key in seen:
                        continue
                    seen.add(key)
                    sim = exp.simulate(dates, prices, cache, cfg)
                    vals = sim["values"]
                    m = exp.base.metrics(dates, vals)
                    sl = {
                        "post_2020": exp.base.slice_metrics(dates, vals, dt.date(2020, 1, 1)),
                        "last_10y": exp.base.slice_metrics(dates, vals, dates[-1].replace(year=dates[-1].year - 10)),
                        "post_2022": exp.base.slice_metrics(dates, vals, dt.date(2022, 1, 1)),
                    }
                    results.append({"score": score(m, sl), "config": cfg, "metrics": m, "slices": sl, "trades": sim["trades"], "exposure": sim["exposure"], "max_dd_episode": exp.mdd_episode(dates, vals)})
    results.sort(key=lambda x: (x["score"], x["metrics"]["annualized"] or 0), reverse=True)
    under10 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.10], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under105 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.105], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    under11 = sorted([x for x in results if x["metrics"]["max_drawdown"] <= 0.11], key=lambda x: x["metrics"]["annualized"] or 0, reverse=True)
    def simp(x: dict[str, Any]) -> dict[str, Any]:
        return {"score": round(x["score"], 6), "trades": x["trades"], "exposure": round(x["exposure"], 4), "config": x["config"], "metrics": sm(x["metrics"]), "slices": {k: sm(v) for k, v in x["slices"].items()}, "max_dd_episode": x["max_dd_episode"]}
    serial = {"coverage": coverage, "evaluated": len(results), "score_top": [simp(x) for x in results[:30]], "under10_by_return": [simp(x) for x in under10[:30]], "under105_by_return": [simp(x) for x in under105[:30]], "under11_by_return": [simp(x) for x in under11[:30]]}
    out = Path("/tmp/atm_no_btc_2001_pf_brake_targeted.json")
    out.write_text(json.dumps(serial, ensure_ascii=False, indent=2, default=str))
    print("COVERAGE", coverage["aligned_dynamic"], "EVALUATED", len(results), "WROTE", out)
    for sec in ["under10_by_return", "under105_by_return", "under11_by_return", "score_top"]:
        print("\n==", sec, "==")
        for i, x in enumerate(serial[sec][:10], 1):
            m=x["metrics"]; p20=x["slices"]["post_2020"]; y10=x["slices"]["last_10y"]; p22=x["slices"]["post_2022"]
            print(i, "ann", f"{m['annualized']*100:.2f}%", "mdd", f"{m['max_drawdown']*100:.2f}%", "sharpe", round(m['sharpe'] or 0,2), "p20", f"{p20['annualized']*100:.2f}/{p20['max_drawdown']*100:.2f}", "y10", f"{y10['annualized']*100:.2f}/{y10['max_drawdown']*100:.2f}", "p22", f"{p22['annualized']*100:.2f}/{p22['max_drawdown']*100:.2f}", "dd", x["max_dd_episode"], "cfg", x["config"])

if __name__ == "__main__":
    main()
