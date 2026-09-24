# ATM-SVP-3 提案：研究产物迁出 App 开发仓库

状态：**提案（未正式冻结）；P1 已执行**
提出日期：2026-09-24
修订：2026-09-24 —— 迁移目标由「研究工坊」改为 **FlyingrtxFast**（用户决策）
修订：2026-09-24 —— 订正 §3.1 实测数字；记录 §7.1 P1 执行结果
影响协议：`ATM-SVP-2`（由 `tools/research-results/strategy-validation/protocol-freeze-v2.json` 冻结）

> **治理状态说明**：用户于 2026-09-24 决定**跳过 P0**（不写 `protocol-freeze-v3.json`）
> 直接执行 P1。因此本文件在形式上仍是**未冻结的提案**，而 P1 已落地。
> P2–P5 执行前应先补齐 P0，或由用户再次明确豁免。

---

## 1. 决策

将 `tools/research-results/` 下的全部研究产物迁出 App 开发仓库，迁入 **FlyingrtxFast**
（`/Users/xiangjunsheng/FlyingrtxFast`）。App 仓库只保留治理协议文档与一份**产物索引**
（路径 → SHA-256 → FlyingrtxFast commit）。

现状是写进 `AGENTS.md` 的规则：

> Formal ATM-SVP artifacts and executable code remain committed in this repository before a formal run.
>
> 正式 ATM-SVP 的 preregistration、数据清单、结果和 Git 提交仍必须保留在本仓库的 `tools/research-results/strategy-validation/`，以维持可复现和审计边界。

本提案主张：该规则**达成目的的手段可以更换**。可复现与可审计需要的是「代码版本 + 冻结候选集 + 结果」三者的**可验证绑定**，而不是三者物理同库。绑定方式改为跨仓库 pinned commit + SHA-256 清单，同样可验证。

因为改动归档政策属于治理变更，按 `AGENTS.md` 规定：

> Never edit either frozen protocol document/policy in place. A further governance change requires ATM-SVP-3.

故立本提案。**在提案被正式采纳并冻结之前，不执行任何迁移动作。**

> ⚠️ 上述约束**已被用户于 2026-09-24 明确豁免**：用户选择跳过 P0 直接执行 P1。
> 迁移已实际发生，本文件因此同时是「提案」与「执行记录」。详见 §7.1。

---

## 2. 为什么选 FlyingrtxFast

| 理由 | 依据 |
|---|---|
| 线上回测引擎在此 | `contracts/public-backtest-v1/`（`catalog.json`、`queued.json`、`succeeded.json`） |
| 研究产物在此被消费 | `backend/services/asset_time_machine_service.py`、`backend/api/v1/` 下的 `internal/factor-imports`、`internal/strategy-imports` |
| 研究执行环境在此 | `backend/docker-compose.research-agent.yml`、`backend/research/` |
| **有远端，可备份** | `origin  git@github.com:flyingrtx2333/FlyingrtxFast.git` |
| ATM 后端已在此 | `backend/models/asset_time_machine.py`、`backend/db/ModuleAssetTimeMachine*.sql`、`docs/asset-time-machine/` |

关键优势：**有 GitHub 远端**。迁入后产物即获得异地备份，解决「无远端 = 单副本」的暴露。
（对比：研究工坊 `AssetTimeMachineResearch` 未初始化 git、无远端，且总体 4.6 GB，
其中 `strategies/sec-13f-etf-crowding-reversal-001` 单个目录就 2.8 GB 的 SEC 13F 原始 zip，
`studies/` 1.5 GB —— 大部分是可重新下载的原始数据，不适合整体纳入版本控制。）

---

## 3. 现状事实

### 3.1 待迁出内容（App 仓库）

2026-09-24 实测：

| 项 | 数值 |
|---|---|
| `tools/research-results/` 被跟踪文件 | **432 个 / 153.1 MiB** |
| `tools/fixtures/` 被跟踪文件 | **19 个 / 21.5 MiB** |
| 被跟踪合计 | **451 个 / 174.6 MiB** |
| 被 `.gitignore` 刻意排除的本地 scratch | **2292 个 / ~11.7 MiB** |
| 最大单文件 | `strategy-validation/preregistrations/RS-RANGE-BREADTH-21-252-001-schedule.json` — **103.67 MiB**（108,707,228 B） |
| 第二 | `strategy-validation/preregistrations/IDB-63-21-schedule.json` — **18.64 MiB**（19,550,148 B） |
| App 仓库 `.git` pack | **597 MB** |

