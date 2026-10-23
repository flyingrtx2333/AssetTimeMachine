"""Independent input/schedule and saved cash-ledger audit; no capital generator."""
from pathlib import Path
from datetime import datetime,timezone,timedelta,date
import bisect,collections,gzip,hashlib,json,math,statistics,sys,os
HERE=Path(__file__).resolve().parent
def raw(p):return p.read_bytes() if p.exists() else gzip.decompress(p.with_suffix(p.suffix+'.gz').read_bytes())
def read(p):return json.loads(raw(p))
def sha(b):return hashlib.sha256(b).hexdigest()
def stamp(s):return datetime.fromisoformat(s.replace('Z','+00:00'))
def session(s):return (stamp(s)+timedelta(hours=8)).date().isoformat()
def near(a,b):assert abs(a-b)<=max(1e-8,abs(b)*3e-12),(a,b)
def clean(w):return {k:v for k,v in w.items() if v>0}
d=read(HERE/'DECLARATION.json');h=read(HERE/'history.json');curve=read(HERE/'curve.json')['rows']
assert sha(raw(HERE/'history.json'))==d['input_sha256']['history']==read(HERE/'PARENT_MARKET_SOURCE.json')['normalized_sha256']
assert sha(raw(HERE/'curve.json'))==d['input_sha256']['curve']
assert read(HERE/'PARENT_DATA_BLOCKED_RESULT.json')['historical_pnl_computed'] is False
APP=Path(os.environ.get('ASSET_TIME_MACHINE_APP_REPO',HERE.parents[4].parent/'AssetTimeMachine'))
assert (APP/'Sources/AssetTimeMachineResearchSupport/Commands/RecoveredCurveSignals.swift').read_bytes().split(b'\n',1)[1]==(HERE/'PARENT_CurveSignals.swift').read_bytes()
frame=read(HERE/'prepare/frame.json');plans=read(HERE/'prepare/plans.json');signal_audit=read(HERE/'prepare/signal-audit.json')
days=frame['dates'];first=frame['first_index'];last=frame['last_index'];symbols=['gold_cny','nasdaq']
sources={s['symbol']:dict(zip(s['dates'],s['prices'])) for s in h['series']}
expected_days=sorted(set(sources['gold_cny'])&set(sources['nasdaq_composite'])&set(sources['usd_per_cny']))
expected_days=[day for day in expected_days if date.fromisoformat(day).weekday()<5]
assert days==expected_days
assert first==bisect.bisect_left(days,'2008-01-01') and last==len(days)-1 and days[last]=='2026-09-04'
for i,day in enumerate(days):
 near(frame['prices']['gold_cny'][i],sources['gold_cny'][day])
 near(frame['prices']['nasdaq'][i],sources['nasdaq_composite'][day]/sources['usd_per_cny'][day])
 assert all(frame['observed'][s][i] for s in symbols)
cdays=[r['date'] for r in curve]
def known(signal):
 i=bisect.bisect_left(cdays,signal)-1
 if i<0:return None
 return curve[i] if (date.fromisoformat(signal)-date.fromisoformat(cdays[i])).days<=7 else None
def weights(r,v):
 if v=='nasdaq':return {'nasdaq':1}
 if r is None:return {}
 stress=r['vix']>r['vix3m']
 if v=='defensive_gold':return {'gold_cny' if stress else 'nasdaq':1}
 if v=='panic_premium':return {'nasdaq':1} if stress else {}
 if v=='defensive_cash':return {} if stress else {'nasdaq':1}
 if v=='reverse_rotation':return {'nasdaq' if stress else 'gold_cny':1}
 raise AssertionError(v)
