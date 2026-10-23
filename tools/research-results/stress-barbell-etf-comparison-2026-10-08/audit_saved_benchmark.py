"""Audit saved proposals, accepted targets, fills, entitlements and metrics.

This reads a completed shared Swift run; it never generates a capital path.
"""
from pathlib import Path
from datetime import datetime, timezone, timedelta
import bisect, collections, gzip, hashlib, json, math, statistics
HERE=Path(__file__).resolve().parent
def raw(p): return p.read_bytes() if p.exists() else gzip.decompress(p.with_suffix(p.suffix+'.gz').read_bytes())
def read(p): return json.loads(raw(p))
def sha(b): return hashlib.sha256(b).hexdigest()
def stamp(s): return datetime.fromisoformat(s.replace('Z','+00:00'))
def session(s): return (stamp(s)+timedelta(hours=8)).date().isoformat()
def near(a,b): assert abs(a-b)<=max(1e-8,abs(b)*3e-12),(a,b)
d=read(HERE/'DECLARATION.json');f=read(HERE/'TECHNICAL_FREEZE.json')
inp=read(HERE/'prices.json');history=read(HERE/'history.json');cash_input=read(HERE/'cash.json')
rows=read(HERE/'run/result.json');claims=read(HERE/'run/entitlements.json')
decisions=read(HERE/'run/decisions.json');completions=read(HERE/'run/completions.json');evidence=read(HERE/'run/evidence.json')
assert evidence['source_commit']==f['app_commit'] and evidence['binary_sha256']==f['binary_sha256']
assert evidence['result_sha256']==sha(raw(HERE/'run/result.json'))
for key,path in [('input','prices'),('history','history'),('cash','cash')]: assert evidence[key+'_sha256']==d[key+'_sha256']==sha(raw(HERE/(path+'.json')))
assert len(rows)==2 and evidence['parameter_searches']==0 and evidence['new_economic_candidates']==0
bars={s['symbol']:s['bars'] for s in inp['series']};days=[b['date'] for b in bars['GLD']];first=days.index('2008-03-03')
fx=next(s for s in history['series'] if s['symbol']=='usd_per_cny')
rates=read(HERE.parent/'industry-allocation-counterfactual-2026-10-06/CASH_RATES.json')
candidate_rows=read(HERE.parent/'cross-market-issuer-cash-replay-2026-10-08/run/result.json')
def conversion(day):
 i=bisect.bisect_left(fx['dates'],day)-1;assert i>=0 and fx['dates'][i]<day
 return 1/fx['prices'][i]
def price(symbol,day,field):
 i=bisect.bisect_left(days,day);assert days[i]==day
 return bars[symbol][i][field]*conversion(day)
closes={symbol:[b['close']*conversion(b['date']) for b in values] for symbol,values in bars.items()}
def audit_proposal(index):
 signal=index-1;target={}
 for symbol,weight,weak,neutral in [('GLD',.55,.15,.65),('QQQ',.45,.10,.60)]:
  values=closes[symbol];p=values[signal];ma=sum(values[signal-199:signal+1])/200
  strong=p>ma and p/values[signal-126]-1>0
  is_weak=p<ma and p/values[signal-252]-1<0
  target[symbol]=weight*(1 if strong else weak if is_weak else neutral)
 return target
def accrue(a,b):
 cursor,end=stamp(a).date(),stamp(b).date();factor=1
 while cursor<end:
  rate=[r['annual_rate'] for r in rates if r['date']<=cursor.isoformat()][-1]
  factor*=1+rate/365.25;cursor+=timedelta(days=1)
 return factor
