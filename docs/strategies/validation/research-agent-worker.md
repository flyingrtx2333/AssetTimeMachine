# Research Agent 隔离执行 Worker

研究 Agent 现在分为两个本地 Worker，使用两个互不复用的最小权限 API Key：

- `research_preparation_worker.py`：领取已冻结计划，调用 Codex CLI 在独立 worktree 中准备代码、测试、数据清单和 preregistration；禁止正式回测。
- `research_agent_worker.py`：只在站长人工授权后，执行已经绑定 commit 和 SHA-256 的正式实验。

## AI 代码准备 Worker

在 API 密钥管理页创建只包含 `research:prepare` 的密钥，并通过环境变量提供：

```bash
export FLYINGRTX_RESEARCH_PREPARATION_TOKEN='创建时显示的密钥'
python3 scripts/research_preparation_worker.py --once
```

默认准备模型由服务端配置：

```text
RESEARCH_PREPARATION_PROVIDER=codex-cli
RESEARCH_PREPARATION_MODEL=gpt-5.6-sol
RESEARCH_PREPARATION_REASONING=high
```

Worker 使用当前 Mac 已登录的 Codex CLI，固定启用 `--ephemeral` 和 `workspace-write` 沙箱，不使用危险的 sandbox bypass。启动 Codex 子进程前还会剔除业务 Token、API Key、密码和私钥类环境变量。Codex 必须提交全部准备内容并留下干净 worktree；Worker 随后独立调用 `strategy_validation_run_guard.py`，确认该 trial 只有已提交的 `PREREGISTER`、没有 `RESULT`，候选集合与服务端冻结计划完全一致，才把 commit、分支和文件哈希回传到管理台。

准备完成只会把任务推进到“证据已绑定”。站长仍需在管理台检查后点击“授权正式执行”，正式执行 Worker 才能领取任务。

该 Worker 只执行 Flyingrtx 管理台中已经完成以下步骤的研究任务：

1. 研究计划已冻结；
2. ATM-SVP-2 preregistration、数据清单和正式入口代码已经提交；
3. Git commit、文件 SHA-256 和仓库相对路径已经绑定；
4. 站长已点击“授权正式执行”。

Worker 不接受 shell 字符串。服务端合同只能指定 `scripts/` 下的 Python 入口，Worker 会在目标 Git commit 的独立 worktree 中通过 `strategy_validation_formal_run.py` 执行它。
Worker 会为入口统一注入 `--output-dir tools/research-results/strategy-validation/runs/<trial_id>/candidates`，入口必须把候选与控制组的中间产物写入该受控目录。

## 创建专用 API Key

在 Flyingrtx API 密钥管理页创建一个只包含以下权限的密钥：

```text
research:execute
```

不要复用因子导入密钥，也不要把密钥写入仓库。Worker 仅从环境变量读取：

```bash
export FLYINGRTX_RESEARCH_WORKER_TOKEN='创建时显示的密钥'
```

## 单次检查

```bash
python3 scripts/research_agent_worker.py --once
```

本地后端联调：

```bash
python3 scripts/research_agent_worker.py \
  --base-url http://127.0.0.1:59888 \
  --once
```

持续运行时去掉 `--once`。默认状态目录位于独立研究工作区：

```text
../FlyingrtxFast/research/asset-time-machine/workspace/agent/
```

准备 Worker 使用 `agent/preparation/`，正式执行 Worker 使用 `agent/execution/`。其中保存：

- 按 authorization SHA 隔离的 Git worktree；
- Worker 自身 stdout/stderr；
- API 暂时不可用时的待回传结果。

待回传文件权限为 `0600`，成功收到服务端确认后立即删除。API Key 不会写入状态目录或研究产物。
可通过 `ASSET_TIME_MACHINE_RESEARCH_WORKSPACE` 迁移整个研究工作区，或分别使用
`FLYINGRTX_RESEARCH_PREPARATION_STATE`、`FLYINGRTX_RESEARCH_WORKER_STATE` 覆盖两个 Worker 的状态目录。

## 正式入口输出合同

冻结的 runner spec 必须声明：

- `trial_id`
- `entrypoint`
- `arguments`
- `dataset_manifest_path`
- `result_path`
- `strategy_manifest_path`

入口必须生成 `result_path` 和 `strategy_manifest_path`。策略清单使用 `strategy-library-v1` 或 `strategy-library-v2`，必须覆盖全部冻结候选；额外结果只能标记为 `CONTROL`。PASS、FAIL、INVALID、ABORTED 都会进入策略库，避免幸存者偏差。

绑定证据前可用以下命令取得管理台需要的两个文件哈希：

```bash
shasum -a 256 scripts/<正式入口>.py
shasum -a 256 tools/research-results/<数据清单>.json
```

`execution_commit` 必须是包含 preregistration、数据清单、入口及其 Swift 依赖的干净 Git commit。虽然入口文件另有 SHA 校验，完整代码身份最终仍由该 commit 固定。

## 故障语义

- Worker 每 30 秒续租；租约 15 分钟。
- 租约过期后任务最多被其他 Worker 重领 3 次。
- 正式执行成功但回传网络失败时，Worker 先落本地 spool，不会重新运行正式实验。
- 连续租约耗尽或入口失败后任务进入 `failed`，可在管理台人工检查后重新授权。
