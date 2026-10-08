"""Append explicit ETF controls and comparison audit, retaining all prior rows."""
from pathlib import Path
import collections, csv, gzip, hashlib, io, json
HERE=Path(__file__).resolve().parent;MASTER=HERE.parent/'strategy-master';ROOT=HERE.parents[4]
def read(p):return json.loads(p.read_bytes())
def write(p,o):p.write_text(json.dumps(o,ensure_ascii=False,indent=2)+'\n')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
summary=read(HERE/'SUMMARY.json');audit=read(HERE/'SAVED_AUDIT.json');assert audit['status'].startswith('PASS')
paths=[MASTER/n for n in ['strategy-master.json','strategy-master.csv','notion-target.json','validation-report.json']]
before={p:p.read_bytes() for p in paths};doc=read(paths[0]);target=read(paths[2]);old=doc['rows'][:]
headers=next(csv.reader(io.StringIO(before[paths[1]].decode('utf-8-sig'))));rows=[]
for item in summary['benchmarks']:
 tax=item['id'].split(':')[1];full=item['slices']['full'];row={h:None for h in headers}
 row.update(key='POSTHOC:BARBELL:ETF-ADAPTATION:20261008:'+tax.upper(),name='双趋势杠铃｜GLD／QQQ明确适配｜'+('毛分红' if tax=='gross' else '统一扣缴30%'),kind='对照基线',
  cagr=full['annualizedReturn']*100,mdd=full['maxDrawdown']*100,sharpe=full['sharpeRF0'],latest=summary['completed_at'],time_basis='共享Swift串行资金回放完成时间',
  trial_status='POSTHOC_ETF_BENCHMARK_ADAPTATION_NOT_PRODUCT_PARITY',validation='SAVED_PROPOSALS_FILLS_CASH_CLAIMS_METRICS_PASS_FORMAL_UNCERTIFIED',objective='CONTROL_NOT_NEW_ECONOMIC_CANDIDATE',comparison='ONLY_EXPLICIT_ETF_ADAPTATION_COMPLETE_ORIGINAL_FRONTIER_PENDING',backtest_start='2008-03-03',backtest_end='2026-10-02',fee=.025,slip=0,since2020=item['slices']['since2020']['annualizedReturn']*100,since2022=item['slices']['since2022']['annualizedReturn']*100,legacy=False,
  review='原黄金／纳斯达克价格代理替换为GLD／QQQ，严格标识为已有冻结杠铃规则的ETF对照；不是原产品等价或新策略。与压力候选4677个资金日期、QQQ原始报价/汇率/发行人分红/费用一致，严格T−1信号、下一联合开盘、63日完成时钟及0.10带。所有分段保留，零调参。45项针对性测试通过；整套旧基准差异在修改前后逐行一致；并发测试信号10根因仍待查。不作全套测试、PIT、OOS或G0—G6通过声明。',source=str((HERE/'SUMMARY.json').relative_to(ROOT)),source_sha256=sha(HERE/'SUMMARY.json'))
 rows.append(row)
row={h:None for h in headers};row.update(key='AUDIT:STRESS-VS-BARBELL:ETF:20261008',name='压力候选 vs 金纳杠铃｜ETF匹配资金对照',kind='独立审计',latest=audit['audited_at'],time_basis='真实资金结果与既有候选结果独立回读时间',trial_status='POSTHOC_EXPLICIT_BENCHMARK_ADAPTATION_COMPARISON',validation=audit['status'],objective='ORIGINAL_STRONGEST_FRONTIER_AND_SINGLE_PRICE_INDICATOR_SCOPE_UNPROVEN',comparison=summary['full_comparison_status'],legacy=False,review=summary['conclusion'],source=str((HERE/'SAVED_AUDIT.json').relative_to(ROOT)),source_sha256=sha(HERE/'SAVED_AUDIT.json'));rows.append(row)
assert len(old)==297 and len(rows)==3
assert not ({r['key'] for r in rows}&{r['key'] for r in old})
backup=HERE/'master-before';backup.mkdir()
for p,data in before.items():
 (backup/(p.name+'.gz')).write_bytes(gzip.compress(data,mtime=0));assert p.read_bytes()==data
doc['rows'].extend(rows);pending=list(dict.fromkeys(target['pending_keys']+[r['key'] for r in rows]))
buf=io.StringIO(newline='');writer=csv.DictWriter(buf,fieldnames=headers,lineterminator='\r\n' if b'\r\n' in before[paths[1]] else '\n');writer.writerows(rows)
csv_bytes=before[paths[1]]+buf.getvalue().encode();csv_sha=hashlib.sha256(csv_bytes).hexdigest()
doc['summary'].update(rows=len(doc['rows']),by_kind=dict(collections.Counter(r['kind'] for r in doc['rows'])),latest_research_time_known=sum(bool(r.get('latest')) for r in doc['rows']),numeric_primary_metric_rows=sum(r.get('sharpe') is not None for r in doc['rows']),notion_status='LOCAL_RESULTS_PENDING_QUERY_ENTITLEMENT',notion_pending_keys=pending,last_local_update=summary['completed_at'],last_update_note='Three explicit ETF benchmark/audit rows appended; previous297 unchanged; original product frontier not certified. Notion unique-query entitlement previously exhausted; no unqueried page creations.')
target.update(row_count=len(doc['rows']),status='LOCAL_RESULTS_PENDING_QUERY_ENTITLEMENT',pending_keys=pending,pending_local_csv_sha256=csv_sha,last_local_update=summary['completed_at'])
write(paths[0],doc);paths[1].write_bytes(csv_bytes);write(paths[2],target);write(paths[3],doc['summary']);assert read(paths[0])['rows'][:-3]==old
write(HERE/'MASTER_ROWS.json',rows);write(HERE/'MASTER_RECEIPT.json',{'status':'LOCAL_APPEND_VERIFIED_NOTION_QUERY_ENTITLEMENT_PENDING','previous_rows_unchanged':len(old),'new_rows':3,'total_rows':len(doc['rows']),'prior_pending_keys_retained':len(target['pending_keys'])-3,'pending_keys':pending,'remote_new_pages_created':0});print(json.dumps({'old_rows_unchanged':len(old),'local_rows':len(doc['rows']),'notion_pending':len(pending)}))
