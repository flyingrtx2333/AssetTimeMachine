"""Audit one immutable shared-Swift account. Does not generate any account."""
from pathlib import Path
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
import gzip, hashlib, json, math, statistics

HERE = Path(__file__).resolve().parent
def raw(p): return p.read_bytes() if p.exists() else gzip.decompress(Path(str(p)+'.gz').read_bytes())
def read(p): return json.loads(raw(p))
def sha(b): return hashlib.sha256(b).hexdigest()
def day(text): return datetime.fromisoformat(text.replace('Z','+00:00')).astimezone(ZoneInfo('Asia/Shanghai')).date().isoformat()
def close(a,b): assert math.isclose(a,b,rel_tol=1e-10,abs_tol=1e-10),(a,b)

account = read(HERE/'qual-run/result.json'); evidence = read(HERE/'qual-run/evidence.json')
parameters = read(HERE/'qual-run/parameters.json'); configuration = read(HERE/'configuration.json')
assert sha(raw(HERE/'qual-run/result.json')) == evidence['result_sha256']
assert sha(raw(HERE/'qual-run/parameters.json')) == evidence['parameters_sha256']
assert parameters['run'] == configuration['run']
assert parameters['frozen'] == read(HERE/'EXPECTED_QUAL_PARAMETERS.json')['frozen_parameters']
assert evidence['source_commit'] == read(HERE/'PRE_CAPITAL_COMMITS.json')['app_source_commit']
history = read(HERE/'combined-history.json'); macro = raw(HERE/'nfci.json')
assert sha(raw(HERE/'combined-history.json')) == evidence['dataset_sha256']
assert sha(macro) == evidence['macro_sha256']
parent = HERE.parent/'product-benchmark-scope-replay-2026-10-08'
assert history['series'][:-1] == read(parent/'inputs/history.json')['series']
assert macro == raw(parent/'inputs/nfci.json')
source = read(HERE/'qual-response.json')
assert history['series'][-1] == source['series'][0]
observed = {s['symbol']:set(s['dates']) for s in history['series']}
observed['nasdaq'] = observed['nasdaq_composite']
states = account['daily_states']; dates = [s['date'] for s in states]
assert dates == sorted(set(dates))
for s in states:
    held = s['holdingsBySymbol']
    assert all(v >= 0 and math.isfinite(v) for v in held.values())
    assert s['cash'] >= -1e-8 and s['portfolioValue'] > 0
    close(sum(held.values()) + s['cash'],s['portfolioValue'])
    assert sum(held.values()) <= s['portfolioValue']*(1+1e-12)
    assert all(v >= 0 and math.isfinite(v) for v in s['targetWeights'].values())
    assert sum(s['targetWeights'].values()) <= 1+1e-12
    assert 'money511990_cny' not in held

role_fills = []; missing_qual_fill_dates = []
for t in account['trades']:
    assert day(t['date']) in observed[t['assetSymbol']]
    gross = t['units']*t['price']
    if t['actionRawValue']=='buy':close(t['cashAmount']*(1-.00025),gross)
    else:
        assert t['actionRawValue']=='sell';close(t['cashAmount'],gross*(1-.00025))
    if t['assetSymbol']=='sp500' and day(t['date'])>='2013-07-19':
        role_fills.append(t)
        if day(t['date']) not in observed['qual']: missing_qual_fill_dates.append(t['date'])

values = [s['portfolioValue'] for s in states]
returns = [b/a-1 for a,b in zip(values,values[1:])]
years = (datetime.fromisoformat(day(dates[-1]))-datetime.fromisoformat(day(dates[0]))).days/365.25
normalized = peak = 1.0; mdd = 0.0
for r in returns:
    normalized *= 1+r;peak = max(peak,normalized);mdd = max(mdd,(peak-normalized)/peak)
calculated = {'annualized_return':normalized**(1/years)-1,
              'sharpe_rf0':statistics.mean(returns)/statistics.stdev(returns)*math.sqrt(len(returns)/years),
              'max_drawdown':mdd}
