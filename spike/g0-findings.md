# G0 技术验证结论（开工日 spike）

> 日期：2026-07-31 ｜ 对象：`kimi` CLI **0.31.0**（`~/.kimi-code/bin/kimi`）
> 工具：`spike/probe_acp.py`（NDJSON JSON-RPC 探针客户端，stdlib-only）
> 样本：`spike/samples/sanitized/*.jsonl`（已脱敏：路径替换、他人会话条目遮蔽、敏感词扫描复核通过）
> 额度消耗：7 个短 prompt + 3 个播种 prompt，均为最小化提问

## 1. 环境与握手（M1-001 / M1-004）

- CLI 0.31.0，`acp` 子命令存在；启动后 stdout 纯协议（无 banner），日志走 stderr + `~/.kimi-code/logs/`。
- `initialize` → `protocolVersion: 1`（ACP v1）；`agentInfo` / `authMethods`（login，device-code terminal-auth）按官方文档返回。
- **已登录状态下无需 `authenticate`**，`session/new` 直接成功；`authenticate(methodId=login)` 返回空 result 成功。
- `clientInfo`/`clientCapabilities` 正常协商；声明 `fs.readTextFile=true` 会改变读文件路径（见 §4）。
- 请求 `protocolVersion=999` → agent 回落应答 `protocolVersion=1`（不报错）。应用启动时应比对版本并提示。
- 非法 JSON 行：协议通道静默，stderr 记 `Failed to parse JSON message`，连接不断。适配层对未知/损坏行应保守记录。

## 2. 能力与版本（DEC-03 / DEC-04）

- 版本基线：**CLI 0.31.0 ｜ ACP v1（protocolVersion=1）｜ agent 侧基于 @agentclientprotocol/sdk@0.23.0**（官方文档）。
- `agentCapabilities`：`loadSession=true`，`promptCapabilities{image:true, audio:false, embeddedContext:true}`，`mcpCapabilities{http,sse}`，`sessionCapabilities{list:{}, resume:{}}`。
- **DEC-04 实测结论：session 枚举/恢复/续接全部支持**——
  - `session/list`：枚举全部用户会话（含 sessionId/cwd/title/updatedAt）；
  - `session/resume`：成功，返回 configOptions，**不重放历史**；
  - `session/load`：成功，**异步重放历史**（实测 8 条：user_message_chunk/agent_thought_chunk/agent_message_chunk/tool_call/tool_call_update/available_commands_update；响应后陆续到达，客户端须等待聚合）。
- `session/close`、`logout` 未实现 → `-32601 methodNotFound`（含 `data.method`）。自定义 `_probe/bogus` 同样 -32601。未实现方法不会崩连接。

## 3. 主链路与流式（M1-004）

- `session/new` → `sessionId`（`session_<uuid>` 形式）+ `configOptions[]`：**model 选择器**（kimi-for-coding / kimi-for-coding-highspeed / k3 / k3-256k，当前 k3-256k）与 **thinking 选择器**——模型/模式切换（P0 需求）有协议通道（`session/set_config_option` / `session/set_mode`）。
- 通知流：`available_commands_update`（slash 命令清单，含 `/compact`、`/usage`——"Show session token usage"，**DEC-11 线索**）、`agent_thought_chunk`（思考流，独立事件类型）、`agent_message_chunk`（正文 delta，粒度细）。
- `session/prompt` 响应：`stopReason=end_turn`；**`usage` 字段为 null，全程未观察到 usage 上报事件**（额度展示在协议内暂不可行，记录给 DEC-11/B-M5）。

## 4. 工具调用与权限（M1-004，支撑 B-M2 策略器设计）

- 工具事件：`tool_call`（含 `toolCallId`、`title`、`kind`、`status=pending`）→ 多条 `tool_call_update`（大量 `in_progress` 稀疏更新，字段可空，适配层须容忍）→ 终态 `completed`/`failed`。call id 形如 `0:tool_xxx`，稳定可关联。
- **权限三分行为（实测）**：
  | 操作 | tool kind | 是否触发 `session/request_permission` |
  |---|---|---|
  | 读文件（Read） | `read` | **不触发**，CLI 直接执行 |
  | 写文件（Write） | `edit` | 触发，options：approve_once/approve_always/reject |
  | 终端命令（Bash） | `execute` | 触发，options 同上 |
