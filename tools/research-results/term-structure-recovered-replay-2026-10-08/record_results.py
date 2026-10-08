"""Append all twelve fixed accounts and audit; preserve existing table objects."""
from pathlib import Path
import collections,csv,gzip,hashlib,io,json
HERE=Path(__file__).resolve().parent;MASTER=HERE.parent/'strategy-master';ROOT=HERE.parents[4]
def read(p):return json.loads(p.read_bytes())
def write(p,o):p.write_text(json.dumps(o,ensure_ascii=False,indent=2)+'\n')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
s=read(HERE/'SUMMARY.json');a=read(HERE/'SAVED_AUDIT.json');assert a['status'].startswith('PASS')
paths=[MASTER/n for n in ['strategy-master.json','strategy-master.csv','notion-target.json','validation-report.json']]
before={p:p.read_bytes() for p in paths};doc=read(paths[0]);target=read(paths[2]);old=doc['rows'][:]
headers=next(csv.reader(io.StringIO(before[paths[1]].decode('utf-8-sig'))));rows=[]
names={'defensive_gold':'期限倒挂转黄金','panic_premium':'期限倒挂买纳指','defensive_cash':'期限倒挂现金对照','reverse_rotation':'期限反向金纳对照','nasdaq':'纳指持续持有对照','product':'原样金纳杠铃对照'}
for item in s['rows']:
 v,cost=item['id'].split(':');candidate=v in ['defensive_gold','panic_premium'];slip=float(cost[4:]);m=item['slices']['full_2008'];row={h:None for h in headers}
 row.update(key='POSTHOC:TERM-RECOVERED:20261008:'+item['id'].upper(),name=names[v]+'｜2008完整恢复｜滑点'+str(slip)+'%',kind='回溯筛选' if candidate else '对照基线',cagr=m['annualizedReturn']*100,mdd=m['maxDrawdown']*100,sharpe=m['sharpeRF0'],latest=s['completed_at'],time_basis='共享Swift原家族实际资金回放完成时间',trial_status='POSTHOC_EXISTING_FAMILY_SOURCE_RECOVERY_CURRENT_SHARED_ENGINE',validation='SAVED_LEDGER_AND_TARGET_PASS_NOT_FORMAL_PIT_OOS_PENDING',objective='FAIL_FULL_RF0_VS_ORIGINAL_PRODUCT_AND_OLD_JOINT_TARGET' if candidate else 'CONTROL_NOT_CANDIDATE',comparison='FAIL_ORIGINAL_PRODUCT_REPLACEMENT_REQUIREMENTS' if candidate else 'ORIGINAL_PREDECLARED_CONTROL',backtest_start='2008-01-01',backtest_end='2026-09-04',fee=.025,slip=slip,since2020=item['slices']['since2020']['annualizedReturn']*100,since2022=item['slices']['since2022']['annualizedReturn']*100,legacy=False,review='原两候选/四对照×两场景全部保留；唯一VIX/VIX3M自然阈值1，严格共同实测/双日期滞后/7日过期，2008窗口与2026-09-04终点固定。只按原源补充契约恢复451条前缀，零调参、零新机制。55872资金日/2636成交/72指标组及23280信号独立回读；9项信号/共享结算测试通过；目标接受无错配、持仓空缺最长1日。旧DATA_BLOCKED/2010错版与修正结果不变，不把defensive_cash对照改名候选。原生App价格代理，无当年PIT/完整六策略总回报前沿/未触碰OOS/正式G0-G6认证。',source=str((HERE/'SUMMARY.json').relative_to(ROOT)),source_sha256=sha(HERE/'SUMMARY.json'))
 rows.append(row)
row={h:None for h in headers};row.update(key='AUDIT:TERM-RECOVERED:2008:20261008',name='期限结构｜2008完整回放及失败判定审计',kind='独立审计',latest=a['audited_at'],time_basis='真实资金与冻结计划独立回读完成时间',trial_status='PASS_SAVED_EXECUTION_WITH_BOTH_CANDIDATE_OBJECTIVES_FAILED',validation=a['status'],objective='ORIGINAL_TWO_CANDIDATES_FAIL_USER_FULL_RF0_OBJECTIVE',comparison='BOTH_LOWER_THAN_ORIGINAL_PRODUCT_COMPLETE_FRONTIER_NOT_CERTIFIED',legacy=False,review=s['conclusion'],source=str((HERE/'SAVED_AUDIT.json').relative_to(ROOT)),source_sha256=sha(HERE/'SAVED_AUDIT.json'));rows.append(row)
assert len(old)==300 and len(rows)==13
assert not ({r['key'] for r in rows}&{r['key'] for r in old})
backup=HERE/'master-before';backup.mkdir()
for p,b in before.items():(backup/(p.name+'.gz')).write_bytes(gzip.compress(b,mtime=0));assert p.read_bytes()==b
doc['rows'].extend(rows);pending=list(dict.fromkeys(target['pending_keys']+[r['key'] for r in rows]))
buf=io.StringIO(newline='');writer=csv.DictWriter(buf,fieldnames=headers,lineterminator='\r\n' if b'\r\n' in before[paths[1]] else '\n');writer.writerows(rows)
csv_bytes=before[paths[1]]+buf.getvalue().encode();csv_sha=hashlib.sha256(csv_bytes).hexdigest()
doc['summary'].update(rows=len(doc['rows']),by_kind=dict(collections.Counter(r['kind'] for r in doc['rows'])),latest_research_time_known=sum(bool(r.get('latest')) for r in doc['rows']),numeric_primary_metric_rows=sum(r.get('sharpe') is not None for r in doc['rows']),notion_status='LOCAL_RESULTS_PENDING_QUERY_ENTITLEMENT',notion_pending_keys=pending,last_local_update=s['completed_at'],last_update_note='Original recovered2008 family: all12 accounts and audit appended; two candidates fail original product fullRf0. Previous300 unchanged. Notion unique query previously exhausted; no unqueried new pages.')
target.update(row_count=len(doc['rows']),status='LOCAL_RESULTS_PENDING_QUERY_ENTITLEMENT',pending_keys=pending,pending_local_csv_sha256=csv_sha,last_local_update=s['completed_at'])
write(paths[0],doc);paths[1].write_bytes(csv_bytes);write(paths[2],target);write(paths[3],doc['summary']);assert read(paths[0])['rows'][:-13]==old
write(HERE/'MASTER_ROWS.json',rows);write(HERE/'MASTER_RECEIPT.json',{'status':'LOCAL_APPEND_VERIFIED_NOTION_QUERY_ENTITLEMENT_PENDING','previous_rows_unchanged':300,'new_rows':13,'total_rows':313,'prior_pending_keys_retained':len(pending)-13,'pending_keys':pending,'remote_new_pages_created':0});print(json.dumps({'old_rows_unchanged':300,'local_rows':313,'notion_pending':len(pending)}))
