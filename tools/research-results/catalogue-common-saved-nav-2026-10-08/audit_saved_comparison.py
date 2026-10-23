"""Read saved funded states only; never generate trades, targets or accounts."""
from pathlib import Path
from datetime import datetime, timezone
from zoneinfo import ZoneInfo
import gzip
import hashlib
import json
import math
import statistics

HERE = Path(__file__).resolve().parent


def raw(path):
    return path.read_bytes() if path.exists() else gzip.decompress(Path(str(path) + '.gz').read_bytes())


def read(path):
    return json.loads(raw(path))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def day(value):
    return datetime.fromisoformat(value.replace('Z', '+00:00')).astimezone(ZoneInfo('Asia/Shanghai')).date()


def close(a, b):
    assert math.isclose(a, b, rel_tol=1e-10, abs_tol=1e-10), (a, b)


inputs = read(HERE / 'accounts.json')
sources = {}
for entry in inputs['files']:
    path = Path(entry['path'])
    assert sha(raw(path)) == entry['sha256']
    rows = read(path)
    for key in entry['ids']:
        matching = [row for row in rows if row['id'] == key]
        assert len(matching) == 1
        sources[key] = matching[0]['dailyStates']
assert len(sources) == 22

provenance = read(HERE / 'INPUT_PROVENANCE.json')
root = HERE.parents[4]
originals = {}
for key, item in provenance['source_accounts'].items():
    data = raw(root / item['path'])
    assert sha(data) == item['raw_sha256']
    originals[key] = json.loads(data)
assert sources['nfci-dual-core-v11-qual-role'] == originals['qual']['daily_states']
for row in originals['catalogue19']:
    assert sources[row['id']] == row['dailyStates']
for row in originals['stress']:
    if row['id'] in sources:
        assert sources[row['id']] == row['dailyStates']

common = sorted(set.intersection(*(set(s['date'] for s in states) for states in sources.values())))
common_set = set(common)
rows = read(HERE / 'comparison/result.json')
evidence = read(HERE / 'comparison/evidence.json')
assert sha(raw(HERE / 'comparison/result.json')) == evidence['result_sha256']
assert evidence['common_dates'] == [day(d).isoformat() for d in common]
assert len(common) == 3086 and day(common[0]).isoformat() == '2013-07-18'
assert day(common[-1]).isoformat() == '2026-09-30'
assert [r['id'] for r in rows] == list(sources)
groups = states_checked = 0


def metric_check(states, metric):
    global groups
    a, b = day(metric['start']), day(metric['end'])
    selected = [s for s in states if a <= day(s['date']) <= b]
    assert len(selected) == metric['pointCount']
    assert selected[0]['date'] == metric['start'] and selected[-1]['date'] == metric['end']
    values = [s['portfolioValue'] for s in selected]
    returns = [y / x - 1 for x, y in zip(values, values[1:])]
    years = (b - a).days / 365.25
    product = peak = 1.0
    drawdown = 0.0
    for r in returns:
        product *= 1 + r
        peak = max(peak, product)
        drawdown = max(drawdown, (peak - product) / peak)
    close(product ** (1 / years) - 1, metric['annualizedReturn'])
    close(drawdown, metric['maxDrawdown'])
    close(statistics.mean(returns) / statistics.stdev(returns) * math.sqrt(len(returns) / years), metric['sharpeRF0'])
    groups += 1


for row in rows:
    native = sources[row['id']]
    matched = [s for s in native if s['date'] in common_set]
    assert row['dailyStates'] == matched
    assert [s['date'] for s in matched] == common
    assert row['nativeStateCount'] == len(native)
    for state in matched:
        held = sum(state['holdingsBySymbol'].values())
        receivable = state.get('distributionReceivable', 0) or 0
        assert all(v >= 0 for v in state['holdingsBySymbol'].values())
        assert state['cash'] >= -1e-8 and held <= state['portfolioValue'] * (1 + 1e-12)
        close(held + state['cash'] + receivable, state['portfolioValue'])
        states_checked += 1
    for metric in row['slices'].values():
        metric_check(matched, metric)
    metric_check(native, row['nativeFull']['native_full'])