> 本提案初稿曾记作「166 MB / 432 个 / 未跟踪 0 个」——那是 `du -sh` 的磁盘占用（含块对齐），
> 且完全漏记了被忽略的 scratch。上表为订正后的实测值。

scratch 的排除规则来自 App 仓库 `.gitignore`：`tools/research-results/nfci-*-vintages/`、
`tools/research-results/.*`、全局 `__pycache__/`，注释标明为 "Quant research caches /
scratch fragments"。

`preregistrations/` 单目录 122.3 MiB——预注册 JSON 内嵌**完整候选参数网格**（G3 规则要求
每个正式尝试都计数，整张网格必须冻结）。两个 schedule 占全部被跟踪内容的 **69%**。

真正的结论性记录极小：`results/` 108 KB（14 文件）、`datasets/` 80 KB（17 文件）、
`holdouts/` 28 KB（6 文件）、`g4-holdout-invalid/` 8 KB（2 文件）。

### 3.1.1 冻结哈希绑定（迁移前必须知悉）

两个 schedule 的**字节 sha256 被 `trial-ledger.jsonl` 的 `PREREGISTER` 记录永久钉死**：

| 文件 | 台账钉死的 sha256 |
|---|---|
| `RS-RANGE-BREADTH-21-252-001-schedule.json` | `e72607b06df0be5be2fcd381ab98b059536a273e64f755b46cde637552ab0f8a` |
| `IDB-63-21-schedule.json` | `82ba981988d537ee38cd304e122183b4869382050777461e56c03501deb43083` |

`trial-ledger.jsonl` 是哈希链式 append-only（`previous_hash` → `record_hash`），因此这两个
哈希**不可更改**。任何改变文件字节的处理（包括压缩）都必须保证「解压后内容哈希不变」。
`tools/fixtures/backtest-history/public_history.json`（`35bcfc9a…`）等 fixture 同样被台账引用，
**不得压缩**。


### 3.2 迁入目标（FlyingrtxFast）

| 项 | 数值 |
|---|---|
| 仓库体积 | 3.2 GB，`.git` 282 MB |
| 分支 | `main`；迁入前最新 `3fe0e91`，P1 提交后为 `b98e0b8` |
| 现有研究目录 | `backend/research/`（17 MB，目前为 astrology 研究） |
| 现有 ATM 后端 | `backend/models|services|schemas/asset_time_machine.py`、`backend/db/ModuleAssetTimeMachine*.sql` |
| `.gitignore` | 已排除 `.venv*/`、`__pycache__/`、`example`、`dist`、`/evidence/`、`/output/`、`node_modules`、**`*.log`**（P1 已为其加反排除，见 §7.1） |

**已决**：产物落在**新增顶层 `research/asset-time-machine/`**（用户决策，P1 已按此执行）。

---

## 4. 压缩机会（独立于迁移，建议一并评估）

两个巨型预注册 JSON 的压缩率极高。实测 `RS-RANGE-BREADTH-21-252-001-schedule.json` 前 8 MB 样本：

| 处理 | 大小 | 相对原始 |
|---|---|---|
| 原始 | 7.6 MB | 1× |
| gzip -6 | 843 KB | 9.0× |
| **xz -6** | **87 KB** | **87×** |

按此比例外推，2026-09-24 实做（`xz -6 -T0`）后实测：

| 文件 | 原始 | xz 后（实测） | 比率 |
|---|---|---|---|
| `RS-RANGE-BREADTH-21-252-001-schedule.json` | 108,707,228 B | **984,060 B** | **110.5×** |
| `IDB-63-21-schedule.json` | 19,550,148 B | **578,004 B** | **33.8×** |

两个文件解压后 sha256 与 §3.1.1 的台账钉死值**逐字节一致**，压缩未改变冻结语义。

**入库体积实测从 174.6 MiB 降到 55.5 MiB**（含新增的 README / 清单文件；纯产物部分 53.8 MiB）。

