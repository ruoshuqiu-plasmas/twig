# ADR-001：ACP 客户端实现路径

> 状态：**已决定**（2026-07-31，DEC-01 关闭）
> 决策人：用户（依据 `spike/g0-findings.md` §7 证据）

## 结论

采用社区 Swift SDK **`rebornix/acp-swift-sdk`**（SPM 依赖）。**PoC 已于任务 07（2026-07-31）通过**：ADR §依据所列四个 schema 核对点（`tool_call_update` 稀疏字段容忍、`configOptions[]`、`sessionCapabilities{list,resume}`、`agent_thought_chunk`）全部满足，fixtures 取自 G0 脱敏样本离线解码（`swift run schema-poc`）。

**锁定方式**：上游尚无 release tag（仅 main 分支），按 commit **`b800b3f2c251e3453fdd10172d671123e1908301`**（2026-07-31 main HEAD）锁定于 Package.swift / Package.resolved；待上游发布 1.0.0 后转 `from:` 语义版本，升级时须重跑 schema PoC。

**已知缺口**（不阻塞，适配层自行扩展即可）：

- kimi 扩展字段 `configOptions[]`（session/new 响应中的模型/思考档位选项）未在 SDK `SessionNew.Result` 建模，解码时静默丢弃；
- `tool_call_update` 线上条目偶含 `rawInput` 字段，SDK 未建模（同样静默丢弃，不影响解码）。

## 依据

- **协议覆盖**：客户端向稳定方法齐备（`Initialize`/`SessionNew`/`SessionLoad`/`SessionPrompt`/`SessionCancel`/`SessionSetMode`），draft 区含 `SessionList`/`SessionResume`/`SessionFork`（均为 kimi 0.31.0 实测支持的方法）；通知与 permission 回调有类型化入口；stdio transport 内置。
- **版本匹配**：kimi 0.31.0 讲 ACP v1（`protocolVersion=1`，agent 侧 @agentclientprotocol/sdk@0.23.0）。PoC 必须验证的点：`tool_call_update` 稀疏字段容忍、`configOptions[]` 解码、`sessionCapabilities{list,resume}`、`agent_thought_chunk` 事件。
- **构建复杂度**：纯 Swift 6 + SPM，无外部工具链；显著优于 FFI 路径。
- **错误可观测性**：Swift 6 严格并发 + 类型化解码，解码/协议错误可集中在适配层处理；G0 脱敏样本（`spike/samples/sanitized/`）可直接转为回归 fixtures。

## 被否决方案

| 方案 | 否决原因 |
|---|---|
| 官方 Swift SDK | 不存在。官方 SDK 仅 Rust 与 TypeScript（均已 1.0） |
| Rust SDK + FFI | 官方 1.0 最权威，但 ACP over stdio 协议面窄（握手/session/prompt/通知/permission 五类消息，探针 400 行 Python 全覆盖），FFI 的构建链、跨语言错误映射与调试成本相对收益不成比例，且排期 +1~2 日 |
| 手写 NDJSON transport | 可行且简单，但需自行维护全部类型并长期跟进协议演进；列为第一回退方案 |
| `wiedymi/swift-acp` | 有真实应用（Aizen）背书、macOS 12+、自带 fs/terminal delegate；维护规模弱于首选，列第二备选 |
| `aptove/swift-sdk` | 标称协议版本为旧日期制（2025-02-07），维护活跃度不明，排除 |

## 兼容版本（锁定基线）

| 组件 | 版本 |
|---|---|
| Kimi Code CLI | **0.31.0**（G0 锁定基线）；**0.31.1** 已于 M4/RC 实测通过（`session/load` 两处行为差异由客户端 `TwigSessionLoad` 吸收，见矩阵第三行与 `spike/g0-findings.md` §2 补记） |
| ACP 协议 | **v1**（`protocolVersion=1`） |
| agent 侧协议栈 | @agentclientprotocol/sdk@0.23.0（kimi 内置） |
| 客户端 SDK | rebornix/acp-swift-sdk @ commit `b800b3f`（上游无 release tag，PoC 通过后锁定，2026-07-31） |

## 回退触发条件

1. PoC 发现 SDK schema 与 kimi ACP v1 不兼容、且上游短期不响应 → 转手写 NDJSON transport；
2. SDK 停止维护或出现阻塞性 bug → 手写 transport；
3. ACP v2 定型且 CLI 升级支持 → 重新评估三家社区 SDK 与手写成本；
4. 手写路径亦无法跟进协议演进 → 最后手段才启用 Rust FFI（触发时重开 DEC-02，排期 +1~2 日）。

## 附：协议兼容矩阵（随 CLI 升级维护，模板来自开发流程 §9.1）

| App 版本 | Kimi Code CLI | ACP/Agent 侧 SDK | 握手 | session | stream | permission | resume | 结论 |
|---|---|---|---|---|---|---|---|---|
| g0-spike（Python 探针） | 0.31.0 | ACP v1 / sdk@0.23.0 | ✓（含版本回落） | ✓（new/load/resume/list） | ✓（thought+message chunk） | ✓（edit/execute 可拒，read 免审批） | ✓（load 异步重放） | 通过 2026-07-31 |
| m1-007-poc（acp-swift-sdk @ b800b3f，离线解码脱敏样本） | 0.31.0（样本来源） | ACP v1 / sdk@0.23.0 | ✓（sessionCapabilities{list,resume} 可解码） | ✓（sessionId；configOptions 未建模为已知缺口） | ✓（thought chunk；tool_call_update 稀疏字段容忍） | 未测（待 M2-005 真实链路） | 未测（待 M4-010） | 通过 2026-07-31 |
| twig rc-1（acp-swift-sdk @ b800b3f + 自定义 TwigSessionLoad） | **0.31.1** | ACP v1 / sdk@0.23.0 | ✓ | ✓（new/load/list；load 经 TwigSessionLoad 绕过 0.31.1 两处不兼容：`mcpServers` 必填、成功响应无 `sessionId`） | ✓ | ✓（写/终端 default deny 真实拒绝，文件未落盘） | ✓（load 异步重放续接成功；不可用明确降级新建） | 通过 2026-08-02（证据 `doc/RC-验收报告.md` §三） |