- 拒绝路径实测：响应 `{outcome:{outcome:"selected", optionId:"reject"}}` → 工具 `failed`（附"user rejected"提示文本）→ agent 继续作答 → `end_turn`；**目标文件未落盘**（写/终端两场景均验证）。
- permission 请求的 `toolCall.content` 带操作预览文本（如 "Requesting approval to Running: touch …"），可直接用于 UI。
- 声明 `fs.readTextFile=true` 后：**读文件改走 `fs/read_text_file` 反向 RPC 由客户端供给内容**（实测同一文件被请求两次）。应用因此有两个读管控点：默认免审批（CLI 本地读）或客户端接管（可审计、可拒绝）。写能力不声明时仍走 permission 请求，可拒绝。
- 对只读策略的含义：B-M2 策略器主拦截点 = permission 回调（写/终端拒绝）；读放行与 CLI 默认行为一致；未知类型默认拒绝需在适配层兜底。

## 5. 子进程生命周期（M1-004，支撑 ACPProcessSupervisor）

- **优雅终止：关闭 stdin → 进程 exit 0**。这是唯一可靠的优雅关闭方式。
- **SIGTERM 被忽略**（12s 内不退出）；强杀用 SIGKILL。
- SIGKILL 后：stdout EOF 立即可观测，挂起请求应以 transport_closed 失败。崩溃检测链成立。
- framing：NDJSON，每行一个完整 JSON-RPC 消息；关闭方式即 stdin EOF。

## 6. 长背景播种（M1-005）

模板 `[背景上下文]+[当前选中段落]+[用户追问]+[来源说明]`，新建 session 播种：

| 背景长度 | 结果 | 耗时 | stopReason |
|---|---|---|---|
| 4,096 字符 | 正常流式 | 45.5s | end_turn |
| 32,768 字符 | 正常流式 | 18.2s | end_turn |
| 131,072 字符 | 正常流式 | 17.1s | end_turn |

- 无截断/超时/异常；耗时受思考长度波动主导，未随输入尺寸劣化。
- 三档回答均准确总结背景并**逐字引用选中段落**——播种模板的问题指向稳定。
- 每档独立 session，历史隔离（`session/list` 可查）。
- 更高档位未测（控制额度消耗）。**DEC-05 记录：128KB 字符以内无失败点；压缩阈值 B-M3（任务 29）据此定稿，建议警戒值显著低于 128KB。**

## 7. DEC-01 证据：ACP Swift SDK 现状

- **官方 SDK 只有 Rust 与 TypeScript（均已 1.0）；无官方 Swift SDK**（[官方库页面](https://agentclientprotocol.com/libraries/community)）。
- 社区 Swift 实现三家：
  | 库 | 特点 | 风险 |
  |---|---|---|
  | `rebornix/acp-swift-sdk` | Swift 6 严格并发、MIT、客户端向、类型化方法、stdio/WebSocket、含 session/load/resume（draft） | 个人维护，需核对 schema 与 ACP v1 对齐 |
  | `wiedymi/swift-acp` | 有真实应用（Aizen）背书、macOS 12+、actor 并发、session/list、fs/terminal delegate | 社区规模小 |
  | `aptove/swift-sdk` | 自称全协议覆盖、双端实现 | 标称协议版本为旧日期制，维护活跃度待核 |
- 补充事实：本探针证明 ACP over stdio 协议面很窄（握手/session/prompt/通知/permission 五类消息），**手写 NDJSON transport 成本约数百行**，是 FFI 之外的第三选项。
- 分析：**Rust FFI 路径（文档备选）在本轮证据下吸引力下降**——协议简单、无重计算，FFI 只增加构建与调试复杂度。实际选择收敛为「社区 Swift SDK（首选 rebornix，骨架阶段做 PoC 核对 schema）」vs「手写 transport」。待用户关闭 DEC-01。

## 8. 待验证清单（带入 B-M1 及以后）

- `allow_always` 批准后是否整个 session 免审批（策略器须感知）；
- 多 session 并发时事件交错与归属（B-M3 路由设计依赖）；
- `session/cancel` 实际中断时序与残余事件；
- `session/set_config_option` 切换模型/思考的生效确认；
- image / resource / resource_link prompt 的实际行为（P1+）；
- >128KB 播种的行为（如需，RC 前补测）；
- 支线新 session 的 title 生成规则（树节点摘要数据来源）。

## 9. 样本索引（samples/sanitized/）

| 文件 | 覆盖 |
|---|---|
| baseline-*.jsonl | 握手、session/new、文本+思考流、session/list/resume/load |
| perms-*.jsonl | 读工具（免审批）、写工具 permission 拒绝全链路 |
| terminal-*.jsonl | Bash permission 拒绝、拒绝后 agent 续答 |
| fsrpc-*.jsonl | fs/read_text_file 反向 RPC |
| loadreplay-*.jsonl | session/load 历史重放时序 |
| seed-*.jsonl | 三档长背景播种 |
| lifecycle-badjson/-badversion/-unknown/-crash/-stdinclose-*.jsonl | 非法输入、版本回落、未知方法、SIGKILL EOF、stdin 关闭退出 |
| stderr-*.log | 各运行子进程 stderr（解析失败日志等） |
