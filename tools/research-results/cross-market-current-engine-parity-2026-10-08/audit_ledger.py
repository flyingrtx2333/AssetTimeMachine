"""Independent signal/quote and saved capital-ledger readback, not a backtester."""
import bisect
import collections
import gzip
import hashlib
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
freeze = json.loads((HERE/'TECHNICAL_FREEZE.json').read_text())
inp = json.loads(gzip.decompress((HERE/'prices.json.gz').read_bytes()))
def read_run(name):
    p = HERE/'run'/name
    return p.read_bytes() if p.exists() else gzip.decompress(p.with_suffix(p.suffix+'.gz').read_bytes())


result_raw = read_run('result.json')
rows = json.loads(result_raw)
features = json.loads(read_run('features.json'))
targets = json.loads(read_run('desired-targets.json'))
evidence = json.loads((HERE/'run/evidence.json').read_text())
assert hashlib.sha256(result_raw).hexdigest() == evidence['result_sha256']
assert evidence['source_commit'] == freeze['app_commit']
assert evidence['data_sha256'] == freeze['input_unpacked_sha256']
assert evidence['binary_sha256'] == freeze['binary_sha256']
bars = inp['series'][0]['bars']; days = [b['date'] for b in bars]

history = json.loads(gzip.decompress((HERE/'history.json.gz').read_bytes()))
fx = next(s for s in history['series'] if s['symbol'] == 'usd_per_cny')
rates = json.loads((HERE.parent/'industry-allocation-counterfactual-2026-10-06/CASH_RATES.json').read_text())


def stamp(value):
    return datetime.fromisoformat(value.replace('Z','+00:00'))


def session(value):
    return (stamp(value)+timedelta(hours=8)).date().isoformat()


def near(actual, expected):
    assert abs(actual-expected) <= max(1e-8,abs(expected)*1e-12), (actual,expected)


def price(day, field):
    i = bisect.bisect_left(days,day)
    j = bisect.bisect_left(fx['dates'],day)-1
    assert days[i] == day and j >= 0
    assert 0 < (datetime.fromisoformat(day)-datetime.fromisoformat(fx['dates'][j])).days <= 14
    return bars[i][field]/fx['prices'][j]


def accrue(a,b):
    cursor,end = stamp(a).date(),stamp(b).date(); factor = 1
    while cursor < end:
        rate = [r['annual_rate'] for r in rates if r['date'] <= cursor.isoformat()][-1]
        factor *= 1+rate/365.25
        cursor += timedelta(days=1)
    return factor


# Independently reconstruct rolling extreme features and waiting state from frozen quotes.
closes = {s['symbol']:[b['adjustedClose'] for b in s['bars']] for s in inp['series']}
returns = {}
for symbol, values in closes.items():
    returns[symbol] = [None]*65 + [values[j]/(sum(values[j-k] for k in range(55,66))/11)-1 for j in range(65,len(days))]
keys = ['XLI','DBB','IGE','SHY','negative_UUP','negative_GLD_minus_SLV','negative_XLU_minus_XLI','negative_FXF_minus_FXA']
columns = [returns[k] for k in keys[:4]]
columns += [[-v if v is not None else None for v in returns['UUP']]]
for safe,risk in [('GLD','SLV'),('XLU','XLI'),('FXF','FXA')]:
    columns.append([-(a-b) if a is not None else None for a,b in zip(returns[safe],returns[risk])])
in_market = True; wait = 15; count = 0; last_out = 0; previous_weight = 0
max_feature_error = 0; max_threshold_error = 0; triggers = collections.Counter()
for i, f in enumerate(features):
    assert f.get('signalDate') == (days[i-1] if i else None)
    if i < 252:
        assert not f['eligible'] and f['weight'] == 0 and not f['changed']
        continue
    assert f['eligible'] and f['signalDate'] < days[i]
    latest = [v[i-1] for v in columns]
    thresholds = []
    for column in columns:
        values = sorted(column[i-252+65:i]); assert len(values)==187
        rank = (len(values)-1)*.01
        lower = int(rank); fraction = rank-lower
        thresholds.append(values[lower]+fraction*(values[lower+1]-values[lower]))
    extreme = [key for key,a,b in zip(keys,latest,thresholds) if a<b]
    flip = any(returns[a][i-1]>0 and returns[b][i-1]<0 and returns[b][i-2]>0 for a,b in [('GLD','SLV'),('XLU','XLI'),('FXF','FXA')])
    wait = int(max(wait*.5,15*(15 if flip else 1)))
    if extreme: in_market=False; last_out=count
    if count>=last_out+min(60,wait): in_market=True
    weight = int(in_market)
    assert f['extremes']==extreme and f['weight']==weight and f['changed']==(weight!=previous_weight)
    assert (f['waitVariable'],f['waitDays'],f['dayCount'],f['outDay'])==(wait,min(60,wait),count,last_out)
    for a,b in zip(f['current'],latest):
        assert abs(a-b)<=1e-12;max_feature_error=max(max_feature_error,abs(a-b))
    for a,b in zip(f['thresholds'],thresholds):
        assert abs(a-b)<=1e-12;max_threshold_error=max(max_threshold_error,abs(a-b))
    triggers.update(extreme);previous_weight=weight;count+=1
