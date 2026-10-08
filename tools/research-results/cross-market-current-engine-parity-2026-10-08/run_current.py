"""One fixed-data current Swift replay. Python only decodes frozen inputs and launches CLI."""
import gzip,hashlib,json,subprocess,tempfile
from datetime import datetime,timezone
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[4];APP=ROOT.parent/'AssetTimeMachine'
sha=lambda b:hashlib.sha256(b).hexdigest()
f=json.loads((HERE/'TECHNICAL_FREEZE.json').read_bytes());d=json.loads((HERE/'DECLARATION.json').read_bytes())
assert not (HERE/'RUN_RECEIPT.json').exists() and not (HERE/'run').exists()
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=APP,text=True).strip()==f['app_commit']
assert sha((HERE/'DECLARATION.json').read_bytes())==f['declaration_sha256']
assert all(sha((APP/path).read_bytes())==h for path,h in f['code_files'].items())
binary=APP/'.build/release/AssetTimeMachineResearch';assert sha(binary.read_bytes())==f['binary_sha256']
with tempfile.TemporaryDirectory(prefix='atm-stress-parity-') as temp:
 temp=Path(temp)
 for logical in ['prices','history']:
  raw=gzip.decompress((HERE/(logical+'.json.gz')).read_bytes());assert sha(raw)==d['inputs'][logical]['raw_sha256'];(temp/(logical+'.json')).write_bytes(raw)
 cmd=[str(binary),'cross-market-stress-screen','--prices',str(temp/'prices.json'),'--history',str(temp/'history.json'),'--output',str(HERE/'run'),'--source-commit',f['app_commit']]
 r={'started_at':datetime.now(timezone.utc).isoformat(),'command':cmd,'app_commit':f['app_commit'],'root_freeze_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'status':'STARTED','funded_accounts':4,'parameter_searches':0}
 (HERE/'RUN_RECEIPT.json').write_text(json.dumps(r,indent=2)+'\n')
 p=subprocess.run(cmd,cwd=APP,capture_output=True,timeout=180)
 for name,raw in [('STDOUT.txt',p.stdout),('STDERR.txt',p.stderr)]: (HERE/name).write_bytes(raw)
 r.update(completed_at=datetime.now(timezone.utc).isoformat(),exit_code=p.returncode,status='COMPLETED' if p.returncode==0 else 'FAILED_PRESERVE_ATTEMPT');(HERE/'RUN_RECEIPT.json').write_text(json.dumps(r,indent=2)+'\n')
 print(json.dumps(r));raise SystemExit(p.returncode)