for v,records in signal_audit.items():
 assert len(records)==last-first+1;expected_orders=[];previous=None
 for index,record in zip(range(first,last+1),records):
  day=days[index];r=known(day);w=weights(r,v)
  assert record['signal_date']==day and record['source_date']==(r['date'] if r else '') and clean(record['weights'])==w
  assert record['state']==('stress' if r['vix']>r['vix3m'] else 'normal') if r else record['state']=='missing_or_stale'
  if r:
   assert r['date']<day;near(record['vix'],r['vix']);near(record['vix3m'],r['vix3m'])
  if previous!=w:expected_orders.append({'signal_index':index,'signal_date':day,'weights':record['weights']});previous=w
 assert plans[v]==expected_orders
prep_result={'status':'PASS_RAW_NATIVE_FRAME_AND_ORIGINAL_SIGNALS','audited_at':datetime.now(timezone.utc).isoformat(),'frame_dates':len(days),'funded_dates':last-first+1,'signal_audits_checked':sum(len(x) for x in signal_audit.values()),'cash_paths_computed':False,'source_date_isolation':'jointCboeDate < AppSignalDate < AppExecutionDate','new_economic_mechanisms':0}
def save_result(path,result):
 if path.exists():
  old=read(path);old.pop('audited_at');new=dict(result);new.pop('audited_at');assert old==new
 else:path.write_text(json.dumps(result,indent=2)+'\n')
save_result(HERE/'PREPARE_AUDIT.json',prep_result)
if '--prepare-only' in sys.argv:
 print(json.dumps(prep_result));raise SystemExit(0)
f=read(HERE/'TECHNICAL_FREEZE.json');rows=read(HERE/'run/result.json');decisions=read(HERE/'run/decisions.json');completed=read(HERE/'run/completions.json');e=read(HERE/'run/evidence.json')
assert len(rows)==12 and e['source_commit']==f['app_commit'] and e['binary_sha256']==f['binary_sha256']
assert e['result_sha256']==sha(raw(HERE/'run/result.json')) and e['parameter_searches']==0 and e['new_economic_mechanisms']==0
for key,path in [('history','history.json'),('curve','curve.json')]:assert e[key+'_sha256']==d['input_sha256'][key]==sha(raw(HERE/path))
for key,path in [('frame','frame.json'),('plan','plans.json')]:assert e[key+'_sha256']==sha(raw(HERE/'prepare'/path))
rates=read(HERE.parent/'industry-allocation-counterfactual-2026-10-06/CASH_RATES.json')
def accrue(a,b):
 cursor,end=stamp(a).date(),stamp(b).date();factor=1
 while cursor<end:
  rate=[r['annual_rate'] for r in rates if r['date']<=cursor.isoformat()][-1]
  factor*=1+rate/365.25;cursor+=timedelta(days=1)
 return factor
