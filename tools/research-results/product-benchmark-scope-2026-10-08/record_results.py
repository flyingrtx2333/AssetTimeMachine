"""Append all existing comparator results/pending audit; preserve prior master rows."""
from pathlib import Path
import collections, csv, gzip, hashlib, io, json

HERE = Path(__file__).resolve().parent
MASTER = HERE.parent/'strategy-master'
ROOT = HERE.parents[4]

def read(p): return json.loads(p.read_bytes())
def write(p, d): p.write_text(json.dumps(d, ensure_ascii=False, indent=2)+'\n')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

s = read(HERE/'SUMMARY.json'); a = read(HERE/'SAVED_AUDIT.json'); c = read(HERE/'prepare/contract.json')
assert a['status'].startswith('PASS') and len(s['rows']) == 19
paths = [MASTER/n for n in ['strategy-master.json','strategy-master.csv','notion-target.json','validation-report.json']]
before = {p:p.read_bytes() for p in paths}
doc = read(paths[0]); target = read(paths[2]); old = doc['rows'][:]
old_overrides = doc['audit_overrides'].copy()
assert len(old) == 313
headers = next(csv.reader(io.StringIO(before[paths[1]].decode('utf-8-sig'))))
rows = []
for item in s['rows']:
    entry = next(r for r in c['catalogue'] if r['id'] == item['id']); m = item['slices']['full']
    row = {h:None for h in headers}
    row.update(key='POSTHOC:APP-CATALOGUE:20261008:'+item['id'].upper(),
               name=entry['title_key']+'｜既有目录完整共同历史对照',kind='对照基线',
               cagr=m['annualizedReturn']*100,mdd=m['maxDrawdown']*100,sharpe=m['sharpeRF0'],
               latest=s['completed_at'],time_basis='共享Swift既有规则实际资金回放完成时间',
               trial_status='POSTHOC_EXISTING_APP_BENCHMARK_SCOPE_NOT_FORMAL',
               validation='SAVED_ACCOUNTING_METRICS_QUOTE_DATE_PASS; FORMAL_PIT_OOS_NOT_CERTIFIED',
               objective='EXISTING_COMPARATOR_NOT_NEW_CANDIDATE',comparison='19_READY_EXACT_COMMON_DATES; QUAL_PENDING_COMPLETE_FRONTIER_NOT_CERTIFIED',
               backtest_start=s['common_start'],backtest_end=s['common_end'],fee=.025,slip=0,
               since2020=item['slices']['since2020']['annualizedReturn']*100,
               since2022=item['slices']['since2022']['annualizedReturn']*100,legacy=False,
               review='全部23可见App目录冻结：6精选+4实验+13基础。19有数据的现有规则各一次，新增候选/调参0。共同5595日2002-09-18—2026-09-30，原生账户从自然预热日连续运行后切片；不是共同日重新入金。13基础均未超过精选最大0.996612。QUAL缺数据留待核实，不算落败；3近期实验实际持货币ETF不符合本次现金约束。价格代理、后验诊断、未正式G0-G6/OOS或完整资金结算意图认证。六精选指标数值相同，尾差与极小额新增成交保留。',
               source=str((HERE/'SUMMARY.json').relative_to(ROOT)),source_sha256=sha(HERE/'SUMMARY.json'))
    rows.append(row)
pending = {h:None for h in headers}
pending.update(key='PENDING:APP-CATALOGUE:20261008:NFCI-QUAL',name='NFCI质量增强｜现有对照待QUAL输入',kind='对照基线',
               latest=s['completed_at'],time_basis='本批真实目录及输入资格核查完成时间',
               trial_status='PENDING_INPUT_NO_CAPITAL_RUN',validation='MISSING_QUAL_SOURCE_NOT_EVALUATED',
               objective='EXISTING_COMPARATOR_NOT_NEW_CANDIDATE',comparison='NO_INFERIORITY_OR_COMPLETE_FRONTIER_CLAIM',legacy=False,
               review='目录中确有此项，但当前冻结市场响应无qual。未替换资产、未打开新数据、未计算收益；原规则收益角色拼接资格仍待核查。不得沿用旧1.532当新指标，也不得视作已被超过。',
               source=str((HERE/'prepare/contract.json').relative_to(ROOT)),source_sha256=sha(HERE/'prepare/contract.json'))
