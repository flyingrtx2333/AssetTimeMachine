# 旧分支整合记录（2026-10-07）

当前日常开发和发布统一使用 `main`。

## 历史研究分支

`codex/dayk-fast-001` 的最终提交为 `67904da3df6e3f15464c6351cc5bf005861eab21`，与整合前主分支共有祖先为 `a0ef8800cf38e66ff8360f9e465bf936450e29f5`。其 135 条独立提交保留在只读标签 `archive/2026-10-07/codex-dayk-fast-001`，原提交身份和冻结记录保持原样。

与共有祖先相比的 1,725 个文件已逐项核对：377 个文件在 FlyingrtxFast 的研究归档中已有完全相同的 Git blob；另外 1,348 个历史文件版本保存在压缩归档中，解压内容的 SHA256 已逐项回读核对。

研究归档位于兄弟仓库：

`research/asset-time-machine/workspace/archive/branch-integration-2026-10-07/`

- `LEGACY_MANIFEST.json`：原路径、原 Git blob、内容 SHA256、已有文件位置或压缩归档内的位置。
- `legacy-dayk-files.tar.xz`：缺失的历史文件版本；不替换当前台账、原冻结政策或 App 源码。
- `FINAL_RECEIPT.json`：远端与本地分支清理后的核验回执。

[研究归档入口](https://github.com/flyingrtx2333/FlyingrtxFast/tree/main/research/asset-time-machine/workspace/archive/branch-integration-2026-10-07)

旧 `BacktestEngine.swift` 的研究扩展也作为原版本保留。历史复现从上述原提交或只读标签取出相应代码，继续使用其原参数、原执行语义和原证据；当前计算实现仍以共享 Package 为准。此次整合不重新计算、评价或发布任何策略。

## 已完成的源码分支

`codex/factor-library-export` 和 `codex/backtest-architecture-source-20261002` 的最终提交均已是 `main` 的祖先；清理分支引用不会移除提交。

## 恢复原研究分支

需要审计原历史时，可从标签创建临时分支：

```bash
git switch -c codex/review-legacy-dayk archive/2026-10-07/codex-dayk-fast-001
```

先保持当前工作区干净，再在单独目录中进行历史复现。不得将旧研究结果重新标记成当前产品成绩。