audits=[]
for row in rows:
 v,cost=row['id'].split(':');slip=float(cost.removeprefix('slip'))/100;assert slip in [0,.0005]
 states=row['dailyStates'];assert len(states)==last-first+2
 assert session(states[0]['date'])=='2008-01-01' and [session(s['date']) for s in states[1:]]==days[first:last+1]
 fills=collections.defaultdict(list)
 for fill in row['trades']:fills[fill['date']].append(fill)
 units={s:0. for s in symbols};missing_episodes=[];episode=None;metric_groups=0
 if v!='product':
  trace=decisions[row['id']];orders=plans[v];order_indices=[x['signal_index'] for x in orders];changes=set(order_indices)
  assert len(trace)==len(states)-1
 for n,state in enumerate(states[1:]):
  i=first+n;previous=states[n];cash=previous['cash'] if n==0 else previous['cash']*accrue(previous['date'],state['date']);settled=cash;spent=0
  if v!='product':
   signal=i-1;k=bisect.bisect_right(order_indices,signal)-1;desired=clean(orders[k]['weights']) if k>=0 else {}
   t=trace[n];assert t['index']==i and t['date']==state['date'] and session(t['signalDate'])==days[signal]
   assert t['desired']==desired==state['targetWeights'] and t['submitted']==(signal in changes)
  for fill in fills[state['date']]:
   symbol=fill['symbol'];buy=fill['action']=='buy';assert symbol in symbols and (buy or fill['action']=='sell')
   assert frame['observed'][symbol][i] and fill['units']>0
   near(fill['price'],frame['prices'][symbol][i]*(1+slip if buy else 1-slip))
   amount=fill['units']*fill['price']/(1-.00025) if buy else fill['units']*fill['price']*(1-.00025)
   near(amount,fill['cashAmount']);cash+=-amount if buy else amount;units[symbol]+=fill['units'] if buy else -fill['units']
   if buy:spent+=amount
   if v!='product':assert desired.get(symbol,0)>0 if buy else True
  assert min(units.values())>=-1e-8 and spent<=settled+1e-8 and cash>=-1e-8
  held={s:max(units[s],0)*frame['prices'][s][i] for s in symbols}
  near(cash,state['cash'])
  for s,amount in held.items():near(amount,state['holdingsBySymbol'].get(s,0))
  near(cash+sum(held.values()),state['portfolioValue']);assert sum(held.values())<=state['portfolioValue']+1e-8 and sum(state['targetWeights'].values())<=1+1e-12
  absent=[s for s,w in state['targetWeights'].items() if w>0 and held[s]<=.0001]
  if absent:
   if episode is None or episode['symbols']!=absent:
    if episode is not None:missing_episodes.append(episode)
    episode={'start':days[i],'end':days[i],'symbols':absent,'opportunities':0}
   episode['end']=days[i];episode['opportunities']+=1
  elif episode is not None:missing_episodes.append(episode);episode=None
 if episode is not None:missing_episodes.append(episode)
 for metric in row['slices'].values():
  window=[s for s in states if stamp(metric['start'])<=stamp(s['date'])<=stamp(metric['end'])];assert len(window)==metric['pointCount']
  years=(stamp(window[-1]['date'])-stamp(window[0]['date'])).days/365.25
  returns=[b['portfolioValue']/a['portfolioValue']-1 for a,b in zip(window,window[1:])]
  near(metric['annualizedReturn'],(window[-1]['portfolioValue']/window[0]['portfolioValue'])**(1/years)-1)
  peak=window[0]['portfolioValue'];dd=0
  for s in window:peak=max(peak,s['portfolioValue']);dd=max(dd,(peak-s['portfolioValue'])/peak)
  near(metric['maxDrawdown'],dd);near(metric['sharpeRF0'],statistics.mean(returns)/statistics.stdev(returns)*math.sqrt(len(returns)/years))
  excess=[r-(accrue(a['date'],b['date'])-1) for r,a,b in zip(returns,window,window[1:])]
  near(metric['excessSharpeCNYCash'],statistics.mean(excess)/statistics.stdev(excess)*math.sqrt(len(returns)/years));metric_groups+=1
 audits.append({'id':row['id'],'states_checked':len(states)-1,'fills_checked':len(row['trades']),'metric_groups':metric_groups,'accepted_target_mismatches':0 if v!='product' else None,'missing_holdings_episodes':missing_episodes,'longest_absent_target_opportunities':max((x['opportunities'] for x in missing_episodes),default=0)})
result={'status':'PASS_SAVED_CASH_FILLS_METRICS_AND_TARGET_READBACK','audited_at':datetime.now(timezone.utc).isoformat(),'accounts':audits,'formal_validation':False,'complete_original_product_frontier_certified':False,'result_sha256':e['result_sha256'],'extended_buy_delay_review_required':any(x['longest_absent_target_opportunities']>2 for x in audits)}
save_result(HERE/'SAVED_AUDIT.json',result)
print(json.dumps({'status':result['status'],'accounts':12,'states':sum(a['states_checked'] for a in audits),'fills':sum(a['fills_checked'] for a in audits),'metric_groups':sum(a['metric_groups'] for a in audits),'max_target_absence':max(a['longest_absent_target_opportunities'] for a in audits)}))
