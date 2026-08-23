#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,os,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]; TRIAL_ID='ATM-SVP3-VOLATILITY-SWITCH-001'; CANDIDATE_ID='S-VOLATILITY-SWITCH-001'; FRAGMENT=ROOT/'tools/volatility_switch_001.swiftpart'; LOGIC=ROOT/'tools/volatility_switch_001_logic.swift'; ASSEMBLED=Path('/private/tmp/atm_volatility_switch_001.swift'); BINARY=Path('/private/tmp/atm_volatility_switch_001')
def run(cmd,env=None,timeout=360):
 p=subprocess.run(cmd,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout,check=False)
 if p.returncode: sys.stderr.write(p.stdout[-16000:]); raise RuntimeError('command failed')
 return p.stdout
def compile_binary():
 run([sys.executable,'scripts/assemble_strategy_metric_dump.py','--fragment',str(FRAGMENT.relative_to(ROOT)),'--output',str(ASSEMBLED)])
 run(['xcrun','swiftc','-parse-as-library','-module-cache-path','/private/tmp/atm-swift-module-cache','AssetTimeMachine/Backtest/BacktestModels.swift','AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift','AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift','AssetTimeMachine/Backtest/BacktestFXConverter.swift','AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift','AssetTimeMachine/Backtest/BacktestEngine.swift',str(LOGIC.relative_to(ROOT)),str(ASSEMBLED),'-o',str(BINARY)])
def parse(stdout):
 prefix='VOLATILITY_SWITCH_001_FORMAL_JSON='; rows=[x[len(prefix):] for x in stdout.splitlines() if x.startswith(prefix)]
 if len(rows)!=1 or 'VOLATILITY_SWITCH_001_FORMAL_OK' not in stdout: raise RuntimeError('formal output incomplete')
 d=json.loads(rows[0]); assert d['trial_id']==TRIAL_ID and d['candidate_id']==CANDIDATE_ID and d['short_window']==21 and d['long_window']==252 and d['evaluation_start']=='2002-07-03' and abs(d['fee_percent_per_trade']-1)<1e-12 and abs(d['slippage_percent_per_trade']-.05)<1e-12; return d
def evaluate(d):
 c,b,cash=d['candidate'],d['barbell_control'],d['cash_control']; folds=c['folds']; pos=sum(x['sharpe']>0 for x in folds)
 val={'actual_trades_gt_0':c['trades']>0,'full_cagr_gt_0':c['cagr_percent']>0,'full_sharpe_gt_0':c['sharpe']>0,'full_mdd_le_25pct':c['mdd_percent']<=25,'positive_sharpe_folds_ge_70pct':pos/len(folds)>=.70,'max_gross_le_1':c['max_gross']<=1.000000001,'cash_nonnegative':c['minimum_cash']>=-1e-8}
 obj={'cagr_ge_12pct':c['cagr_percent']>=12,'sharpe_ge_1':c['sharpe']>=1,'mdd_le_20pct':c['mdd_percent']<=20,'since2020_cagr_positive':c['since2020_cagr_percent']>0,'since2022_cagr_positive':c['since2022_cagr_percent']>0,'cagr_gt_cash':c['cagr_percent']>cash['cagr_percent']}
 comp={'sharpe_gt_barbell':c['sharpe']>b['sharpe'],'mdd_lt_barbell':c['mdd_percent']<b['mdd_percent']}
 return {'status':'PASS' if all(val.values()) else 'FAIL','validation_status':'PASS' if all(val.values()) else 'FAIL','objective_status':'PASS' if all(obj.values()) else 'FAIL','comparison_status':'PASS' if all(comp.values()) else 'FAIL','validation_checks':val,'objective_checks':obj,'comparison_checks':comp,'validation_warnings':['execution_stress_not_in_this_R1_trial'],'diagnostics':{'positive_fold_count':pos,'fold_count':len(folds),'barbell_cagr_percent':b['cagr_percent'],'barbell_sharpe':b['sharpe'],'barbell_mdd_percent':b['mdd_percent'],'cash_cagr_percent':cash['cagr_percent']}}
def write_outputs(outdir,d,e):
 outdir.mkdir(parents=True,exist_ok=True); (outdir/'candidate-metrics.json').write_text(json.dumps({**d,'three_axis_evaluation':e},ensure_ascii=False,indent=2,sort_keys=True)+'\n')
 with (outdir/'candidate-metrics.csv').open('w',newline='',encoding='utf-8') as f:
  fields=['id','kind','cagr_percent','mdd_percent','volatility_percent','sharpe','trades','average_cash_ratio','max_gross','minimum_cash','target_fingerprint']; w=csv.DictWriter(f,fieldnames=fields,lineterminator='\n'); w.writeheader()
  for kind,row in [('CANDIDATE',d['candidate']),('BARBELL_CONTROL',d['barbell_control']),('CASH_CONTROL',d['cash_control'])]: w.writerow({'kind':kind,**{k:row.get(k) for k in fields if k!='kind'}})
def main():
 ap=argparse.ArgumentParser(); ap.add_argument('--fixture',required=True); ap.add_argument('--output-dir'); ap.add_argument('--formal',action='store_true'); a=ap.parse_args(); compile_binary(); env=os.environ.copy(); env.update({'ATM_HISTORY_FIXTURE':a.fixture,'ATM_VOLATILITY_SWITCH_001':'1'}); 
 if a.formal: env.update({'ATM_VOLATILITY_SWITCH_001_FORMAL':'1','ATM_VOLATILITY_SWITCH_001_OUTPUT_DIR':a.output_dir})
 stdout=run([str(BINARY)],env=env)
 if not a.formal:
  if 'VOLATILITY_SWITCH_001_SMOKE_OK' not in stdout: print(stdout,end=''); raise RuntimeError('smoke failed')
  print(stdout,end=''); return 0
 d=parse(stdout); e=evaluate(d); write_outputs(Path(a.output_dir),d,e); print(json.dumps({'trial_id':TRIAL_ID,'candidate_id':CANDIDATE_ID,**e},ensure_ascii=False,sort_keys=True)); print('VOLATILITY_SWITCH_001_FORMAL_COMPLETE'); return 0
if __name__=='__main__': raise SystemExit(main())
