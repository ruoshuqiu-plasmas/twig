# AGENTS.md · 分支对话面板

> 本文件面向 AI 编码代理。阅读者默认对项目一无所知。
> 项目文档与注释均使用**简体中文**，代理在与用户沟通和撰写文档时应保持一致。

## 1. 项目概览

「分支对话面板」是一款 **macOS 原生桌面应用**（Swift + SwiftUI），作为 **ACP（Agent Client Protocol）客户端**驱动本机的 Kimi Code CLI（`kimi acp` 子进程），消耗 Kimi Code 会员额度而非 API token 计费。

核心特色：**选中 AI 回答或工具调用结果中的任意文字，就地开启支线对话**（独立 ACP session，可嵌套、可将结论回流主线），配合左侧卡片式对话树与右侧支线标签栏。

**当前状态：Swift 骨架已落地（任务 07 完成，2026-07-31）。** 仓库含产品/流程文档、执行台账（TODO.md）、ADR-001、G0 技术验证（spike）的 Python 探针与协议样本，以及 Swift 6 + SPM 工程骨架（Package.swift + App/Features/Core/Shared 四层占位模块，acp-swift-sdk PoC 已通过）。已是 git 仓库并以 MIT 协议开源：<https://github.com/ruoshuqiu-plasmas/twig>。下一项工作是任务 08（M1-008）：子进程 Supervisor（§5.5 状态机，有限重启+退避）。

**第一阶段非目标**（不得混入范围）：任何写能力（改文件、执行终端命令）、多人协作/账号/云同步、Windows/Linux 版、画布式节点图、历史导入、Apple 签名与公证分发。

## 2. 仓库布局

```
TODO.md                          线性执行台账：50 个任务 + G0~G4/RC 门槛 + DEC 决策点，逐项勾选
doc/
  分支对话面板-开发文档.md        产品定位、需求、技术选型、数据模型（v1.0 定稿，"已确认"决策不得擅改）
  分支对话面板-开发流程.md        执行版流程：DoR/DoD、状态机、各阶段交付物、测试矩阵、RC 检查清单
adr/
  ADR-001-acp-client-path.md     已定稿：采用 rebornix/acp-swift-sdk；含锁定版本基线、PoC 结论与回退触发条件
Package.swift                    SPM 工程清单（Swift 6，macOS 14+；目标：App/Features/Core/Shared/SchemaPoC）
Package.resolved                 依赖锁定（acp-swift-sdk @ b800b3f + swift-log + swift-system）
App/        BranchConversationApp.swift, AppEnvironment.swift（@main 入口，SwiftUI）
Features/   MainChat/ BranchPanel/ ConversationTree/ Settings/（界面功能层占位）
Core/       ACP/（AgentEvent, Client/Transport/EventAdapter/SessionStore）
            Process/（CLIEnvironmentProbe, ACPProcessSupervisor）
            Policy/（PermissionPolicyEngine）
            Branching/（BranchContextAssembler, BranchMergeService）
            Persistence/（AppDatabase, Migrations/, Repositories/）
Shared/     Models/ UIComponents/ Logging/ TestSupport/
Tests/
  CoreTests/                     单元测试（swift-testing）；Fixtures/ 为 G0 脱敏样本提取件
spike/
  probe_acp.py                   G0 协议探针（Python 3，stdlib-only），驱动 `kimi acp` 采集事件样本
  sanitize_samples.py            样本脱敏脚本（路径替换、他人会话遮蔽、敏感词扫描）
  g0-findings.md                 G0 结论报告：协议行为、权限三分、生命周期、播种实测、待验证清单
  samples/raw/                   原始样本（未经脱敏，勿直接引用到对外产物）
  samples/sanitized/             脱敏样本（后续测试替身 / 回归 fixtures 的数据源）
  sandbox/                       探针自建沙箱文件（内容全部人造，不含真实项目数据）
```

**Swift 工程分层**（流程文档 §5.4，任务 07 已按此落地；SPM target 与顶层目录一一对应：App → Features → Core → Shared）：

```
App/        BranchConversationApp.swift, AppEnvironment.swift
Features/   MainChat/ BranchPanel/ ConversationTree/ Settings/
Core/       ACP/（Client/Transport/EventAdapter/SessionStore）
            Process/（CLIEnvironmentProbe, ACPProcessSupervisor）
            Policy/（PermissionPolicyEngine）
            Branching/（BranchContextAssembler, BranchMergeService）
            Persistence/（AppDatabase, Migrations, Repositories/）
Shared/     Models/ UIComponents/ Logging/ TestSupport/
```

