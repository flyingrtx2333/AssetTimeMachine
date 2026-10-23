"""Independent reconstruction of saved cash facts, fills, claims and metrics.

No new strategy simulation or parameter search.
"""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import bisect, collections, gzip, hashlib, json, math, statistics
HERE = Path(__file__).resolve().parent
def raw(p): return p.read_bytes() if p.exists() else gzip.decompress(p.with_suffix(p.suffix + '.gz').read_bytes())
def read(p): return json.loads(raw(p))
def sha(b): return hashlib.sha256(b).hexdigest()
def stamp(s): return datetime.fromisoformat(s.replace('Z','+00:00'))
def session(s): return (stamp(s) + timedelta(hours=8)).date().isoformat()
def near(a,b): assert abs(a-b) <= max(1e-8,abs(b)*2e-12), (a,b)
freeze = read(HERE/'TECHNICAL_FREEZE.json'); declaration = read(HERE/'DECLARATION.json')
inp = read(HERE/'prices.json'); history = read(HERE/'history.json'); cash_input = read(HERE/'cash.json')
rows = read(HERE/'run/result.json'); features = read(HERE/'run/features.json'); targets = read(HERE/'run/desired-targets.json')
claims = read(HERE/'run/entitlements.json'); evidence = read(HERE/'run/evidence.json')
old = HERE.parent/'cross-market-current-engine-parity-2026-10-08'
assert raw(HERE/'run/features.json') == raw(old/'run/features.json')
old_targets = read(old/'run/desired-targets.json')
assert evidence['source_commit'] == freeze['app_commit'] and evidence['binary_sha256'] == freeze['binary_sha256']
assert evidence['result_sha256'] == sha(raw(HERE/'run/result.json'))
assert evidence['data_sha256'] == declaration['inputs']['prices']['raw_sha256']
assert evidence['history_sha256'] == declaration['inputs']['history']['raw_sha256']
assert evidence['cash_sha256'] == declaration['cash_input_sha256']
assert len(rows) == 8 and evidence['parameter_search_count'] == 0
bars = inp['series'][0]['bars']; days = [b['date'] for b in bars]; first = days.index('2008-03-03')
fx = next(s for s in history['series'] if s['symbol']=='usd_per_cny')
rates = read(HERE.parent/'industry-allocation-counterfactual-2026-10-06/CASH_RATES.json')
def conversion(day):
    i = bisect.bisect_left(fx['dates'],day)-1; assert i >= 0 and fx['dates'][i] < day
    return 1/fx['prices'][i]
def price(day,field):
    i = bisect.bisect_left(days,day); assert days[i] == day
    return bars[i][field]*conversion(day)
def accrue(a,b):
    cursor,end = stamp(a).date(),stamp(b).date(); factor = 1
    while cursor < end:
        rate = [r['annual_rate'] for r in rates if r['date'] <= cursor.isoformat()][-1]
        factor *= 1+rate/365.25; cursor += timedelta(days=1)
    return factor
