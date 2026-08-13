from pathlib import Path
import subprocess
import sys

build_dir = Path('build/TestFlight-1.12-163')
archive = build_dir / 'AssetTimeMachine.xcarchive'
ipa = build_dir / 'export' / 'AssetTimeMachine.ipa'
delivery_file = build_dir / 'delivery-id.txt'
print(f'ARCHIVE_EXISTS={archive.exists()}')
print(f'IPA_EXISTS={ipa.exists()}')
if not delivery_file.exists():
    print('DELIVERY_ID_MISSING')
    raise SystemExit(3)
text = delivery_file.read_text().strip()
delivery_id = text.split('=', 1)[-1].strip()
print(f'DELIVERY_ID={delivery_id}')
result = subprocess.run(
    ['scripts/check_testflight_status.sh', delivery_id],
    text=True,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    timeout=170,
    check=False,
)
print(result.stdout, end='')
raise SystemExit(result.returncode)
