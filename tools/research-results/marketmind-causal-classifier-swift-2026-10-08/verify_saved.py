"""Independent classifier parity/prefix readback; no native rerun or account."""
from pathlib import Path
from datetime import datetime, timezone
import hashlib
import json
import math

HERE = Path(__file__).resolve().parent
read = lambda path: json.loads(path.read_bytes())
sha = lambda data: hashlib.sha256(data).hexdigest()
fixture, native = read(HERE / 'FIXTURE.json'), read(HERE / 'SWIFT_STATES.json')
receipt = read(HERE / 'FIXTURE_RECEIPT.json')
assert sha((HERE / 'FIXTURE.json').read_bytes()) == receipt['fixture_sha256']
assert len(native) == len(fixture['cases']) == 11
by_id = {item['id']: item['states'] for item in native}
count = 0
thresholds = 0
for case in fixture['cases']:
    states = by_id[case['id']]
    assert len(states) == len(case['expected'])
    for actual, expected in zip(states, case['expected']):
        for key in ['day', 'value', 'regime']:
            assert actual.get(key) == expected.get(key)
        for key in ['lower', 'upper']:
            left, right = actual.get(key), expected.get(key)
            assert (left is None and right is None) or (left is not None and right is not None and
                   math.isclose(left, right, rel_tol=0, abs_tol=1e-12))
            thresholds += 1
        count += 1
prefix_states = 0
for name in ['complete', 'past_missing_values', 'asynchronous_network_dates']:
    prefix = by_id[name + '-prefix']
    full = by_id[name + '-full'][:len(prefix)]
    future = by_id[name + '-future-perturbed'][:len(prefix)]
    assert prefix == full == future
    prefix_states += len(prefix)
run = read(HERE / 'RUN_RECEIPT.json')
assert len(run['operations']) == 2 and all(item['exit_code'] == 0 for item in run['operations'])
for item in run['operations']:
    for channel in ['stdout', 'stderr']:
        assert sha((HERE / (item['phase'] + '.' + channel + '.txt')).read_bytes()) == item[channel + '_sha256']
out = {'verified_at': datetime.now(timezone.utc).isoformat(),
       'status': 'PASS_SWIFT_FIXED252_CLASSIFIER_PARITY_AND_EXACT_PREFIX',
       'states': count, 'threshold_cells': thresholds, 'exact_shared_prefix_states': prefix_states,
       'reference_cases': 11, 'native_rejections': 5, 'monthly_current_value_isolation': 'PASS_NATIVE_ASSERTION',
       'fixture_sha256': receipt['fixture_sha256'], 'swift_states_sha256': sha((HERE / 'SWIFT_STATES.json').read_bytes()),
       'account_runs': 0, 'raw_feature_estimator_runs': 0, 'actual_market_availability_certified': False,
       'objective_complete': False}
(HERE / 'SAVED_AUDIT.json').write_text(json.dumps(out, indent=2) + '\n')
print(json.dumps(out))
