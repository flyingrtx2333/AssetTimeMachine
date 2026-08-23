#!/usr/bin/env python3
from __future__ import annotations
import argparse,csv,json,os,subprocess,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
TRIAL_ID='ATM-SVP3-BTC-SMA200-001';CANDIDATE_ID='S-BTC-SMA200-001'
FRAGMENT=ROOT/'tools/btc_sma200_001.swiftpart';LOGIC=ROOT/'tools/btc_sma200_001_logic.swift'
ASSEMBLED=Path('/private/tmp/atm_btc_sma200_001.swift');BINARY=Path('/private/tmp/atm_btc_sma200_001')
def run(cmd,env=None,timeout=360):
 c=subprocess.run(cmd,cwd=ROOT,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout,check=False)
 if c.returncode: sys.stderr.write(c.stdout[-16000:]);raise RuntimeError('command failed: '+' '.join(cmd))
 return c.stdout
def compile_binary():
 run([sys.executable,'scripts/assemble_strategy_metric_dump.py','--fragment',str(FRAGMENT.relative_to(ROOT)),'--output',str(ASSEMBLED)])
 run(['xcrun','swiftc','-parse-as-library','-module-cache-path','/private/tmp/atm-swift-module-cache','AssetTimeMachine/Backtest/BacktestModels.swift','AssetTimeMachine/Backtest/BacktestMetricsCalculator.swift','AssetTimeMachine/Backtest/BacktestSeriesAlignment.swift','AssetTimeMachine/Backtest/BacktestFXConverter.swift','AssetTimeMachine/Backtest/BacktestAdvancedSeriesPreparer.swift','AssetTimeMachine/Backtest/BacktestEngine.swift',str(LOGIC.relative_to(ROOT)),str(ASSEMBLED),'-o',str(BINARY)])
def validate(d):
 if d.get('trial_id')!=TRIAL_ID or d.get('candidate_id')!=CANDIDATE_ID: raise RuntimeError('identity drift')
 if d.get('evaluation_start')!='2018-06-05' or d.get('evaluation_end')!='2026-08-20': raise RuntimeError('window drift')
 if int(d.get('lookback_common_sessions',-1))!=200: raise RuntimeError('lookback drift')
 if abs(float(d.get('fee_percent_per_trade',-1))-1)>1e-12 or abs(float(d.get('slippage_percent_per_trade',-1))-.05)>1e-12: raise RuntimeError('cost drift')
def evaluate(d):
 c=d['candidate'];b=d['btc_buy_hold_control'];cash=d['cash_control'];folds=c.get('folds') or []
 pos=sum(float(x.get('sharpe',0))>0 for x in folds);frac=pos/len(folds) if folds else 0
 checks={'actual_trades_gt_0':int(c['trades'])>0,'full_cagr_gt_0':float(c['cagr_percent'])>0,'full_sharpe_gt_0':float(c['sharpe'])>0,'full_mdd_le_25pct':float(c['mdd_percent'])<=25,'positive_sharpe_folds_ge_70pct':frac>=.70,'max_gross_le_1':float(c['max_gross'])<=1.000000001,'cash_nonnegative':float(c['minimum_cash'])>=-1e-8}
 obj={'cagr_ge_20pct':float(c['cagr_percent'])>=20,'sharpe_ge_1':float(c['sharpe'])>=1,'mdd_le_25pct':float(c['mdd_percent'])<=25,'since2020_cagr_positive':float(c['since2020_cagr_percent'])>0,'since2022_cagr_positive':float(c['since2022_cagr_percent'])>0,'cagr_gt_cash':float(c['cagr_percent'])>float(cash['cagr_percent'])}
 comp={'sharpe_gt_btc_buy_hold':float(c['sharpe'])>float(b['sharpe']),'mdd_lt_btc_buy_hold':float(c['mdd_percent'])<float(b['mdd_percent'])}
 st='PASS' if all(checks.values()) else 'FAIL'
 return {'status':st,'validation_status':st,'objective_status':'PASS' if all(obj.values()) else 'FAIL','comparison_status':'PASS' if all(comp.values()) else 'FAIL','validation_checks':checks,'objective_checks':obj,'comparison_checks':comp,'validation_warnings':['BTCUSDT quote treated as USD-equivalent before historical USD/CNY conversion','execution restricted to SP500 common sessions; weekends intentionally excluded for metric comparability','base run already uses conservative 1.00% fee plus 0.05% slippage'],'diagnostics':{'positive_fold_count':pos,'fold_count':len(folds),'positive_fold_fraction':frac,'btc_buy_hold_cagr_percent':float(b['cagr_percent']),'btc_buy_hold_sharpe':float(b['sharpe']),'btc_buy_hold_mdd_percent':float(b['mdd_percent']),'cash_cagr_percent':float(cash['cagr_percent'])}}
def write_outputs(out,d,e):
 out.mkdir(parents=True,exist_ok=True);(out/'candidate-metrics.json').write_text(json.dumps({**d,'three_axis_evaluation':e},ensure_ascii=False,indent=2,sort_keys=True)+'\n')
 with (out/'candidate-metrics.csv').open('w',newline='',encoding='utf-8') as h:
  f=['id','kind','cagr_percent','mdd_percent','volatility_percent','sharpe','trades','average_cash_ratio','max_gross','minimum_cash','target_fingerprint'];w=csv.DictWriter(h,fieldnames=f,lineterminator='\n');w.writeheader()
  for kind,row in [('CANDIDATE',d['candidate']),('BTC_BUY_HOLD_CONTROL',d['btc_buy_hold_control']),('CASH_CONTROL',d['cash_control'])]:w.writerow({'kind':kind,**{k:row.get(k) for k in f if k!='kind'}})
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--fixture',required=True);ap.add_argument('--output-dir');ap.add_argument('--formal',action='store_true');a=ap.parse_args()
 if a.formal and not a.output_dir:raise SystemExit('--formal requires --output-dir')
 compile_binary();env=os.environ.copy();env.update({'ATM_HISTORY_FIXTURE':a.fixture,'ATM_BTC_SMA200_001':'1'})
 if a.formal:env['ATM_BTC_SMA200_001_FORMAL']='1';env['ATM_BTC_SMA200_001_OUTPUT_DIR']=a.output_dir
 out=run([str(BINARY)],env=env)
 if not a.formal:
  if 'BTC_SMA200_001_SMOKE_OK' not in out:print(out,end='');raise RuntimeError('smoke failed')
  print(out,end='');return 0
 pref='BTC_SMA200_001_FORMAL_JSON=';lines=[x[len(pref):] for x in out.splitlines() if x.startswith(pref)]
 if len(lines)!=1 or 'BTC_SMA200_001_FORMAL_OK' not in out:raise RuntimeError('formal output incomplete')
 d=json.loads(lines[0]);validate(d);e=evaluate(d);write_outputs(Path(a.output_dir),d,e);print(json.dumps({'trial_id':TRIAL_ID,'candidate_id':CANDIDATE_ID,**e},ensure_ascii=False,sort_keys=True));print('BTC_SMA200_001_FORMAL_COMPLETE');return 0
if __name__=='__main__':raise SystemExit(main())