## 3. 构建与测试命令

**当前可用的只有 spike 探针**（Python 3，无第三方依赖）：

```bash
cd spike
python3 probe_acp.py baseline   # 握手/session/流式/list/resume/load
python3 probe_acp.py perms      # 工具调用 + permission 放行/拒绝
python3 probe_acp.py fsrpc      # fs.readTextFile 反向 RPC 采样
python3 probe_acp.py lifecycle  # 握手失败/未知方法/崩溃/stdin 关闭
python3 probe_acp.py seed       # 长背景播种（消耗会员额度，慎用高档位）
python3 sanitize_samples.py     # raw/ + stderr 日志 → sanitized/，含敏感词扫描
```

注意：探针会真实驱动 `~/.kimi-code/bin/kimi acp` 并**消耗会员额度**；prompt 均已最小化，重跑前先确认必要性。

**Swift 工程**（Swift 6.3.3 + SPM，最低 macOS 14；技术栈：SwiftUI + AppKit 互操作、GRDB（任务 11 引入）、acp-swift-sdk）：

```bash
swift build                 # 构建全部目标（App/Features/Core/Shared）
swift run BranchConversation # 启动应用（当前为骨架占位窗口）
swift test                  # 单元测试（swift-testing；含 acp-swift-sdk schema 核对，升级 SDK 后必跑）
swift package resolve       # 解析/更新依赖
```

测试框架为 swift-testing（Xcode 26），测试位于 `Tests/CoreTests/`。

## 4. 锁定的版本基线（ADR-001 兼容矩阵首行）

| 组件 | 版本 |
|---|---|
| Kimi Code CLI | **0.31.0**（`~/.kimi-code/bin/kimi`） |
| ACP 协议 | **v1**（`protocolVersion=1`） |
| agent 侧协议栈 | @agentclientprotocol/sdk@0.23.0（kimi 内置） |
| 客户端 SDK | rebornix/acp-swift-sdk @ commit `b800b3f`（任务 07 PoC 通过；上游无 release tag，待 1.0.0 发布转语义版本） |

回退路径：PoC 发现 schema 不兼容 → **手写 NDJSON transport**（第一回退，G0 已证明协议面窄、约数百行可覆盖）→ Rust FFI（最后手段，触发时重开 DEC-02，排期 +1~2 日）。

## 5. G0 已实测的协议事实（适配层设计依据，勿凭猜测推翻）

- framing 为 **NDJSON over stdio**（每行一个 JSON-RPC 消息）；stdout 纯协议，日志走 stderr。
- 已登录时 `session/new` 直接成功，**无需 authenticate**。
- `session/list`、`session/resume`（不重放历史）、`session/load`（**异步重放**历史，客户端须等待聚合）全部支持。
- 权限三分实测：**读文件不触发 permission**（CLI 直接执行）；写文件（kind=`edit`）与终端命令（kind=`execute`）触发 `session/request_permission`，可拒绝且目标文件不落盘；拒绝后 agent 继续作答至 `end_turn`。
- `tool_call` → 多条稀疏 `tool_call_update`（字段可空，须容忍）→ 终态；call id 稳定（形如 `0:tool_xxx`）。
- 优雅终止唯一可靠方式：**关闭 stdin → exit 0**；SIGTERM 被忽略，强杀用 SIGKILL（之后 stdout EOF 立即可观测）。
- 长背景播种 4KB/32KB/128KB 字符三档全部正常 `end_turn`，无截断；压缩阈值 DEC-05 待 B-M3 定稿，警戒值应显著低于 128KB。
- `usage` 字段为 null，协议内暂无法查询额度（DEC-11）。
- 待验证清单共 7 项（allow_always 行为、多 session 事件交错、cancel 时序等），见 `spike/g0-findings.md` §8。

## 6. 工作流约定（来自 TODO.md 与流程文档，执行时必须遵守）

