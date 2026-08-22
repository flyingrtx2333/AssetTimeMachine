#!/usr/bin/env python3
from __future__ import annotations
import argparse, hashlib, json, re, subprocess
from pathlib import Path
from typing import Any
ROOT=Path(__file__).resolve().parents[1]
SOURCE_REPOSITORY="flyingrtx2333/AssetTimeMachine"
SPECS={
"F-COT-LEV-SPX":("ATM-SVP2-COT-001","COT 杠杆资金 SPX 净多变化","positioning","atm.formal.cot_lev_spx","tools/cot_leveraged_money_spx_v1.swiftpart","alpha_candidate"),
"F-MARGIN-LEV-US":("ATM-SVP2-MARGIN-001","FINRA 融资杠杆变化","market_leverage","atm.formal.finra_margin_leverage","tools/finra_margin_leverage_v1.swiftpart","alpha_candidate"),
"F-BDLEV-ANNUAL-US":("ATM-SVP2-BDLEV-001","券商交易商年度账面杠杆","dealer_leverage","atm.formal.broker_dealer_annual_leverage","tools/broker_dealer_leverage_v1.swiftpart","alpha_candidate"),
"F-SEC-INSIDER-BUY-BREADTH-US":("ATM-SVP2-INSIDER-001","SEC 内部人买入广度","insider_activity","atm.formal.sec_insider_buy_breadth","tools/sec_insider_buy_breadth_v1.swiftpart","alpha_candidate"),
"F-NET-PAYOUT-YIELD-US":("ATM-SVP2-NPY-001","企业净派息收益率","corporate_payout","atm.formal.net_payout_yield_us","tools/net_payout_yield_v1.swiftpart","alpha_candidate"),
"F-TIC-FLOW-CONTRARIAN-US":("ATM-SVP2-TIC-001","TIC 外资美股流向反向状态","cross_border_flow","atm.formal.tic_equity_flow_contrarian","tools/tic_foreign_equity_flow_v1.swiftpart","alpha_candidate"),
"F-SLOOS-STANDARDS":("ATM-SVP2-SLOOS-001","SLOOS 银行信贷标准","credit_conditions","atm.formal.sloos_standards","tools/sloos_standards_v1.swiftpart","alpha_candidate"),
"F-CBOE-PC-EXECUTION":("ATM-SVP2-CBOE-PC-001","CBOE 股票 Put/Call 执行状态","options_sentiment","atm.formal.cboe_equity_put_call_execution","tools/cboe_equity_put_call_execution_v1.swiftpart","alpha_candidate"),
"F-HESHARE-US-COMPLETION":("ATM-SVP2-HESHARE-001","家庭股票配置占比 HEShare","household_positioning","atm.formal.household_equity_share","tools/household_equity_share_v1.swiftpart","alpha_candidate"),
"F-IWD-SP500-ROLE":("ATM-SVP2-US-VALUE-ROLE-001","IWD 美股价值角色替代","role_substitution","atm.formal.iwd_sp500_role","tools/us_value_role_substitution_v1.swiftpart","diagnostic"),
"F-VBR-SP500-ROLE":("ATM-SVP2-US-VALUE-ROLE-001","VBR 小盘价值角色替代","role_substitution","atm.formal.vbr_sp500_role","tools/us_value_role_substitution_v1.swiftpart","diagnostic"),
}
def sha(path:Path)->str: return hashlib.sha256(path.read_bytes()).hexdigest()
def vkey(cid:str)->str: return cid.removeprefix("F-").lower().replace("_","-")+"-v1"
def artifact(key,kind,path,fk,vk):
 return {"artifact_key":key,"artifact_type":kind,"original_name":path.name,"mime_type":"application/json","byte_size":path.stat().st_size,"sha256":sha(path),"local_path":path.relative_to(ROOT).as_posix(),"factor_key":fk,"version_key":vk}
def definition(prereg,cid):
 if isinstance(prereg.get("factor_definition"),dict): return prereg["factor_definition"]
 defs=prereg.get("candidate_definitions") or {}
 if isinstance(defs,dict) and cid in defs: return defs[cid]
 return {"candidate_id":cid,"allowed_changes":prereg.get("allowed_changes",[])}
