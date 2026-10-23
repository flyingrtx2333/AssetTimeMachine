"""Guarded one-time append of an audit-only version; no account generation."""
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
KEY = 'AUDIT:MII:SWIFT-CLASSIFIER:READINESS:20261008'
read = lambda path: json.loads(path.read_bytes())
sha = lambda data: hashlib.sha256(data).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


paths = [MASTER / name for name in ['strategy-master.json', 'strategy-master.csv',
                                   'notion-target.json', 'validation-report.json']]
before = {path: path.read_bytes() for path in paths}
doc, target = read(paths[0]), read(paths[2])
old_rows, old_overrides, old_pending = doc['rows'][:], doc['audit_overrides'].copy(), target['pending_keys'][:]
assert len(old_rows) == 361 and len(old_overrides) == 14 and len(old_pending) == 95
assert KEY not in {row['key'] for row in old_rows} and KEY not in old_pending
summary, audit = read(HERE / 'SUMMARY.json'), read(HERE / 'SAVED_AUDIT.json')
audit['verified_at'] = summary['completed_at']
assert summary['funded_runs'] == summary['new_candidates'] == summary['parameter_searches'] == 0
headers = next(csv.reader(io.StringIO(before[paths[1]].decode('utf-8-sig'))))
row = {header: None for header in headers}
row.update(key=KEY, name='完整MarketMind MII｜Swift因果分类与市场输入准入', kind='独立审计',
           latest=audit['verified_at'], time_basis='实际原生分类输出与市场来源审计完成时间',
           trial_status=summary['status'], validation=audit['status'],
           objective='USER_SINGLE_INDICATOR_SUPERIORITY_UNPROVEN', comparison='NOT_EVALUATED_NO_ACCOUNT',
           legacy=False, source=str((HERE / 'SUMMARY.json').relative_to(ROOT)),
           source_sha256=sha((HERE / 'SUMMARY.json').read_bytes()),
           review='Swift固定252预热分类成功编译；11参考案例8882状态/17764阈值匹配，1194共同前缀状态精确不变，5拒绝及月更新当前值隔离通过。仅分类移植，非完整估计器或交易候选。一次生产基础目录200/38项、0全史请求；固定作者主列SPX/NDX/SX5E/ES，网络默认全列，禁止缺主列静默回退。NDX身份、ES滚动、跨市场可得时刻、陈旧与修订政策仍缺；配置ffill5不能约束估计器无界ffill。0实际市场特征/账户/收益搜索；旧361行/14覆盖/95待同步键保留，Notion额度待恢复。')
assert all(row[field] is None for field in ['cagr', 'mdd', 'sharpe', 'fee', 'slip', 'since2020', 'since2022'])
backup = HERE / 'master-before'
backup.mkdir()
for path, data in before.items():
    (backup / (path.name + '.gz')).write_bytes(gzip.compress(data, mtime=0))
doc['rows'].append(row)
pending = old_pending + [KEY]
doc['summary'].update(rows=len(doc['rows']), by_kind=dict(collections.Counter(item['kind'] for item in doc['rows'])),
                      latest_research_time_known=sum(bool(item.get('latest')) for item in doc['rows']),
                      numeric_primary_metric_rows=sum(item.get('sharpe') is not None for item in doc['rows']),
                      notion_pending_keys=pending, last_local_update=audit['verified_at'],
                      last_update_note='One native fixed252 MII classifier and real input readiness audit appended; previous361rows/14overrides/95pending retained. Native classification parity passes but full raw-feature Swift port and real-market identity/as-of/roll/stale contract remain incomplete. No candidate, account, return search, formal gate or objective pass; Notion query entitlement pending.')
buffer = io.StringIO(newline='')
csv.DictWriter(buffer, fieldnames=headers, lineterminator='\n').writerow(row)
csv_data = before[paths[1]] + buffer.getvalue().encode()
target.update(row_count=len(doc['rows']), pending_keys=pending, last_local_update=audit['verified_at'],
              pending_local_csv_sha256=sha(csv_data))
write(paths[0], doc)
paths[1].write_bytes(csv_data)
write(paths[2], target)
write(paths[3], doc['summary'])
assert read(paths[0])['rows'][:361] == old_rows and read(paths[0])['audit_overrides'] == old_overrides
assert read(paths[2])['pending_keys'][:95] == old_pending
assert paths[1].read_bytes().startswith(before[paths[1]])
write(HERE / 'MASTER_ROWS.json', [row])
write(HERE / 'MASTER_RECEIPT.json', {
    'status': 'LOCAL_APPEND_VERIFIED_NOTION_QUERY_ENTITLEMENT_PENDING',
    'previous_rows_unchanged': 361, 'previous_overrides_unchanged': 14,
    'new_audit_rows': 1, 'total_rows': 362,
    'previous_pending_keys_retained': 95, 'total_pending_keys': 96, 'remote_new_pages_created': 0,
    'master_before_sha256': {path.name: sha(data) for path, data in before.items()},
    'master_after_sha256': {path.name: sha(path.read_bytes()) for path in paths},
})
print(json.dumps({'old_rows_unchanged': 361, 'new_audit_rows': 1, 'total_rows': 362, 'pending': 96}))