- **台账驱动**：任务以 TODO.md 为唯一执行台账；状态 `[ ]`/`[~]`/`[x]`/`[!]`；每完成一项**立即**更新勾选与「▶ 当前进度」指针，并在附录 C 追加进度日志。
- **Ready**：关联阶段、输入/输出/不做事项、依赖、≥1 条可执行验收条件齐备才开工。
- **Done**：测试通过、错误/空状态已处理、日志不记敏感内容、文档已同步、验收可重复。
- **决策点（DEC-01~11）**：到达前必须显式关闭，产出 ADR（`adr/` 目录）或实现说明；DEC-01/03/04 已关闭。
- **Gate 制**：G0（已过）→ G1（B-M1 主对话）→ G2（B-M2 只读安全）→ G3（B-M3 支线）→ G4（B-M4 树/多线程/恢复）→ RC。阶段不得只按"代码写完"判断完成。
- **分支与提交**：短分支 `spike/xxx`、`feat/bmN-xxx`、`fix/xxx`；提交信息用 Conventional Commits 风格英文，如 `feat(acp): establish session and stream text deltas`。每个合并请求只解决一个 Story 或一组强相关 Task。**分支的创建、提交、合并回 `main` 与推送由代理代为管理**（用户 2026-07-31 授权，无需逐次确认）。

## 7. 代码规范（Swift 工程落地后适用）

核心架构约束（流程文档 §5.4，"核心约束"原文）：

- UI 不直接读写 Pipe；
- ACP SDK 类型不得直接扩散到 Feature 层，协议适配集中在 ACP adapter（输出统一 `AgentEvent` 领域事件）；
- **permission 回调只进入 `PermissionPolicyEngine`，不由 View 决定**；
- 数据库存取通过 Repository 层；不把完整 ACP SDK 对象直接序列化进数据库；
- 分支上下文组装（`BranchContextAssembler`）独立于 UI 和 session 创建；
- 未知/损坏协议事件**保守记录，不崩溃**；
- 数据库：每次 schema 变化新增 migration（不改已发布 migration）；线程/支线/回流等复合写入必须同事务。

## 8. 测试策略

四层测试体系（流程文档 §10）：

1. **单元测试**：PermissionPolicyEngine、BranchContextAssembler、BranchMergeService、ACP event adapter、session 路由、树构建（含孤儿/环检测）、锚点定位、migration、消息状态机。
2. **ACP 测试替身**：以 `spike/samples/sanitized/` 的脱敏样本为 fixtures 建立 fake ACP process，可脚本化流式、工具事件、各类 permission、malformed message、子进程中途退出、多 session 交错等。替身用于稳定回归，**不能替代真实 CLI 验证**。
3. **真实 CLI 集成测试**：每个 Gate 至少一次，RC 前全量（真实写/终端权限拒绝、播种、嵌套、回流、子进程重启、session 恢复）。
4. **UI 测试**：自动化或可重复手工脚本。

**不得跳过的测试矩阵**：SEC-01~14（只读安全，G2 不允许任何"暂时跳过"）、BR-01~18（支线）、TREE/THREAD/REC（B-M4）。跨阶段回归原则：B-M2 后重跑 B-M1 崩溃测试，B-M3 后重跑 SEC 矩阵，RC 前跑全链路。

## 9. 安全注意事项

- **第一阶段绝对只读**：allowlist 仅含读文件/列目录/搜索；写、编辑、删除、终端命令、**未知类型、无法解析的请求一律默认拒绝**（default deny）。CLI 升级出现新操作类型不得默认批准。
- **日志脱敏**：默认只记事件类型、脱敏 session id、耗时、状态、错误码；不记完整用户问题、模型回答、文件内容、登录信息。permission 拒绝日志保留操作分类与决策原因。
- **样本脱敏**：任何进入仓库或对外产物的协议样本必须经过 `sanitize_samples.py`（或等效流程）处理；`samples/raw/` 可能含本机路径，勿直接外发。
- **额度意识**：所有真实 CLI 调用消耗用户会员额度；避免重复发送、超长背景注入；重试须产生明确新请求，不得悄悄重复扣费。
- 候选版本若权限回归失败**不得发布**；CLI 升级导致兼容失败时回退到已验证版本，而不是临时放宽解析或权限策略。

## 10. 给代理的实务提示

- 改任何协议行为假设前，先查 `spike/g0-findings.md` 的实测结论与 ADR-001；有冲突时以实测样本为准并更新文档。
- 动数据模型（锚点字段 DEC-07 等）前先确认对应 DEC 是否已关闭、是否需要 ADR + migration。
- 文档标记约定：「已确认」= 不得擅改；「流程补充」= 工程补充可调整；「待验证」= 须实测定案；「待决策」= 须 ADR。
- 当前进度与下一任务永远看 TODO.md 顶部「▶ 当前进度」。