for k,v in calculated.items():close(v,account[k])
old = read(HERE/'old19-result.json')
assert old == read(parent/'run/result.json')
common = [s['date'] for s in old[0]['dailyStates']]
assert all([s['date'] for s in r['dailyStates']]==common for r in old)
missing = sorted(set(common)-set(dates)); assert len(common)==5595 and len(missing)==2509
assert all(day(d)<'2013-07-18' for d in missing)
audited_at = datetime.now(timezone.utc).isoformat()
failure = {'status':'FAIL_FROZEN_FULL_LONG_CALENDAR_COVERAGE_NO_RESCUE',
           'verified_at':audited_at,'required_common_start':'2002-09-18','required_common_end':'2026-09-30',
           'required_common_dates':len(common),'missing_dates':missing,
           'actual_account_start':day(dates[0]),'actual_account_end':day(dates[-1]),
           'actual_state_count':len(states),'cause':'Shared Registry requires QUAL input and its available-date intersection begins at ETF first quote. App source contains a pre-listing S&P hybrid role, but the Registry account did not execute pre-listing capital days.',
           'calendar_or_economic_parameters_changed':False,'account_rerun':False,
           'not_concluded':['QUAL inferior over the original2002 full common history','20-comparator same-long-history ranking complete','old formal quality-alpha failure reversed']}
(HERE/'PRIMARY_COMPARISON_FAILURE.json').write_text(json.dumps(failure,ensure_ascii=False,indent=2)+'\n')
audit = {'status':'PASS_NATIVE_SAVED_ACCOUNTING_AND_METRICS_LONG_COMPARISON_FAIL',
         'audited_at':audited_at,'states_checked':len(states),'fills_checked':len(account['trades']),
         'original_19_saved_results_unchanged':True,'original_other_series_and_macro_unchanged':True,
         'original_QUAL_rule_parameters_unchanged':True,'native_App_report_metrics':calculated,
         'post_substitution_sp500_role_fill_count':len(role_fills),
         'role_fills_without_real_QUAL_date':missing_qual_fill_dates,
         'hybrid_calendar_dates_without_QUAL_quote':read(HERE/'INPUT_QUALIFICATION.json')['qual_missing_sp500_dates'],
         'actual_tradable_QUAL_units_and_issuer_corporate_cash_certified':False,
         'not_certified':['original2002 full common comparison','independent historical macro release-vintage reconstruction',
                          'QUAL versus S&P price/total-return economic equivalence','all economic targets/settlement intent','G0-G6','pristine OOS']}
(HERE/'SAVED_AUDIT.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2)+'\n')
summary = {'status':'QUAL_SOURCE_RECOVERED_NATIVE_REPLAY_COMPLETE_LONG_COMPARISON_FAILED',
           'completed_at':read(HERE/'RUN_RECEIPT.json')['finished_at'],'source_qualification_at':read(HERE/'INPUT_QUALIFICATION.json')['at'],
           'new_candidate_count':0,'funded_replays':1,'funded_reruns':0,'parameter_search_budget':0,
           'id':'nfci-dual-core-v11-qual-role','native_start':day(dates[0]),'native_end':day(dates[-1]),
           'native_point_count':len(states),'native_sharpe_rf0':account['sharpe_rf0'],
           'native_cagr_percent':account['annualized_return']*100,'native_mdd_percent':account['max_drawdown']*100,
           'native_trade_count':len(account['trades']),'fixed_long_calendar_comparison':'FAIL_MISSING2509_PRE_LISTING_DATES',
           'old_19_metric_rows_unchanged':True,'old_19_highest_full_common_sharpe':max(r['slices']['full']['sharpeRF0'] for r in old),
           'highest_20_full_common_comparator':None,'complete_executable_frontier_certified':False,
           'formal_validation':False,'recommendation_eligible':False,'objective_complete':False,
           'conclusion':'Existing QUAL data gap is resolved and current native App account was replayed once. Its full native2013+ Rf0 Sharpe0.962698 cannot be directly ranked against original19 full2002+0.996612. Fixed no-shortening comparison failed structurally; no price/asset/period rescue and no new single-indicator winner.'}
(HERE/'SUMMARY.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'status':audit['status'],'states':len(states),'fills':len(account['trades']),'native_sharpe_rf0':account['sharpe_rf0'],'missing_long_dates':len(missing),'missing_QUAL_fill_dates':len(missing_qual_fill_dates)}))