first = days.index('2008-03-03'); audits = []
for mode,row in enumerate(rows):
    states = row['dailyStates']; assert len(states) == len(days)-first+1
    assert [session(s['date']) for s in states[1:]] == days[first:]
    fills = collections.defaultdict(list)
    for trade in row['trades']: fills[trade['date']].append(trade)
    units = 0.0; max_cash_error = 0.0; missing = 0; outside_changes = 0
    for n,state in enumerate(states[1:]):
        day = session(state['date']); i = first+n
        weight = features[i]['weight'] if mode==0 else 1-features[i]['weight'] if mode==1 else int(mode==2)
        desired = {'QQQ':1} if weight else {}
        assert targets[row['id']][n] == desired == state['targetWeights']
        previous = states[n]
        cash = previous['cash'] if n == 0 else previous['cash']*accrue(previous['date'],state['date'])
        cash_before_fills = cash; spent = 0
        changed = n == 0 or (mode < 2 and features[i]['changed'])
        for trade in fills[state['date']]:
            assert trade['symbol'] == 'QQQ'
            near(trade['price'],price(day,'open'))
            buy = trade['action'] == 'buy'; assert buy or trade['action'] == 'sell'
            assert buy == bool(weight)
            if not changed: outside_changes += 1
            amount = trade['units']*trade['price']/(1-.00025) if buy else trade['units']*trade['price']*(1-.00025)
            near(trade['cashAmount'],amount)
            units += trade['units'] if buy else -trade['units']
            cash += -amount if buy else amount
            if buy: spent += amount
        assert spent <= cash_before_fills+1e-8 and units >= -1e-8
        near(cash,state['cash']); max_cash_error = max(max_cash_error,abs(cash-state['cash']))
        held = max(units,0)*price(day,'close')
        near(held,state['holdingsBySymbol'].get('QQQ',0))
        near(state['cash']+sum(state['holdingsBySymbol'].values()),state['portfolioValue'])
        assert state['cash'] >= -1e-8 and held/state['portfolioValue'] <= 1+1e-12
        if weight and held <= .0001: missing += 1
        if not weight: near(held,0)
    assert missing == outside_changes == 0
    audits.append(dict(id=row['id'],states_checked=len(states)-1,fills_checked=len(row['trades']),
        cash_reconstruction_max_error=max_cash_error,desired_accepted_mismatches=0,
        missing_target_member_sessions=missing,fills_outside_state_changes=outside_changes,
        status='PASS_SAVED_LEDGER_AND_PRIOR_DAY_STRESS_SIGNAL'))

audit = dict(audited_at=datetime.now(timezone.utc).isoformat(),result_sha256=evidence['result_sha256'],
    features_checked=len(days),extreme_trigger_counts=dict(triggers),max_feature_error=max_feature_error,max_threshold_error=max_threshold_error,rows=audits,formal_validation=False,
    scope='Saved stress signal/target/quote/fees/cash/units audit only; original quote vintages uncertified.',
    cash_control_metric_warning='First seed interval receives no cash interest; near-zero excess-return variance makes cash-control Sharpe uninformative. Keep raw output, do not rank or publish cash Sharpe.',
    timestamp_note='ISO dates are shared-engine China-midnight session labels, not physical New York execution timestamps.')
(HERE/'EXECUTION_AUDIT.json').write_text(json.dumps(audit,indent=2)+'\n')

print(json.dumps({"accounts":len(audits),"states":sum(a["states_checked"] for a in audits),"fills":sum(a["fills_checked"] for a in audits),"features":len(days),"status":"PASS_SAVED_LEDGER_AND_PRIOR_DAY_STRESS_SIGNAL"}))
