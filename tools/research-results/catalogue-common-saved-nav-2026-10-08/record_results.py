"""One-time append of this saved-NAV version; retain all previous master rows."""
from pathlib import Path
import collections
import csv
import gzip
import hashlib
import io
import json

HERE = Path(__file__).resolve().parent
MASTER = HERE.parent / 'strategy-master'
ROOT = HERE.parents[4]


def read(p):
    return json.loads(p.read_bytes())


def write(p, value):
    p.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def sha(data):
    return hashlib.sha256(data).hexdigest()


paths = [MASTER / n for n in ['strategy-master.json', 'strategy-master.csv', 'notion-target.json', 'validation-report.json']]
before = {p: p.read_bytes() for p in paths}
doc = read(paths[0])
target = read(paths[2])
old_rows = doc['rows'][:]
old_overrides = doc['audit_overrides'].copy()
assert len(old_rows) == 336 and len(old_overrides) == 14
assert len(target['pending_keys']) == 70
summary = read(HERE / 'SUMMARY.json')
audit = read(HERE / 'SAVED_AUDIT.json')
compared = read(HERE / 'comparison/result.json')
assert len(compared) == 22 and summary['funded_runs'] == 0
headers = next(csv.reader(io.StringIO(before[paths[1]].decode('utf-8-sig'))))
names = {}
for old in old_rows:
    if old['key'].startswith('POSTHOC:APP-CATALOGUE:20261008:'):
        names[old['key'].split('POSTHOC:APP-CATALOGUE:20261008:', 1)[1].lower()] = old['name'].split('｜')[0]
names.update({'nfci-dual-core-v11-qual-role': 'NFCI质量增强',
              'cross-market-extreme-qqq-cash:gross': '跨市场压力｜毛分红',
              'cross-market-extreme-qqq-cash:withhold30': '跨市场压力｜统一扣税30%'})
rows = []
source = str((HERE / 'COMPARISON_METRICS.csv').relative_to(ROOT))
result_sha = sha((HERE / 'COMPARISON_METRICS.csv').read_bytes())
for index, item in enumerate(compared):
    m = item['slices']['full']
    row = {h: None for h in headers}
    row.update(key='POSTHOC:COMMON20:20261008:' + item['id'].upper(),
               name=names.get(item['id'], item['id']) + '｜20对照完整共同历史补充', kind='对照基线' if index < 20 else '回溯筛选',
               cagr=m['annualizedReturn'] * 100, mdd=m['maxDrawdown'] * 100, sharpe=m['sharpeRF0'],
               since2020=item['slices']['since2020']['annualizedReturn'] * 100,
               since2022=item['slices']['since2022']['annualizedReturn'] * 100,
               latest=audit['audited_at'], time_basis='保存账户完整共同历史独立回读实际完成时间',
               trial_status='POSTHOC_SAVED_COMMON20_DIAGNOSTIC_NOT_FORMAL', validation=audit['status'],
               objective='CONTROL_NOT_NEW_CANDIDATE' if index < 20 else 'USER_SINGLE_INDICATOR_SUPERIORITY_UNPROVEN',
               comparison='CONTROL' if index < 20 else 'FAIL_NUMERIC_RF0_VS_MAX20_COMMON_HISTORY',
               backtest_start=summary['common_start'], backtest_end=summary['common_end'], fee=.025, slip=0, legacy=False,
               review='全部22保存资金日机械交集2013-07-18—2026-09-30共3086日，不重置资金或持仓、零新候选/资金回放/调参。原2002共同5595日QUAL缺2509日失败不变。20目录对照最高金纳双趋势夏普1.033773377，既有八成分压力毛0.985053348/扣税0.976282912均未超过；标的/股息/时钟不同，数值排序不认证经济等价、单一自身价格指标或完整有效前沿。补充比较不视作用户范围问题的回答。',
               source=source, source_sha256=result_sha)
    rows.append(row)
row = {h: None for h in headers}
row.update(key='AUDIT:COMMON20:SAVED-NAV:20261008', name='20目录对照｜完整共同净值与压力失败审计', kind='独立审计',
           latest=audit['audited_at'], time_basis='独立状态/指标/源范围回读完成时间', trial_status=summary['status'],
           validation=audit['status'], objective='USER_SINGLE_INDICATOR_SUPERIORITY_UNPROVEN',
           comparison='STRESS2_BELOW_MAX20_COMMON_NAV', legacy=False,
           review='核验67892共同资金状态、151组原生Swift指标及19真正原生账户指标。来源JSON字段适配仅QUAL字段改名/加ID；全部状态和日期不变。继承nativeFull字段对19项指保存5595日源而非全原生历史，真正原生另存ORIGINAL_NATIVE_ACCOUNT_REPORTS.json。原334+2行及14覆盖不变。Notion唯一键查询额度待恢复，未建新页。',
           source=str((HERE / 'SAVED_AUDIT.json').relative_to(ROOT)), source_sha256=sha((HERE / 'SAVED_AUDIT.json').read_bytes()))
rows.append(row)
keys = [r['key'] for r in rows]
assert len(set(keys)) == 23 and not set(keys) & {r['key'] for r in old_rows}
backup = HERE / 'master-before'
backup.mkdir()
for p, data in before.items():
    (backup / (p.name + '.gz')).write_bytes(gzip.compress(data, mtime=0))
doc['rows'].extend(rows)
pending = target['pending_keys'] + keys
doc['summary'].update(rows=len(doc['rows']), by_kind=dict(collections.Counter(r['kind'] for r in doc['rows'])),
                      latest_research_time_known=sum(bool(r.get('latest')) for r in doc['rows']),
                      numeric_primary_metric_rows=sum(r.get('sharpe') is not None for r in doc['rows']),
                      notion_pending_keys=pending, last_local_update=audit['audited_at'],
                      last_update_note='23 saved common20 comparator/stress/audit records appended. Previous336rows/14overrides preserved; both stress tax paths fail numeric common-history superiority. No original2002 calendar rescue, capital run, alpha/OOS or economic-equivalence certification; Notion query entitlement pending.')
buf = io.StringIO(newline='')
writer = csv.DictWriter(buf, fieldnames=headers, lineterminator='\r\n' if b'\r\n' in before[paths[1]] else '\n')
writer.writerows(rows)
csv_data = before[paths[1]] + buf.getvalue().encode()
target.update(row_count=len(doc['rows']), pending_keys=pending, last_local_update=audit['audited_at'],
              pending_local_csv_sha256=sha(csv_data))
write(paths[0], doc)
paths[1].write_bytes(csv_data)
write(paths[2], target)
write(paths[3], doc['summary'])
assert read(paths[0])['rows'][:336] == old_rows
assert read(paths[0])['audit_overrides'] == old_overrides
assert paths[1].read_bytes().startswith(before[paths[1]])
write(HERE / 'MASTER_ROWS.json', rows)
write(HERE / 'MASTER_RECEIPT.json', {'status': 'LOCAL_APPEND_VERIFIED_NOTION_QUERY_ENTITLEMENT_PENDING',
                                  'previous_rows_unchanged': 336, 'previous_overrides_unchanged': 14,
                                  'new_rows': 23, 'total_rows': 359, 'previous_pending_keys_retained': 70,
                                  'total_pending_keys': 93, 'remote_new_pages_created': 0,
                                  'master_before_sha256': {p.name: sha(data) for p, data in before.items()}})
print(json.dumps({'old_rows_unchanged': 336, 'new_rows': 23, 'local_total': 359, 'pending': 93}))