代价：需改两处加载器（Swift `RSRangeBreadthArtifactLoader` 与 Python 侧对应读取），
且因文件字节变化，读取方须在**解压后**计算内容哈希——台账钉死值即解压后哈希，语义不变。


---

## 5. 影响面

### 5.1 Python（36 个脚本）

每个脚本各自定义 `ROOT = Path(__file__).resolve().parents[1]`（**无共享路径模块**），
再以 `ROOT / "tools/research-results/..."` 或字符串字面量拼接。

代表：`scripts/strategy_validation_ledger.py`、`strategy_validation_run_guard.py`、
`strategy_validation_formal_run.py`、`strategy_validation_artifact_manifest.py`、
`publish_factor_library_manifest.py`、`publish_strategy_library_manifest.py`、
`research_agent_worker.py`、`research_preparation_worker.py`、
`validate_strategy_protocol.py`、`build_recent_strategy_library_manifests.py`，
以及 `tools/research-results/*.py`（8 个自引用脚本）。

### 5.2 Swift（4 个文件，**不影响上架包**）

- `AssetTimeMachine/Backtest/RSRangeBreadthFormalSupport.swift`
- `AssetTimeMachine/Backtest/RSRangeBreadthFreezeSupport.swift`
- `AssetTimeMachine/Backtest/IntradayDownsideBreadthFormalSupport.swift`
- `AssetTimeMachine/Backtest/IntradayDownsideBreadthFreezeSupport.swift`

已核实：
- `AssetTimeMachine.xcodeproj/project.pbxproj` 对这 4 个文件的引用数为 **0** —— 它们**不在 App target 内**，不随 App 分发。
- 它们只属于 `Package.swift` 的 `AssetTimeMachineBacktestCore` 目标（`swiftSettings: [.define("ATM_SERVER")]`），供 4 个 SwiftPM 可执行目标使用。
- 入口已参数化：`run(arguments:)` 接收 `--repo-root <path>`，只有内部相对路径是硬编码的。

### 5.3 文档（13 份）

`AGENTS.md`、`README.md`、`tools/research-results/strategy-validation/README.md`、
`docs/strategies/validation/research-agent-worker.md`、
`docs/superpowers/plans/*.md`（7 份）、`docs/superpowers/specs/*.md`（1 份）、
`tools/research-results/*.md`（2 份）。

### 5.4 附带发现

`FlyingrtxFast/AGENTS.md:12` 也含一条失效路径：

> The related Asset Time Machine app lives outside this repo at `/Users/xiangjunsheng/Desktop/Allprojects/AssetTimeMachine`.

实际位置是 `/Users/xiangjunsheng/AssetTimeMachine`。迁移时一并修正。

---

## 6. 目标架构

**P1 实际落地形态**（2026-09-24）：

```
AssetTimeMachine/                     ← App 仓库（本仓库）
├── AssetTimeMachine/                  App 源码
├── Server/                            SwiftPM 服务端/CLI
├── scripts/                           研究执行脚本（P2 改为读 ATM_RESEARCH_ROOT）
├── tools/
│   ├── fixtures/                      P3 删除
│   └── research-results/
│       ├── README.md                  P3 改为「产物已迁至 FlyingrtxFast」说明
│       └── artifact-index.json        P3 新增：路径 → SHA-256 → FlyingrtxFast commit
└── docs/strategies/validation/        治理协议文档（保留）

FlyingrtxFast/                        ← 迁移目标（有 GitHub 远端）
└── research/asset-time-machine/      ← 新增顶层（已落地）
    ├── README.md                     来源、映射、压缩、校验说明
    ├── MIGRATION-MANIFEST.json       每文件：存储/内容哈希 + 源路径 + 是否入库
    ├── MANIFEST.sha256               shasum -c 可直接校验的平铺清单
    ├── strategy-validation/          preregistrations / datasets / results / runs /
    │                                 holdouts / factor-data / g4-* / trial-ledger.jsonl
    ├── factor-library/
    ├── daily-factor-lab/
    ├── macro-vintages/
    ├── nfci-*-vintages/              本地 scratch（磁盘镜像，不入库）
    ├── <research-results 根级散件>    *.py / *.csv / *.md / *.json / *.png
    └── fixtures/                     原 tools/fixtures/（backtest-history + macro-risk）
```