events = {r['ex_date']:r for r in cash_input['events']}; account_audits = []
for row in rows:
    base,taxID = row['id'].split(':'); tax = 0 if taxID=='gross' else .3
    assert taxID in ['gross','withhold30'] and targets[row['id']] == old_targets[base]
    states = row['dailyStates']; assert len(states) == len(days)-first+1
    assert [session(s['date']) for s in states[1:]] == days[first:]
    fills = collections.defaultdict(list)
    for fill in row['trades']: fills[fill['date']].append(fill)
    units = 0.0; expected_claims = []; metric_groups = 0; missing_target = 0
    for n,state in enumerate(states[1:]):
        day = days[first+n]; previous = states[n]; desired = targets[row['id']][n]
        assert state['targetWeights'] == desired and state['cash'] >= -1e-8
        if day in events and units > 0:
            event = events[day]
            expected_claims.append({'event':event,'units':units,'net':units*event['amount_usd']*(1-tax),'paid':False,'paid_on':None,'paid_amount':None})
        cash = previous['cash'] if n==0 else previous['cash']*accrue(previous['date'],state['date'])
        cash_before_fills = cash; spent = 0
        changed = n==0 or (base in ['cross-market-extreme-qqq-cash','inverse-stress-control'] and features[first+n]['changed'])
        for fill in fills[state['date']]:
            assert changed and fill['symbol']=='QQQ'
            near(fill['price'],price(day,'open'))
            buy = fill['action']=='buy'; assert buy or fill['action']=='sell'
            assert buy == bool(desired)
            amount = fill['units']*fill['price']/(1-.00025) if buy else fill['units']*fill['price']*(1-.00025)
            near(fill['cashAmount'],amount)
            units += fill['units'] if buy else -fill['units']; cash += -amount if buy else amount
            if buy: spent += amount
        assert units >= -1e-8 and spent <= cash_before_fills+1e-8
        for claim in expected_claims:
            if not claim['paid'] and claim['event']['payment_date'] <= day:
                claim['paid']=True; claim['paid_on']=state['date']; claim['paid_amount']=claim['net']*conversion(day); cash += claim['paid_amount']
        receivable = sum(c['net']*conversion(day) for c in expected_claims if not c['paid'])
        held = max(units,0)*price(day,'close')
        near(cash,state['cash']); near(receivable,state.get('distributionReceivable',0)); near(held,state['holdingsBySymbol'].get('QQQ',0))
        near(cash+held+receivable,state['portfolioValue']); assert held/state['portfolioValue'] <= 1+1e-12
        if desired and held <= .0001: missing_target += 1
        if not desired: near(held,0)
    assert missing_target == 0 and len(claims[row['id']]) == len(expected_claims)
    for claim,actual in zip(expected_claims,claims[row['id']]):
        event=claim['event']; saved=actual['distribution']
        assert saved['id']=='QQQ:'+event['ex_date'] and saved['symbol']=='QQQ' and saved['currencyCode']=='USD'
        assert session(saved['exDate'])==event['ex_date'] and session(saved['paymentDate'])==event['payment_date']
        near(saved['amountPerUnit'],event['amount_usd']); near(saved['withholdingRate'],tax)
        near(actual['eligibleUnits'],claim['units']); near(actual['netAmountInDistributionCurrency'],claim['net'])
        assert actual.get('paidOn')==claim['paid_on']
        if claim['paid']: near(actual['paidAmountInBaseCurrency'],claim['paid_amount'])
        else: assert actual.get('paidAmountInBaseCurrency') is None
    for metric in row['slices'].values():
        window=[s for s in states if stamp(metric['start'])<=stamp(s['date'])<=stamp(metric['end'])]
        assert len(window)==metric['pointCount']
        years=(stamp(window[-1]['date'])-stamp(window[0]['date'])).days/365.25
        returns=[b['portfolioValue']/a['portfolioValue']-1 for a,b in zip(window,window[1:])]
        near(metric['annualizedReturn'],(window[-1]['portfolioValue']/window[0]['portfolioValue'])**(1/years)-1)
        peak=window[0]['portfolioValue']; dd=0
        for s in window: peak=max(peak,s['portfolioValue']); dd=max(dd,(peak-s['portfolioValue'])/peak)
        near(metric['maxDrawdown'],dd)
        near(metric['sharpeRF0'],statistics.mean(returns)/statistics.stdev(returns)*math.sqrt(len(returns)/years))
        excess=[r-(accrue(a['date'],b['date'])-1) for r,a,b in zip(returns,window,window[1:])]
        # Near-zero cash-control excess variance is not a useful metric.
        if base!='cny-cash-control': near(metric['excessSharpeCNYCash'],statistics.mean(excess)/statistics.stdev(excess)*math.sqrt(len(returns)/years))
        metric_groups+=1
    if base=='cny-cash-control':
        original=next(r for r in read(old/'run/result.json') if r['id']==base)
        for a,b in zip(states,original['dailyStates']):
            for key in ['date','cash','holdingsBySymbol','portfolioValue','targetWeights']: assert a[key]==b[key]
        assert not expected_claims and not row['trades']
    account_audits.append({'id':row['id'],'states_checked':len(states)-1,'fills_checked':len(row['trades']),'entitlements_checked':len(expected_claims),'unpaid_terminal_claims':sum(not c['paid'] for c in expected_claims),'metric_groups_checked':metric_groups,'target_mismatches':0})
result={'status':'PASS_SAVED_CASH_LEDGER_AND_UNCHANGED_SIGNAL_READBACK','audited_at':datetime.now(timezone.utc).isoformat(),'accounts':account_audits,'features_byte_identical_to_original':True,'targets_identical_to_original':True,'zero_cash_control_differences':True,'formal_validation':False,'matched_total_return_superiority_certified':False,'result_sha256':evidence['result_sha256'],'scope':'Saved funded audit only, not independent alpha/PIT/OOS qualification.'}
path=HERE/'CASH_AUDIT.json'
if path.exists():
    a=read(path);a.pop('audited_at');b=dict(result);b.pop('audited_at');assert a==b
else:path.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'status':result['status'],'accounts':len(account_audits),'states':sum(r['states_checked'] for r in account_audits),'claims':sum(r['entitlements_checked'] for r in account_audits),'metric_groups':sum(r['metric_groups_checked'] for r in account_audits)}))
