"""Append native existing-comparator result and coverage audit; preserve history."""
from pathlib import Path
import collections, csv, gzip, hashlib, io, json

HERE = Path(__file__).resolve().parent
MASTER = HERE.parent/'strategy-master'
ROOT = HERE.parents[4]
def read(p): return json.loads(p.read_bytes())
def write(p,d): p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

s = read(HERE/'SUMMARY.json'); a = read(HERE/'SAVED_AUDIT.json')
assert s['funded_replays']==1 and not s['objective_complete']
paths = [MASTER/n for n in ['strategy-master.json','strategy-master.csv','notion-target.json','validation-report.json']]
before = {p:p.read_bytes() for p in paths}; doc = read(paths[0]); target = read(paths[2])
old = doc['rows'][:]; old_overrides = doc['audit_overrides'].copy()
assert len(old)==334
headers = next(csv.reader(io.StringIO(before[paths[1]].decode('utf-8-sig'))))
row = {h:None for h in headers}
row.update(key='POSTHOC:APP-QUAL:NATIVE:20261008',name='NFCI质量增强｜当前App原生全历史对照',kind='对照基线',
           cagr=s['native_cagr_percent'],mdd=s['native_mdd_percent'],sharpe=s['native_sharpe_rf0'],
           latest=s['completed_at'],time_basis='共享Swift原生QUAL资金账户实际完成时间',
           trial_status=s['status'],validation='NATIVE_SAVED_ACCOUNTING_METRICS_PASS; HYBRID_ETF_EXECUTABILITY_NOT_CERTIFIED',
           objective='EXISTING_COMPLEX_COMPARATOR_NOT_NEW_SINGLE_INDICATOR_CANDIDATE',
           comparison='FAIL_FROZEN2002_COMMON_COVERAGE; NATIVE2013_RF0_NOT_DIRECTLY_RANKABLE',
           backtest_start=s['native_start'],backtest_end=s['native_end'],fee=.025,slip=0,legacy=False,
           review='QUAL源恢复、唯一1个现有规则账户，无调参/重跑。原生2013-07-18—2026-09-30、3086日、287成交，夏普0.962698；不能直接对原19条2002起5595日0.996612排名。缺2509上市前日，固定不缩短比较按设计FAIL，不补零/接旧曲线/SPY替换救回。原19状态/市场及as-of不变，原QUAL参数不变，旧匹配总回报正式FAIL不变。调整收盘价混合收益角色，不是逐笔真实ETF分红/股数账户、独立alpha或完整有效前沿证明。',
           source=str((HERE/'SUMMARY.json').relative_to(ROOT)),source_sha256=sha(HERE/'SUMMARY.json'))
audit = {h:None for h in headers}
audit.update(key='AUDIT:APP-QUAL:SOURCE-CALENDAR:20261008',name='QUAL源恢复｜完整历史范围与保存账户审计',kind='独立审计',
             latest=a['audited_at'],time_basis='真实保存资金/指标与完整共同日覆盖审计完成时间',
             trial_status='SOURCE_RECOVERED_NATIVE_REPLAY_PASS_LONG_COMPARISON_FAIL',validation=a['status'],
             objective='USER_SINGLE_INDICATOR_SUPERIORITY_UNPROVEN',comparison='LONG_COMMON_HISTORY_MISSING2509_PRE_LISTING_DATES',legacy=False,
             review=s['conclusion']+' QUAL完整响应3325条，原生保存3086日/287成交；资产角色实际成交无缺QUAL报价日。保留首次十进制序列化哈希错误与第二次原长历史覆盖拒绝；未缩短原长历史或重跑资金。全历史范围可选澄清已发出，待回复；不自动选有利区间。',
             source=str((HERE/'SAVED_AUDIT.json').relative_to(ROOT)),source_sha256=sha(HERE/'SAVED_AUDIT.json'))
rows = [row,audit]
assert not {r['key'] for r in rows}&{r['key'] for r in old}
backup = HERE/'master-before'; backup.mkdir()
for p,b in before.items():
    (backup/(p.name+'.gz')).write_bytes(gzip.compress(b,mtime=0)); assert p.read_bytes()==b
doc['rows'].extend(rows)
pending_key = 'PENDING:APP-CATALOGUE:20261008:NFCI-QUAL'
assert pending_key in {r['key'] for r in old} and pending_key not in old_overrides
doc['audit_overrides'][pending_key] = {
    'status':'SOURCE_RECOVERED_NATIVE2013_ACCOUNT_COMPLETE_LONG2002_COMPARISON_FAILED',
    'exclude_from_current_strategy_comparisons':True,
    'reason':'Prior pending-input record is now historical. QUAL data recovered and native current App result recorded separately; missing2509pre-listing dates prevents the fixed original5595date comparison. No inferiority claim or period rescue.',
    'audit_key':audit['key'],'replacement_evidence_key':row['key'],'historical_row_preserved':True,
    'source':str((HERE/'PRIMARY_COMPARISON_FAILURE.json').relative_to(ROOT)),
    'source_sha256':sha(HERE/'PRIMARY_COMPARISON_FAILURE.json'),'latest_audit_date':a['audited_at']}
buf = io.StringIO(newline=''); writer = csv.DictWriter(buf,fieldnames=headers,lineterminator='\r\n' if b'\r\n' in before[paths[1]] else '\n');writer.writerows(rows)
csv_data = before[paths[1]] + buf.getvalue().encode()
pending = list(dict.fromkeys(target['pending_keys']+[r['key'] for r in rows]))
doc['summary'].update(rows=len(doc['rows']),by_kind=dict(collections.Counter(r['kind'] for r in doc['rows'])),
    latest_research_time_known=sum(bool(r.get('latest')) for r in doc['rows']),
    numeric_primary_metric_rows=sum(r.get('sharpe') is not None for r in doc['rows']),
    notion_pending_keys=pending,last_local_update=a['audited_at'],
    active_audit_override_keys=list(doc['audit_overrides']),
    last_update_note='QUAL source recovered;1existing native2013 account and coverage audit added. Fixed2002 long comparison fails2509missing days; no narrowing/alpha/rescue. Previous334rows and13overrides unchanged, prior pending-input row status qualified separately. Notion unique-query entitlement pending.')
target.update(row_count=len(doc['rows']),pending_keys=pending,last_local_update=a['audited_at'],
              pending_local_csv_sha256=hashlib.sha256(csv_data).hexdigest())
target['pending_audit_override_keys'] = list(dict.fromkeys(target.get('pending_audit_override_keys',[])+[pending_key]))
write(paths[0],doc);paths[1].write_bytes(csv_data);write(paths[2],target);write(paths[3],doc['summary'])
assert read(paths[0])['rows'][:-2]==old
assert all(read(paths[0])['audit_overrides'][k]==v for k,v in old_overrides.items())
assert paths[1].read_bytes().startswith(before[paths[1]])
write(HERE/'MASTER_ROWS.json',rows)
write(HERE/'MASTER_RECEIPT.json',{'status':'LOCAL_APPEND_VERIFIED_NOTION_QUERY_ENTITLEMENT_PENDING',
    'previous_rows_unchanged':334,'previous_overrides_unchanged':13,'new_rows':2,'total_rows':336,
    'previous_pending_keys_retained':len(pending)-2,'total_pending_keys':len(pending),'remote_new_pages_created':0,
    'source_recovered_pending_override_key':pending_key,
    'master_before_sha256':{p.name:hashlib.sha256(b).hexdigest() for p,b in before.items()}})
print(json.dumps({'old_rows_unchanged':334,'new_rows':2,'local_total':336,'pending_keys':len(pending)}))