> 初稿曾把目标画成 `backend/research/asset-time-machine/`，并把 fixtures 画到
> `tools/fixtures/backtest-history/`。实际采用**新增顶层 `research/asset-time-machine/`**，
> 且 fixtures 收进同一目录下，使整个迁移成为一个自包含的提交单元。

**绑定机制**：App 仓库的 `artifact-index.json` 为每个产物记录
`{path, sha256, flyingrtx_commit}`。任何 formal RESULT 记录在 App 仓库侧绑定
`flyingrtx_commit`，即可验证「哪份代码 + 哪份冻结候选集 + 哪份结果」是一组。
P1 已在目标侧提供等价的 `MIGRATION-MANIFEST.json` + `MANIFEST.sha256` 作为反向锚点。


---

## 7. 分阶段方案

| 阶段 | 动作 | 可回滚 | 状态 |
|---|---|---|---|
| **P0** | 本提案评审、采纳、冻结为 `protocol-freeze-v3.json` | — | **用户决定跳过**（2026-09-24） |
| **P1** | 在 FlyingrtxFast 建立目标目录，导入全部文件（含 `tools/fixtures/`），生成 SHA-256 清单，提交 | 是（新增，无破坏） | **✅ 已完成**（2026-09-24，commit `b98e0b8`，未推送） |
| **P2** | 改造引用：36 个 Python 脚本 + 4 个 Swift 文件改为经 `ATM_RESEARCH_ROOT` 解析，**默认回退**到 FlyingrtxFast 路径，保持双路径可读；并支持 `.xz` 解压后校验 | 是 | 待执行 |
| **P3** | 从 App 仓库删除 `tools/research-results/` 与 `tools/fixtures/`，提交 `artifact-index.json` | 是（单 commit，可 revert） | 待执行 |
| **P4** | 更新 `AGENTS.md`、`README.md`、协议文档、13 份引用文档，并修正 FlyingrtxFast 的失效路径 | 是 | 待执行 |
| **P5** | *用户已决定延后*：重写 App 仓库 git 历史，清除 597 MB pack 中的大 blob。**等 P1–P4 稳定后再做** | **否** | 延后 |

### 7.1 P1 执行记录（2026-09-24）

| 项 | 结果 |
|---|---|
| 目标 | `FlyingrtxFast/research/asset-time-machine/` |
| 提交 | `b98e0b8`，456 文件 / 1,022,522 行，**本地提交，未推送** |
| 入库文件 | 455 个 / 55.5 MiB（产物 452 + README + `MIGRATION-MANIFEST.json` + `MANIFEST.sha256`） |
| 未入库 scratch | 2291 个 / 3.0 MiB（磁盘已镜像，`.gitignore` 排除） |
| 校验 | `shasum -c MANIFEST.sha256` → 2743/2743 OK；源↔目标双向逐字节比对 → 全部一致 |
| 台账绑定 | 两个 schedule 的解压内容哈希与 `trial-ledger.jsonl` 钉死值一致 |

**路径映射**：`tools/research-results/<P>` → `research/asset-time-machine/<P>`；
`tools/fixtures/<P>` → `research/asset-time-machine/fixtures/<P>`。
冻结记录内部引用的旧路径**未改写**（哈希链约束），新旧对应关系记录在
`MIGRATION-MANIFEST.json` 的 `entries[].source_path` ↔ `entries[].path`。

**3 处有意差异**（记录于 `MIGRATION-MANIFEST.json` → `deviations_from_source`）：

1. 两个 schedule 改为 `.json.xz` 存储（内容不变）。
2. `runs/ATM-SVP2-GOR-QREG-001/formal-run.log` **新增入库**——App 仓库的全局 `*.log`
   规则误伤了它，但它是该正式运行唯一的控制台实录，且同目录其余 10 个产物均已跟踪。
   属源仓库遗漏，迁移时一并修正。
3. `runs/**/*.log` 统一入库（FlyingrtxFast `.gitignore` 显式反排除）。

