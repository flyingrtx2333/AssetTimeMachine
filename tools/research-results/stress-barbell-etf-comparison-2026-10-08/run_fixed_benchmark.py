"""Unpack frozen inputs and launch the shared Swift simulator once."""
from pathlib import Path
from datetime import datetime, timezone
import gzip, hashlib, json, subprocess, tempfile
HERE=Path(__file__).resolve().parent; ROOT=HERE.parents[4]; APP=ROOT.parent/'AssetTimeMachine'
def sha(b):return hashlib.sha256(b).hexdigest()
f=json.loads((HERE/'TECHNICAL_FREEZE.json').read_bytes());d=json.loads((HERE/'DECLARATION.json').read_bytes())
assert not (HERE/'RUN_RECEIPT.json').exists() and not (HERE/'run').exists()
assert subprocess.check_output(['rtk','proxy','git','rev-parse','HEAD'],cwd=APP,text=True).strip()==f['app_commit']
assert sha((HERE/'DECLARATION.json').read_bytes())==f['declaration_sha256']
assert sha((HERE/'run_fixed_benchmark.py').read_bytes())==f['launcher_sha256']
assert sha((HERE/'audit_saved_benchmark.py').read_bytes())==f['auditor_sha256']
assert all(sha((APP/path).read_bytes())==h for path,h in f['code_files'].items())
assert sha((HERE/'cash.json').read_bytes())==d['cash_sha256']
binary=APP/'.build/release/AssetTimeMachineResearch';assert sha(binary.read_bytes())==f['binary_sha256']
with tempfile.TemporaryDirectory(prefix='atm-barbell-etf-') as folder:
    temp=Path(folder)
    for key in ['prices','history']:
        data=gzip.decompress((HERE/(key+'.json.gz')).read_bytes());assert sha(data)==d[{'prices':'input_sha256','history':'history_sha256'}[key]];(temp/(key+'.json')).write_bytes(data)
    cmd=['rtk','proxy',str(binary),'stress-barbell-etf-comparison','--prices',str(temp/'prices.json'),'--history',str(temp/'history.json'),'--cash',str(HERE/'cash.json'),'--output',str(HERE/'run'),'--source-commit',f['app_commit']]
    receipt={'started_at':datetime.now(timezone.utc).isoformat(),'command':cmd,'app_commit':f['app_commit'],'root_freeze_commit':subprocess.check_output(['rtk','proxy','git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'status':'STARTED','funded_accounts':2,'parameter_searches':0}
    (HERE/'RUN_RECEIPT.json').write_text(json.dumps(receipt,indent=2)+'\n')
    p=subprocess.run(cmd,cwd=APP,capture_output=True,timeout=180)
    (HERE/'STDOUT.txt').write_bytes(p.stdout);(HERE/'STDERR.txt').write_bytes(p.stderr)
    receipt.update(completed_at=datetime.now(timezone.utc).isoformat(),exit_code=p.returncode,status='COMPLETED' if p.returncode==0 else 'FAILED_PRESERVE_ATTEMPT')
    (HERE/'RUN_RECEIPT.json').write_text(json.dumps(receipt,indent=2)+'\n');print(json.dumps(receipt));raise SystemExit(p.returncode)
