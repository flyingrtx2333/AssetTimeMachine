"""Classifier-only reference on retained synthetic MII; no raw estimation/account."""
from pathlib import Path
from datetime import datetime, timezone
import gzip
import hashlib
import importlib
import json
import sys
import types

import numpy as np
import pandas as pd

HERE = Path(__file__).resolve().parent
PREVIOUS = HERE.parent / 'marketmind-full-estimator-audit-2026-10-08'
SOURCE = HERE.parent / 'marketmind-causal-audit-2026-10-06'
package = types.ModuleType('marketmind')
package.__path__ = [str(SOURCE / 'source/src/marketmind')]
sys.modules['marketmind'] = package
regimes = importlib.import_module('marketmind.regimes')
sha = lambda data: hashlib.sha256(data).hexdigest()
manifest = json.loads((SOURCE / 'SOURCE_MANIFEST.json').read_bytes())
binding = next(item for item in manifest['files'] if item['path'].endswith('/regimes.py'))
assert sha((SOURCE / binding['path']).read_bytes()) == binding['sha256']
audit = json.loads((PREVIOUS / 'FULL_ESTIMATOR_AUDIT.json').read_bytes())
cases = []


def add_case(key, values):
    classified = regimes.classify_regimes(values, lookback=756, min_history=252, monthly=True)
    cases.append({'id': key,
                  'points': [{'day': str(day.date()), 'value': None if pd.isna(value) else float(value)}
                             for day, value in values.items()],
                  'expected': [{'day': str(day.date()), 'value': None if pd.isna(row['mii']) else float(row['mii']),
                                'lower': None if pd.isna(row['lower']) else float(row['lower']),
                                'upper': None if pd.isna(row['upper']) else float(row['upper']),
                                'regime': None if pd.isna(row['regime']) else str(row['regime'])}
                               for day, row in classified.iterrows()]})


for item in audit['snapshots']:
    raw = gzip.decompress((PREVIOUS / item['path']).read_bytes())
    assert sha(raw) == item['raw_sha256']
    frame = json.loads(raw)['mii']
    series = pd.Series([row[0] for row in frame['data']], index=pd.to_datetime(frame['index']), name='mii')
    add_case(Path(item['path']).name.removesuffix('.json.gz'), series)
dates = pd.bdate_range('2000-01-03', periods=1000)
add_case('flat_mii', pd.Series(.5, index=dates, name='mii'))
sparse = pd.Series(.5 + .3 * np.sin(np.arange(1000) / 25), index=dates, name='mii')
sparse.iloc[200:300] = np.nan
sparse.iloc[800:950] = np.nan
add_case('missing_mii', sparse)
assert len(cases) == 11 and 'marketmind.mii' not in sys.modules and 'marketmind.backtest' not in sys.modules
fixture = {'kind': 'synthetic-mii-classification-reference-v1', 'synthetic': True, 'cases': cases}
data = (json.dumps(fixture, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n').encode()
(HERE / 'FIXTURE.json').write_bytes(data)
receipt = {'prepared_at': datetime.now(timezone.utc).isoformat(), 'fixture_sha256': sha(data),
           'original_classifier_sha256': binding['sha256'], 'source_commit': manifest['source_commit'],
           'full_estimator_audit_sha256': sha((PREVIOUS / 'FULL_ESTIMATOR_AUDIT.json').read_bytes()),
           'cases': 11, 'reference_states': sum(len(item['points']) for item in cases),
           'raw_estimator_runs': 0, 'account_runs': 0, 'actual_market_data': False}
(HERE / 'FIXTURE_RECEIPT.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt))