def formula(d,cid):
 if isinstance(d,dict):
  for k in ("risk_on_rule","signal_rule","formula","rule","definition"):
   if d.get(k): return str(d[k])
 return json.dumps(d,ensure_ascii=False,sort_keys=True)[:4000] or cid
def build(commit):
 factors=[]; arts=[]; datasets={}; decisions={}
 for cid,(tid,name,family,fk,source_path,role) in SPECS.items():
  pp=ROOT/f"tools/research-results/strategy-validation/preregistrations/{tid}.json"; rp=ROOT/f"tools/research-results/strategy-validation/results/{tid}.json"; dp=ROOT/f"tools/research-results/strategy-validation/datasets/{tid}.json"
  pre=json.loads(pp.read_text()); res=json.loads(rp.read_text()); rows={r["candidate_id"]:r for r in res.get("candidate_results",[])}; row=rows[cid]
  robust=bool((row.get("metrics") or {}).get("robust_factor_pass",False)); assert not robust, cid
  datasets[dp.relative_to(ROOT).as_posix()]={"sha256":sha(dp)}; vk=vkey(cid); d=definition(pre,cid); sp=ROOT/source_path
  decisions[fk]={"candidate_id":cid,"trial_id":tid,"trial_status":res.get("status"),"robust_factor_pass":False,"formal_result_artifact":rp.relative_to(ROOT).as_posix()}
  factors.append({"factor_key":fk,"display_name":name,"family":family,"description":f"ATM-SVP-2 正式候选 {cid}；正式结果未通过冻结 robust gate，按研究闭环规则以 rejected 状态永久归档。","tags":["ATM-SVP-2","formal_trial","rejected",cid.lower()],"research_role":role,"owner_name":"AssetTimeMachine Research","source_project":"AssetTimeMachine","version":{"version_key":vk,"formula_text":formula(d,cid),"parameters":{"historical_trial_id":tid,"factor_definition":d,"shared_rules":pre.get("shared_rules",{})},"required_inputs":[],"applicable_universe":["nfci-dual-core-v11 research"],"frequency":"daily","lookback_sessions":0,"observation_lag_sessions":1,"source_path":source_path,"code_sha256":sha(sp),"lifecycle_status":"rejected","materialization_policy":"none"},"results":[]})
  suf=cid.removeprefix("F-").lower().replace("_","-"); arts += [artifact(suf+"-preregister","preregistration",pp,fk,vk),artifact(suf+"-result","formal_result",rp,fk,vk)]
 enc=json.dumps(datasets,sort_keys=True,separators=(",",":")).encode(); batch=f"atm-svp2-postprotocol-rejected-sync-{commit[:12]}"
 return {"schema_version":"factor-library-v1","batch_key":batch,"source_repository":SOURCE_REPOSITORY,"source_commit":commit,"dataset_fingerprint":hashlib.sha256(enc).hexdigest(),"methodology":{"sync_kind":"formal_result_ledger_reconciliation","new_research_trial_created":False,"factor_catalog_before_batch":22,"this_batch_rejected_candidates":len(factors),"factor_catalog_after_batch":22+len(factors),"historical_decisions":decisions,"structured_results_policy":"exact formal results attached as immutable artifacts; no survivorship filtering"},"run_key":batch,"run_title":"ATM-SVP-2 后协议正式失败因子补档","runner_path":"scripts/export_factor_library_postprotocol_rejected_manifest.py","runner_sha256":sha(ROOT/"scripts/export_factor_library_postprotocol_rejected_manifest.py"),"dataset_spec":{"kind":"formal_result_ledger_reconciliation","dataset_manifests":datasets},"summary":"对账 validation ledger 与生产因子库，补齐11个已有正式RESULT但尚未归档的失败因子/诊断候选。","factors":factors,"artifacts":arts,"observations":[]}
def main():
 ap=argparse.ArgumentParser(); ap.add_argument("--output",required=True); a=ap.parse_args(); commit=subprocess.check_output(["git","rev-parse","HEAD"],cwd=ROOT,text=True).strip(); m=build(commit); out=ROOT/a.output; out.parent.mkdir(parents=True,exist_ok=True); out.write_text(json.dumps(m,ensure_ascii=False,indent=2,sort_keys=True)+chr(10)); print(f"POSTPROTOCOL_FACTOR_MANIFEST factors={len(m['factors'])} artifacts={len(m['artifacts'])} output={out.relative_to(ROOT)}")
if __name__=="__main__": main()
