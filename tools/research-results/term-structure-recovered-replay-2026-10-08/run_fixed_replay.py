"""One frozen Swift execution of the original 12-account recovered family."""
from pathlib import Path
from datetime import datetime,timezone
import argparse,gzip,hashlib,json,os,subprocess,tempfile
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[4]
parser=argparse.ArgumentParser();parser.add_argument('--source-repo',default=os.environ.get('ASSET_TIME_MACHINE_APP_REPO',ROOT.parent/'AssetTimeMachine'));args=parser.parse_args();APP=Path(args.source_repo).resolve()
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
f=json.loads((HERE/'TECHNICAL_FREEZE.json').read_bytes());d=json.loads((HERE/'DECLARATION.json').read_bytes())
assert not (HERE/'RUN_RECEIPT.json').exists() and not (HERE/'run').exists()
assert subprocess.check_output(['rtk','proxy','git','rev-parse','HEAD'],cwd=APP,text=True).strip()==f['app_commit']
assert subprocess.check_output(['rtk','proxy','git','remote','get-url','origin'],cwd=APP,text=True).strip()==f['app_remote']
assert sha(HERE/'DECLARATION.json')==f['declaration_sha256']
assert sha(HERE/'run_fixed_replay.py')==f['launcher_sha256'] and sha(HERE/'audit_saved_replay.py')==f['auditor_sha256']
assert all(sha(APP/path)==h for path,h in f['code_files'].items())
assert all(sha(HERE/path)==h for path,h in f['prepared_files'].items())
binary=APP/'.build/release/AssetTimeMachineResearch';assert sha(binary)==f['binary_sha256']
with tempfile.TemporaryDirectory(prefix='atm-recovered-term-') as folder:
 temp=Path(folder)
 for key in ['history','curve']:
  data=gzip.decompress((HERE/(key+'.json.gz')).read_bytes());assert hashlib.sha256(data).hexdigest()==d['input_sha256'][key];(temp/(key+'.json')).write_bytes(data)
 cmd=['rtk','proxy',str(binary),'recovered-term-structure','--mode','run','--curve',str(temp/'curve.json'),'--history',str(temp/'history.json'),'--prepared',str(HERE/'prepare'),'--output',str(HERE/'run'),'--source-commit',f['app_commit']]
 receipt={'started_at':datetime.now(timezone.utc).isoformat(),'command':cmd,'app_commit':f['app_commit'],'root_freeze_commit':subprocess.check_output(['rtk','proxy','git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'status':'STARTED','funded_accounts':12,'parameter_searches':0}
 (HERE/'RUN_RECEIPT.json').write_text(json.dumps(receipt,indent=2)+'\n');p=subprocess.run(cmd,cwd=APP,capture_output=True,timeout=180)
 (HERE/'STDOUT.txt').write_bytes(p.stdout);(HERE/'STDERR.txt').write_bytes(p.stderr);receipt.update(completed_at=datetime.now(timezone.utc).isoformat(),exit_code=p.returncode,status='COMPLETED' if p.returncode==0 else 'FAILED_PRESERVE_ATTEMPT');(HERE/'RUN_RECEIPT.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt));raise SystemExit(p.returncode)
