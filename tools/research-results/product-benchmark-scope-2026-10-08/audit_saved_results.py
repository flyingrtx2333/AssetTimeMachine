"""Read retained outputs only; never creates targets, trades, or account returns."""
from pathlib import Path
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
import collections
import gzip
import hashlib
import json
import math
import statistics

HERE = Path(__file__).resolve().parent

def raw(path):
    return path.read_bytes() if path.exists() else gzip.decompress(Path(str(path) + '.gz').read_bytes())

def read(path):
    return json.loads(raw(path))

def sha(data):
    return hashlib.sha256(data).hexdigest()

def day(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(ZoneInfo('Asia/Shanghai')).date().isoformat()

def close(a, b):
    assert math.isclose(a, b, rel_tol=1e-10, abs_tol=1e-10), (a, b)

def metrics(states):
    # Independent readback of the frozen App formula, not a new metric definition.
    values = [s['portfolioValue'] for s in states]
    returns = [b/a - 1 for a, b in zip(values, values[1:])]
    years = (datetime.fromisoformat(day(states[-1]['date'])) - datetime.fromisoformat(day(states[0]['date']))).days / 365.25
    normalized = peak = 1.0
    drawdown = 0.0
    for r in returns:
        normalized *= 1 + r
        peak = max(peak, normalized)
        drawdown = max(drawdown, (peak-normalized)/peak)
    return {'annualizedReturn': normalized**(1/years)-1, 'maxDrawdown': drawdown,
            'sharpeRF0': statistics.mean(returns)/statistics.stdev(returns)*math.sqrt(len(returns)/years)}

contract = read(HERE/'prepare/contract.json')
evidence = read(HERE/'run/evidence.json')
rows = read(HERE/'run/result.json')
assert sha(raw(HERE/'run/result.json')) == evidence['result_sha256']
assert sha(raw(HERE/'prepare/contract.json')) == evidence['contract_sha256']
assert [r['id'] for r in rows] == contract['ready_ids'] and len(rows) == 19
history = read(HERE/'inputs/history.json')
assert sha(raw(HERE/'inputs/history.json')) == contract['history_sha256']
assert sha(raw(HERE/'inputs/nfci.json')) == contract['macro_sha256']
observed = {s['symbol']: set(s['dates']) for s in history['series']}
observed['nasdaq'] = observed['nasdaq_composite']
counts = collections.Counter()
native_dates = []
for row in rows:
    p = HERE/'run/accounts'/row['id']
    account = read(p/'result.json')
    account_evidence = read(p/'evidence.json')
    assert sha(raw(p/'result.json')) == account_evidence['result_sha256']
    assert sha(raw(p/'parameters.json')) == account_evidence['parameters_sha256']
    ss = account['daily_states']
    assert [s['date'] for s in ss] == sorted(set(s['date'] for s in ss))
    native_dates.append(set(s['date'] for s in ss))
    for state in ss:
        holdings = state['holdingsBySymbol']
        assert all(math.isfinite(v) and v >= 0 for v in holdings.values())
        assert state['cash'] >= -1e-8 and state['portfolioValue'] > 0
        close(sum(holdings.values()) + state['cash'], state['portfolioValue'])
        assert sum(holdings.values()) <= state['portfolioValue'] * (1+1e-12)
        assert sum(state['targetWeights'].values()) <= 1+1e-12
        assert all(v >= 0 and math.isfinite(v) for v in state['targetWeights'].values())
        assert 'money511990_cny' not in holdings
        counts['native_states'] += 1
    for t in account['trades']:
        assert day(t['date']) in observed[t['assetSymbol']], t
        # Shared engine buys deduct fee from the whole cash budget; sells report
        # net proceeds. cashAmount is not the face value of purchased units.
        gross = t['units'] * t['price']
        if t['actionRawValue'] == 'buy': close(t['cashAmount']*(1-0.00025), gross)
        else:
            assert t['actionRawValue'] == 'sell'
            close(t['cashAmount'], gross*(1-0.00025))
        counts['fills_with_real_asset_date_and_units_checked'] += 1
    m = metrics(ss)
    for out_key, formula_key in [('annualized_return','annualizedReturn'),('max_drawdown','maxDrawdown'),('sharpe_rf0','sharpeRF0')]:
        close(account[out_key], m[formula_key])
    counts['metric_groups'] += 1
    assert [s for s in ss if day(s['date']) in evidence['common_dates']] == row['dailyStates']
    for name, saved in row['slices'].items():
        sliced = [s for s in row['dailyStates'] if saved['start'] <= s['date'] <= saved['end']]
        assert len(sliced) == saved['pointCount']
        actual = metrics(sliced)
        for key, val in actual.items(): close(val, saved[key])
        counts['metric_groups'] += 1

common = sorted(set.intersection(*native_dates))
assert [day(d) for d in common] == evidence['common_dates']
assert len(common) == 5595 and day(common[0]) == '2002-09-18' and day(common[-1]) == '2026-09-30'
old = read(HERE.parent/'single-indicator-gold-nasdaq-2026-10-08/run/result.json')
parity = []
for row in rows[:6]:
    previous = next(r for r in old if r['id'] == row['id'])
    assert [s['date'] for s in row['dailyStates']] == [s['date'] for s in previous['dailyStates']]
    ratios = [a['portfolioValue']/b['portfolioValue'] for a,b in zip(row['dailyStates'], previous['dailyStates'])]
    fraction_error = 0.0
    target_error = 0.0
    target_nonidentical_states = 0
    for a,b in zip(row['dailyStates'], previous['dailyStates']):
        target_nonidentical_states += a['targetWeights'] != b['targetWeights']
        for k in set(a['targetWeights']) | set(b['targetWeights']):
            target_error = max(target_error,abs(a['targetWeights'].get(k,0)-b['targetWeights'].get(k,0)))
        for k in set(a['holdingsBySymbol']) | set(b['holdingsBySymbol']):
            delta = abs(a['holdingsBySymbol'].get(k,0)/a['portfolioValue'] - b['holdingsBySymbol'].get(k,0)/b['portfolioValue'])
            fraction_error = max(delta, fraction_error)
        fraction_error = max(fraction_error, abs(a['cash']/a['portfolioValue']-b['cash']/b['portfolioValue']))
    assert fraction_error < 1e-12 and target_error < 1e-12
    for name, m in row['slices'].items():
        for k in ['annualizedReturn', 'maxDrawdown', 'sharpeRF0']: close(m[k], previous['slices'][name][k])
    key = lambda t: (t['date'],t['symbol'],t['action'])
    added = collections.Counter(map(key,row['trades'])) - collections.Counter(map(key,previous['trades']))
    removed = collections.Counter(map(key,previous['trades'])) - collections.Counter(map(key,row['trades']))
    extra = [t for t in row['trades'] if key(t) in added]
    assert not removed and all(t['cashAmount'] < 1e-8 for t in extra)
    parity.append({'id':row['id'],'raw_byte_identity':row==previous,
                   'target_weights_exact_identity':target_nonidentical_states==0,
                   'target_weights_nonidentical_states':target_nonidentical_states,'max_target_weight_delta':target_error,
                   'numeric_comparison_tolerance':1e-12,
                   'normalized_nav_ratio_min':min(ratios),'normalized_nav_ratio_max':max(ratios),
                   'max_cash_or_holding_fraction_delta':fraction_error,
                   'primary_full_metric_max_delta':max(abs(row['slices']['full'][k]-previous['slices']['full'][k]) for k in ['annualizedReturn','maxDrawdown','sharpeRF0']),
                   'prior_fill_count':len(previous['trades']),'new_fill_count':len(row['trades']),
                   'extra_dust_fills':extra,'exact_fill_identity_claimed':False})

audit = {'status':'PASS_SAVED_ACCOUNTING_METRICS_AND_ASSET_QUOTE_DATES',
         'audited_at':datetime.now(timezone.utc).isoformat(),'counts':dict(counts),
         'curated_common_path_readback':parity,'new_capital_replay_in_audit':False,
         'not_certified':['QUAL comparator or complete frontier','macro historical publication-vintage reconstruction',
                          'economic target regeneration audit for complex controls','complete settlement intent reconstruction',
                          'tradable funded ETF/gold total return','independent OOS or formal G0-G6']}
(HERE/'SAVED_AUDIT.json').write_text(json.dumps(audit,ensure_ascii=False,indent=2)+'\n')
summary_rows = [{'id':r['id'],'tier':next(x['tier'] for x in contract['catalogue'] if x['id']==r['id']),
                 'slices':r['slices'],'whole_native_trade_count':len(r['trades']),
                 'native_start':day(read(HERE/'run/accounts'/r['id']/'result.json')['daily_states'][0]['date'])}
                for r in rows]
best = max(summary_rows, key=lambda r:r['slices']['full']['sharpeRF0'])
best_basic = max((r for r in summary_rows if r['tier']=='basic'),key=lambda r:r['slices']['full']['sharpeRF0'])
summary = {'status':'POSTHOC_BENCHMARK_SCOPE_COMPLETED_QUAL_PENDING','completed_at':evidence['completed_at'],
           'new_candidate_count':0,'replayed_comparator_count':19,'catalogue_count':23,
           'common_start':evidence['common_start'],'common_end':evidence['common_end'],'common_point_count':len(common),
           'primary_metric':'App full common daily NAV Sharpe Rf=0','rows':summary_rows,
           'highest_replayed_id':best['id'],'highest_replayed_sharpe_rf0':best['slices']['full']['sharpeRF0'],
           'highest_basic_id':best_basic['id'],'highest_basic_sharpe_rf0':best_basic['slices']['full']['sharpeRF0'],
           'excluded_cash_constraint_ids':[r['id'] for r in contract['catalogue'] if r['status'].startswith('EXCLUDED')],
           'pending_ids':[r['id'] for r in contract['catalogue'] if r['status'].startswith('PENDING')],
           'complete_frontier_certified':False,'objective_complete':False,
           'conclusion':'13 existing basic defaults do not exceed the six-curated maximum on the exact 5595-date native-price-proxy common history. QUAL remains pending, three money-fund experimental policies violate this research cash constraint. No new single-indicator winner or completed goal.'}
(HERE/'SUMMARY.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'status':audit['status'],'counts':audit['counts'],'best_replayed':best['id'],'best_sharpe':summary['highest_replayed_sharpe_rf0'],'basic_best_sharpe':summary['highest_basic_sharpe_rf0']}))