native_reports = read(HERE / 'ORIGINAL_NATIVE_ACCOUNT_REPORTS.json')['rows']
assert len(native_reports) == 19
for report in native_reports:
    data = raw(root / report['source'])
    assert sha(data) == report['raw_sha256']
    original = json.loads(data)
    states = original['daily_states']
    metric_check(states, {'start': states[0]['date'], 'end': states[-1]['date'],
                         'pointCount': len(states), 'annualizedReturn': original['annualized_return'],
                         'maxDrawdown': original['max_drawdown'], 'sharpeRF0': original['sharpe_rf0']})
    assert len(states) == report['point_count']
    assert original['sharpe_rf0'] == report['sharpe_rf0']

prior = read(HERE.parent / 'product-qual-benchmark-2026-10-08/PRIMARY_COMPARISON_FAILURE.json')
assert prior['status'] == 'FAIL_FROZEN_FULL_LONG_CALENDAR_COVERAGE_NO_RESCUE'
assert len(prior['missing_dates']) == 2509
compared = rows[:20]
champion = max(compared, key=lambda row: row['slices']['full']['sharpeRF0'])
cases = []
for row in rows[20:]:
    m = row['slices']['full']
    delta = m['sharpeRF0'] - champion['slices']['full']['sharpeRF0']
    cases.append({'id': row['id'], 'metrics': m, 'difference_from_catalogue_max': delta,
                  'numeric_common_history_outperformance': delta > 0})
at = datetime.now(timezone.utc).isoformat()
audit = {'status': 'PASS_SAVED_STATES_AND_OFFICIAL_RF0_METRICS', 'audited_at': at,
         'states_checked': states_checked, 'metric_groups_checked': groups,
         'original_states_values_dates_and_positions_unchanged': True,
         'QUAL_adapter_only_renamed_JSON_field_and_added_id': True,
         'complete_saved_source_history_metrics_retained': True, 'original19_native_reports_separately_retained': 'ORIGINAL_NATIVE_ACCOUNT_REPORTS.json', 'original_2002_comparison_failure_preserved': True,
         'funded_runs': 0, 'new_candidates': 0, 'formal_validation': False,
         'not_certified': ['same instruments and total-return accounting across catalogue and stress',
                           'single own-price indicator', 'historical PIT/source vintage', 'G0-G6/OOS',
                           'complete executable strategy frontier']}
summary = {'status': 'SAVED_COMMON20_COMPARISON_COMPLETE_STRESS2_NOT_SUPERIOR', 'audited_at': at,
           'common_start': day(common[0]).isoformat(), 'common_end': day(common[-1]).isoformat(),
           'common_point_count': len(common), 'catalogue_comparator_count': 20,
           'highest_catalogue_id': champion['id'], 'highest_catalogue_full': champion['slices']['full'],
           'stress_diagnostics': cases, 'funded_runs': 0, 'new_candidates': 0,
           'history_range_user_choice_assumed': False, 'original_long_failure_preserved': True,
           'objective_complete': False, 'recommendation_eligible': False,
           'conclusion': 'The longest exact shared saved-NAV calendar is2013-07-18 to2026-09-30. Both already-viewed stress cash-tax diagnostics have lower Rf0 Sharpe than the maximum among all20 eligible App catalogue comparators. This supplemental post-hoc comparison neither rescues the original2002 full-calendar failure nor certifies economic comparability or a simple single-indicator winner.'}
for name, obj in [('SAVED_AUDIT.json', audit), ('SUMMARY.json', summary)]:
    (HERE / name).write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({'states': states_checked, 'metrics': groups, 'champion': champion['id'],
                  'champion_sharpe': champion['slices']['full']['sharpeRF0'], 'stress_deltas': [c['difference_from_catalogue_max'] for c in cases]}))
