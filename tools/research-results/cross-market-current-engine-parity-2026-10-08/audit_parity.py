"""Compare two saved Swift outputs; never generate targets/trades/accounts."""
import gzip,hashlib,json,math,datetime
from pathlib import Path
HERE=Path(__file__).resolve().parent;OLD=HERE.parent/'cross-market-extreme-cash-2026-10-08'
sha=lambda b:hashlib.sha256(b).hexdigest()
def raw(base,name):
 p=base/name
 return p.read_bytes() if p.exists() else gzip.decompress(p.with_suffix(p.suffix+'.gz').read_bytes())
freeze=json.loads((HERE/'TECHNICAL_FREEZE.json').read_bytes());spec=json.loads((HERE/'DECLARATION.json').read_bytes());old_f=json.loads((OLD/'TECHNICAL_FREEZE.json').read_bytes())
old_e=json.loads((OLD/'run/evidence.json').read_bytes());new_e=json.loads((HERE/'run/evidence.json').read_bytes())
errors=[];counts={'numbers':0,'scalars':0,'containers':0};max_abs=0.;max_rel=0.
def compare(a,b,path):
 global max_abs,max_rel
 if isinstance(a,dict) and isinstance(b,dict):
  counts['containers']+=1
  aa=dict(a);bb=dict(b)
  if 'distributionReceivable' not in aa and bb.get('distributionReceivable')==0:bb.pop('distributionReceivable')
  if 'distributionReceivable' not in bb and aa.get('distributionReceivable')==0:aa.pop('distributionReceivable')
  if set(aa)!=set(bb):errors.append({'path':path,'kind':'keys','old':sorted(aa),'new':sorted(bb)})
  for key in sorted(set(aa)&set(bb)):compare(aa[key],bb[key],path+'/'+key)
 elif isinstance(a,list) and isinstance(b,list):
  counts['containers']+=1
  if len(a)!=len(b):errors.append({'path':path,'kind':'length','old':len(a),'new':len(b)})
  for i,(x,y) in enumerate(zip(a,b)):compare(x,y,path+'/'+str(i))
 elif isinstance(a,(int,float)) and not isinstance(a,bool) and isinstance(b,(int,float)) and not isinstance(b,bool):
  counts['numbers']+=1;delta=abs(a-b);max_abs=max(max_abs,delta);max_rel=max(max_rel,delta/max(1,abs(a)))
  tolerance=max(1e-12 if '/slices/' in path or path.endswith('/meanExposure') else 1e-8,abs(a)*1e-12)
  if not math.isfinite(a) or not math.isfinite(b) or delta>tolerance:errors.append({'path':path,'kind':'numeric','old':a,'new':b,'tolerance':tolerance})
 else:
  counts['scalars']+=1
  if a!=b:errors.append({'path':path,'kind':'scalar','old':a,'new':b})
inputs=[]
for logical,key in [('prices','data_sha256'),('history','history_sha256')]:
 b=raw(HERE,logical+'.json');assert sha(b)==spec['inputs'][logical]['raw_sha256']==new_e[key]==old_e[key];inputs.append(logical)
assert new_e['source_commit']==freeze['app_commit'] and new_e['binary_sha256']==freeze['binary_sha256']
checks={};byte_equal={}
for logical in ['result.json','features.json','desired-targets.json']:
 old_raw=raw(OLD/'run',logical);new_raw=raw(HERE/'run',logical)
 if logical=='result.json':assert sha(old_raw)==old_e['result_sha256'] and sha(new_raw)==new_e['result_sha256']
 before=len(errors);compare(json.loads(old_raw),json.loads(new_raw),logical);checks[logical]={'mismatches':len(errors)-before,'old_raw_sha256':sha(old_raw),'new_raw_sha256':sha(new_raw)};byte_equal[logical]=(old_raw==new_raw)
rows=json.loads(raw(HERE/'run','result.json'));assert [r['id'] for r in rows]==spec['account_ids']
report={'schema':'saved-current-engine-parity-audit-v1','audited_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'PASS_FROZEN_INPUT_CURRENT_ENGINE_PARITY' if not errors else 'FAIL_PRESERVE_PARITY_MISMATCHES','old_app_commit':old_e['source_commit'],'current_app_commit':new_e['source_commit'],'inputs_byte_verified':inputs,'logical_files':checks,'raw_bytes_equal':byte_equal,'compared':counts,'max_numeric_absolute_difference':max_abs,'max_numeric_relative_difference':max_rel,'mismatches':errors,'accounts':len(rows),'states':sum(len(r['dailyStates']) for r in rows),'fills':sum(len(r['trades']) for r in rows),'formal_validation':False,'new_alpha_discovery':False,'goal_achieved':False,'scope':'Old exact price-only accounts reproduced under current shared core, not live current data, total return, PIT or formal validation.'}
(HERE/'PARITY_AUDIT.json').write_text(json.dumps(report,indent=2)+'\n')
summary={'study_id':'AUDIT-CROSS-MARKET-CURRENT-ENGINE-PARITY-20261008','completed_at':new_e['completed_at'],'parity_status':report['status'],'full_window_seed':'2008-03-02','funded_start':'2008-03-03','end':'2026-10-02','accounts':[{'id':r['id'],'slices':r['slices'],'fills':len(r['trades']),'mean_exposure':r['meanExposure']} for r in rows],'objective_complete':False,'formal_validation':False,'scope':report['scope'],'parent_original_status_unchanged':True,'parity_audit_sha256':sha((HERE/'PARITY_AUDIT.json').read_bytes())}
(HERE/'SUMMARY.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps({k:report[k] for k in ['status','raw_bytes_equal','compared','max_numeric_absolute_difference','states','fills']}))
raise SystemExit(bool(errors))