rows.append(pending)
audit = {h:None for h in headers}
audit.update(key='AUDIT:APP-CATALOGUE:SCOPE:20261008',name='现有App目录｜对照完整性与现金约束审计',kind='独立审计',
             latest=a['audited_at'],time_basis='保存资金账目/指标/真实报价日期审计完成时间',
             trial_status='PASS_19_SAVED_COMPARATORS_QUAL_PENDING',validation=a['status'],
             objective='USER_SINGLE_INDICATOR_OBJECTIVE_UNPROVEN',comparison='13_BASIC_DO_NOT_RAISE_CURATED_MAX; QUAL_PENDING',legacy=False,
             review=s['conclusion']+' 118259资金日/17922成交/152指标组通过；两次审计阅读假设失败均保留且未重跑账户。三条旧近期实验的六个账户货币ETF实际持仓证据保留，历史业绩不覆写。',
             source=str((HERE/'SAVED_AUDIT.json').relative_to(ROOT)),source_sha256=sha(HERE/'SAVED_AUDIT.json'))
rows.append(audit)
assert len(rows) == 21 and not {r['key'] for r in rows}&{r['key'] for r in old}
backup = HERE/'master-before'; backup.mkdir()
for p,b in before.items():
    (backup/(p.name+'.gz')).write_bytes(gzip.compress(b,mtime=0))
    assert p.read_bytes() == b
doc['rows'].extend(rows)
cash = read(HERE/'EXPERIMENTAL_CASH_AUDIT.json')
added_overrides = []
for r in cash['accounts']:
    if r['key'] in old_overrides: continue
    assert r['key'] in {row['key'] for row in old} and r['positive_money_fund_holding_states'] > 0
    doc['audit_overrides'][r['key']] = {
        'status':'EXCLUDED_CURRENT_USER_DEMAND_DEPOSIT_CONSTRAINT',
        'exclude_from_current_strategy_comparisons':True,
        'reason':'Saved account actually holds money511990_cny. Current research restricts all strategy cash to CashYieldCNY demand deposits; no intrinsic invalidity or universal leverage allegation.',
        'audit_key':audit['key'],'source':str((HERE/'EXPERIMENTAL_CASH_AUDIT.json').relative_to(ROOT)),
        'source_sha256':sha(HERE/'EXPERIMENTAL_CASH_AUDIT.json'),
        'historical_row_preserved':True,'original_metrics_preserved':True,
        'latest_audit_date':a['audited_at']}
    added_overrides.append(r['key'])
assert len(added_overrides) == 4
buf = io.StringIO(newline='')
writer = csv.DictWriter(buf,fieldnames=headers,lineterminator='\r\n' if b'\r\n' in before[paths[1]] else '\n')
writer.writerows(rows)
csv_data = before[paths[1]]+buf.getvalue().encode()
pending_keys = list(dict.fromkeys(target['pending_keys']+[r['key'] for r in rows]))
summary = doc['summary']
summary.update(rows=len(doc['rows']),by_kind=dict(collections.Counter(r['kind'] for r in doc['rows'])),
               latest_research_time_known=sum(bool(r.get('latest')) for r in doc['rows']),
               numeric_primary_metric_rows=sum(r.get('sharpe') is not None for r in doc['rows']),
               notion_pending_keys=pending_keys,last_local_update=a['audited_at'],
               last_update_note='Full23 App catalogue scope:19 existing controls and1QUAL pending + audit; previous313 rows and9 overrides unchanged,4 proven money-fund exclusions appended. No new alpha or complete frontier claim. Notion query entitlement pending.')
summary['active_audit_override_keys'] = list(doc['audit_overrides'])
target.update(row_count=len(doc['rows']),pending_keys=pending_keys,
              pending_local_csv_sha256=hashlib.sha256(csv_data).hexdigest(),last_local_update=a['audited_at'])
target['pending_audit_override_keys'] = list(dict.fromkeys(target.get('pending_audit_override_keys',[])+added_overrides))
write(paths[0],doc);paths[1].write_bytes(csv_data);write(paths[2],target);write(paths[3],summary)
assert read(paths[0])['rows'][:-21] == old
assert all(read(paths[0])['audit_overrides'][k] == v for k,v in old_overrides.items())
assert paths[1].read_bytes().startswith(before[paths[1]])
write(HERE/'MASTER_ROWS.json',rows)
write(HERE/'MASTER_RECEIPT.json',{'status':'LOCAL_APPEND_VERIFIED_NOTION_QUERY_ENTITLEMENT_PENDING',
      'previous_rows_unchanged':313,'previous_overrides_unchanged':9,'new_rows':21,'total_rows':334,
      'new_cash_constraint_overrides':added_overrides,'pending_keys_retained':len(target['pending_keys'])-21,
      'total_pending_keys':len(pending_keys),'remote_new_pages_created':0,
      'master_before_sha256':{p.name:hashlib.sha256(b).hexdigest() for p,b in before.items()}})
print(json.dumps({'old_rows_unchanged':313,'new_rows':21,'total_rows':334,'pending_keys':len(pending_keys),'new_cash_overrides':len(added_overrides)}))