events={r['ex_date']:r for r in cash_input['events']};audits=[];comparisons=[]
for row in rows:
 taxID=row['id'].split(':')[1];tax=0 if taxID=='gross' else .3;assert taxID in ['gross','withhold30']
 candidate=next(r for r in candidate_rows if r['id']=='cross-market-extreme-qqq-cash:'+taxID)
 states=row['dailyStates'];trace=decisions[row['id']];completed=completions[row['id']]
 assert len(states)==len(days)-first+1 and len(trace)==len(states)-1
 assert [s['date'] for s in states]==[s['date'] for s in candidate['dailyStates']]
 fills=collections.defaultdict(list)
 for fill in row['trades']:fills[fill['date']].append(fill)
 units={'GLD':0.,'QQQ':0.};expected_claims=[];last_completed=-(2**62);accepted={};pending=False;missing=[];max_delay=0;pending_start=None
 for n,state in enumerate(states[1:]):
  day=days[first+n];index=first+n;previous=states[n];decision=trace[n]
  assert session(state['date'])==day and decision['date']==state['date']
  assert decision['index']==index and session(decision['signalDate'])==days[index-1]
  expected=audit_proposal(index);assert decision['proposed'].keys()==expected.keys()
  for symbol,w in expected.items():near(decision['proposed'][symbol],w)
  due=index==first or index-last_completed>=63;assert decision['shouldRebalance']==due
  if due:
   accepted=decision['proposed'];pending=True
   if pending_start is None:pending_start=index
  assert state['targetWeights']==accepted and sum(accepted.values())<=1+1e-12
  if day in events and units['QQQ']>0:
   event=events[day];expected_claims.append({'event':event,'units':units['QQQ'],'net':units['QQQ']*event['amount_usd']*(1-tax),'paid':False,'paid_on':None,'paid_amount':None})
  cash=previous['cash'] if n==0 else previous['cash']*accrue(previous['date'],state['date']);settled=cash;spent=0
  day_fills=fills[state['date']]
  assert not day_fills or pending
  for fill in day_fills:
   symbol=fill['symbol'];assert symbol in units and fill['units']>0
   near(fill['price'],price(symbol,day,'open'))
   buy=fill['action']=='buy';assert buy or fill['action']=='sell'
   amount=fill['units']*fill['price']/(1-.00025) if buy else fill['units']*fill['price']*(1-.00025)
   near(fill['cashAmount'],amount);units[symbol]+=fill['units'] if buy else -fill['units'];cash+=-amount if buy else amount
   if buy:spent+=amount
  assert min(units.values())>=-1e-8 and spent<=settled+1e-8
  if index in completed:
   assert pending;last_completed=index;pending=False
   max_delay=max(max_delay,index-pending_start);pending_start=None
  for claim in expected_claims:
   if not claim['paid'] and claim['event']['payment_date']<=day:
    claim['paid']=True;claim['paid_on']=state['date'];claim['paid_amount']=claim['net']*conversion(day);cash+=claim['paid_amount']
  receivable=sum(c['net']*conversion(day) for c in expected_claims if not c['paid'])
  holdings={symbol:max(held,0)*price(symbol,day,'close') for symbol,held in units.items()}
  near(cash,state['cash']);assert state['cash']>=-1e-8
  near(receivable,state.get('distributionReceivable',0))
  for symbol,held in holdings.items():near(held,state['holdingsBySymbol'].get(symbol,0))
  near(cash+sum(holdings.values())+receivable,state['portfolioValue'])
  assert sum(holdings.values())/state['portfolioValue']<=1+1e-12
  absent=[symbol for symbol,w in accepted.items() if w>0 and holdings[symbol]<=.0001]
  if absent:missing.append({'date':day,'symbols':absent,'pending':pending})
 assert set(completed).issubset(set(range(first,len(days)))) and len(set(completed))==len(completed)
 assert len(expected_claims)==len(claims[row['id']])
 for claim,actual in zip(expected_claims,claims[row['id']]):
  event=claim['event'];saved=actual['distribution'];assert saved['symbol']=='QQQ' and saved['currencyCode']=='USD'
  assert session(saved['exDate'])==event['ex_date'] and session(saved['paymentDate'])==event['payment_date']
  near(saved['amountPerUnit'],event['amount_usd']);near(saved['withholdingRate'],tax)
  near(actual['eligibleUnits'],claim['units']);near(actual['netAmountInDistributionCurrency'],claim['net'])
  assert actual.get('paidOn')==claim['paid_on']
  if claim['paid']:near(actual['paidAmountInBaseCurrency'],claim['paid_amount'])
  else:assert actual.get('paidAmountInBaseCurrency') is None
 for name,metric in row['slices'].items():
  cm=candidate['slices'][name];assert (metric['start'],metric['end'],metric['pointCount'])==(cm['start'],cm['end'],cm['pointCount'])
  window=[s for s in states if stamp(metric['start'])<=stamp(s['date'])<=stamp(metric['end'])];assert len(window)==metric['pointCount']
  years=(stamp(window[-1]['date'])-stamp(window[0]['date'])).days/365.25
  returns=[b['portfolioValue']/a['portfolioValue']-1 for a,b in zip(window,window[1:])]
  near(metric['annualizedReturn'],(window[-1]['portfolioValue']/window[0]['portfolioValue'])**(1/years)-1)
  peak=window[0]['portfolioValue'];dd=0
  for s in window:peak=max(peak,s['portfolioValue']);dd=max(dd,(peak-s['portfolioValue'])/peak)
  near(metric['maxDrawdown'],dd);near(metric['sharpeRF0'],statistics.mean(returns)/statistics.stdev(returns)*math.sqrt(len(returns)/years))
  excess=[r-(accrue(a['date'],b['date'])-1) for r,a,b in zip(returns,window,window[1:])]
  near(metric['excessSharpeCNYCash'],statistics.mean(excess)/statistics.stdev(excess)*math.sqrt(len(returns)/years))
  comparisons.append({'tax':taxID,'window':name,'candidate':cm,'benchmark':metric,'candidate_sharpe_greater':cm['sharpeRF0']>metric['sharpeRF0']})
 audits.append({'id':row['id'],'states_checked':len(states)-1,'proposals_checked':len(trace),'fills_checked':len(row['trades']),'claims_checked':len(expected_claims),'completed_targets':len(completed),'max_pending_delay_sessions':max_delay,'terminal_pending':pending,'missing_positive_target_holdings':missing,'metric_groups_checked':len(row['slices'])})
result={'status':'PASS_SAVED_PROPOSALS_AND_CASH_LEDGER','audited_at':datetime.now(timezone.utc).isoformat(),'accounts':audits,'comparisons':comparisons,'formal_validation':False,'original_product_frontier_certified':False,'result_sha256':evidence['result_sha256']}
path=HERE/'SAVED_AUDIT.json'
if path.exists():
 old=read(path);old.pop('audited_at');new=dict(result);new.pop('audited_at');assert old==new
else:path.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({'status':result['status'],'states':sum(a['states_checked'] for a in audits),'comparisons':len(comparisons),'missing_holdings':sum(len(a['missing_positive_target_holdings']) for a in audits)}))