> ⚠️ **未提交内容风险已消解**：源工作区当时有一处未提交改动
> （`strategy-validation/README.md` 的 12 行 V11 current-data / `POST_HOC_CURRENT_REPLAY`
> 说明），该内容不存在于 App 仓库任何提交中。P1 已按**工作区版本**迁入并提交，
> 现 FlyingrtxFast 是其唯一版本化载体。


---

## 8. 风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| **P5 使审计锚点失效** | 重写历史后 29 个分支 commit hash 全变，既有工件中记录的 App 仓库 SHA 集体失效 | P5 前导出全量 ref→新 hash 映射表存档；迁移完成的产物以 FlyingrtxFast commit 为锚点，不再依赖 App 仓库 SHA |
| **P5 不可逆** | 无备份则无法回退 | P5 前做完整仓库镜像备份（含全部 ref）并验证可克隆 |
| 审计链断裂 | 迁移后 App 仓库不再自含结果 | `artifact-index.json` 记录 SHA-256 + FlyingrtxFast commit；formal run 的 RESULT 强制写入 `flyingrtx_commit` |
| 双路径漂移 | P2 期间两处可写 | P2 只读回退，写入路径唯一；P3 后移除回退分支 |
| 生产仓库膨胀 | FlyingrtxFast 是线上后端仓库，`.git` 将从 282 MB 增长 | **实测增量 55.5 MiB**（压缩前为 174.6 MiB）；两个 schedule 从 122.3 MiB 压到 1.5 MiB |
| 目标仓库 `.gitignore` 吞掉已跟踪文件 | FlyingrtxFast 有全局 `*.log`，会静默丢弃 `runs/**/stdout.log`、`stderr.log` 等正式证据 | P1 已加显式反排除 `!research/asset-time-machine/strategy-validation/runs/**/*.log`；并以「源跟踪集 vs 目标入库集」集合比对确认无其他遗漏 |
| 清单自引用 | 生成器若扫描自身输出，会记录陈旧哈希 | 生成器显式排除 `MIGRATION-MANIFEST.json` / `MANIFEST.sha256` |
| 脚本遗漏 | 36 个脚本写法各异 | P2 完成后跑全量冒烟测试 + 校验无残留字面量 |
| 未跟踪内容遗漏 | 迁移前须确认无未提交产物 | 迁移前对两处都跑 `git status` + 未跟踪扫描；P1 已核对 2743 源文件与目标双向逐字节一致 |

---

## 9. 未决事项

1. ~~产物落在 `backend/research/asset-time-machine/` 还是新增顶层 `research/asset-time-machine/`？~~
   → **已决**：新增顶层 `research/asset-time-machine/`（P1 已按此执行）。
2. ~~是否采用 §4 的压缩方案？~~ → **已决**：采用。实测 110.5× / 33.8×，入库体积
   174.6 MiB → 55.5 MiB；台账钉死哈希逐字节复验通过。
3. ~~P5 的执行时机？~~ → **已决**：延后，等 P1–P4 稳定运行后再做。
4. `artifact-index.json` 是否需要独立校验脚本，纳入 `scripts/validate_strategy_protocol.py`？
   → **仍待定**。P1 已在 FlyingrtxFast 侧提供 `MIGRATION-MANIFEST.json` + `MANIFEST.sha256`；
   App 侧的 `artifact-index.json` 属于 P3 范围。
5. **新增**：P2 的 `.xz` 解压支持必须覆盖哪些读取方？已确认至少包括
   `RSRangeBreadthArtifactLoader`（`RSRangeBreadthFormalSupport.swift:4`）、
   `RSRangeBreadthFreezeSupport.swift:7`、`IntradayDownsideBreadthFreezeSupport.swift:9`、
   `IntradayDownsideBreadthFormalSupport.swift:261`。P2 需先做全仓字面量扫描再动手。


---

## 10. 本提案不改变的内容

- ATM-SVP-1 / ATM-SVP-2 的验证门（G0–G6）定义与判定标准
- 任何既有 trial 的生命周期状态、PASS/FAIL/INVALID 判定
- 试验台账 `trial-ledger.jsonl` 的内容与追加规则
- 1.00% 产品默认费率与 0.05% 滑点
- App 产品行为、可见指标与发布流程
