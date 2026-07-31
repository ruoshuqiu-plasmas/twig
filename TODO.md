# 分支对话面板 · 线性 TODO（执行台账）

> 来源：`doc/分支对话面板-开发文档.md`（v1.0，2026-07-25）、`doc/分支对话面板-开发流程.md`（执行版）
> 生成日期：2026-07-31 ｜ 执行者：Kimi Code（逐项执行，用户把关）
> 基线：单人 12 个工作日；若走 Rust FFI 另加 1～2 日

**状态约定**：`[ ]` 未开始 ｜ `[~]` 进行中 ｜ `[x]` 完成 ｜ `[!]` 阻塞（须记录原因）
**⑂ 条件分支**：仅当触发条件成立时执行，不占主线
**⬦ 决策点（DEC）**：到达该位置前必须显式关闭，产出 ADR 或记录

**执行规则摘要**（流程文档 §2.3~2.4）：
- Ready：关联阶段、输入/输出/不做事项、依赖、≥1 条可执行验收条件齐备才开工；
- Done：测试通过、错误/空状态已处理、日志不记敏感内容、文档已同步、验收可重复；
- 每完成一项立即更新本文件勾选状态与下方进度指针。

**▶ 当前进度**：**任务 10+11 已完成**（SessionStore 映射/路由 + GRDB 首版 migration 与仓储，46 测试全绿连跑 3 次稳定）——下一项 `12. M1-012` 主对话状态机与流式 UI（§5.7）。⚠️ 推送前收尾：Package.resolved 的 GRDB revision 为本地合成哈希（网络受限期 zip 播种），须网络稳定时重新 resolve 换真实哈希

---

## B-M1：项目骨架、ACP 基础链路与主对话（D1～D4）

> 阶段目标：应用启动 → 环境检测 → 子进程 → ACP 握手 → session → 发消息 → 流式接收 → 渲染并持久化。
> 排期：D1 四项技术验证+ADR-001；D2 骨架+子进程管理；D3 ACP 适配+session；D4 主对话 UI+持久化+异常（G1）。

- [x] ⬦ DEC-03：通过验证版本已记录（2026-07-31 实测握手）：**CLI 0.31.0 ｜ ACP v1（protocolVersion=1）｜ agent 侧 @agentclientprotocol/sdk@0.23.0** → 兼容矩阵首行（见 `spike/g0-findings.md` §2）
- [x] 01. **M1-001** CLI 存在、版本、`acp` 子命令、登录态探测 ｜ 依赖：无 ｜ 输出：`CLIEnvironmentProbe` 原型 + 版本记录 + 三类失败（缺失/不兼容/未登录）日志
  - 探测结果（2026-07-31，只读未改动环境）：CLI 位于 `~/.kimi-code/bin/kimi`，版本 **0.31.0**；`acp` 子命令存在（`kimi acp`，含 `--login` device-code 流程，支持 ACP terminal-auth）；`kimi doctor` 校验 config.toml / tui.toml 均 OK；登录态经 ACP 握手实测有效（`session/new` 直接成功，无需 authenticate）
  - 待补（转入后续任务）：Swift 版 `CLIEnvironmentProbe` 随任务 07 骨架落地；三类失败演示由 G1-02/03/04 验收场景覆盖
- [x] ⬦ DEC-01：ACP Swift SDK（2026-07-31 拍板）：采用 **rebornix/acp-swift-sdk**，骨架阶段 PoC 核对 schema 后锁版本；第一回退＝手写 NDJSON transport；Rust FFI 降为最后手段 → **ADR-001 已定稿**：`adr/ADR-001-acp-client-path.md`
- [x] 02. **M1-002** Swift SDK 可用性验证 ｜ 依赖：M1-001 ｜ 输出：SDK PoC（初始化/握手/session/收消息）
  - 完成（2026-07-31）：可用性调研完成；协议 PoC 由 Python 探针完成（握手/session/流式/permission 全通）；Swift 侧 PoC 待 DEC-01 选定 SDK 后随任务 07 骨架补齐
- [ ] 03. ⑂ **M1-003** Rust FFI 备选验证（原触发条件：M1-002 失败）｜ 输出：FFI PoC ——G0 证据下触发条件实际变为「DEC-01 选定的 Swift 方案 PoC 失败」；届时优先评估手写 transport 而非 FFI
  - ⬦ DEC-02：Rust FFI 最小边界（仅备选触发）→ ADR-001 附录
- [x] ⬦ DEC-04：ACP session 恢复能力（2026-07-31 实测）：`session/list` ✓、`session/resume` ✓（不重放）、`session/load` ✓（异步重放历史）；恢复策略记录于 `g0-findings.md` §2
- [x] 04. **M1-004** ACP 完整链路事件采样（握手成败/session/发消息/文本流/工具调用/permission 回调/完成/子进程崩溃/正常终止）｜ 依赖：M1-002/003 ｜ 输出：脱敏事件样本（供测试替身）
  - 完成（2026-07-31）：9 类事件全部采样，`spike/samples/sanitized/`（读免审批；写/终端 permission 拒绝生效且文件未落盘；SIGKILL 后 EOF 可观测；stdin 关闭 exit 0，SIGTERM 被忽略）
- [x] 05. **M1-005** 长背景新 session 播种验证（长度限制/截断/超时/计费表现/历史隔离/摘要稳定性）｜ 依赖：M1-004 ｜ 输出：测试结论 + `TBD_CONTEXT_COMPRESSION_THRESHOLD`（只记实测，不写死）
  - 完成（2026-07-31）：4KB/32KB/128KB 字符三档全部 end_turn，无截断/超时，锚点段落逐字识别，session 历史隔离；未观察到 usage 上报；更高档位为省额度未测
  - ⬦ DEC-05：压缩阈值——实测数据已记录（128KB 内无失败点），B-M3（任务 29）定稿

### Gate G0 退出门槛 ✅ 已通过（2026-07-31）
- [x] 已选定实现路径（ADR-001：rebornix/acp-swift-sdk；第一回退＝手写 NDJSON transport）
- [x] 握手、session、文本流、permission request 均有真实样本（2026-07-31）
- [x] ACP 消息 framing 与关闭方式已明确（NDJSON；stdin EOF 优雅退出；SIGTERM 无效；SIGKILL 后 EOF 可观测）
- [x] session 枚举/恢复/续接能力已记录（list/resume/load 全支持，load 异步重放）
- [x] 长背景播种路径已验证（≤128KB 字符无失败点）
- [x] 未确认协议能力已列入「待验证清单」（`g0-findings.md` §8，共 7 项）并有保守回退方案

- [x] 06. **M1-006** ADR-001 定稿与版本兼容矩阵 ｜ 依赖：M1-001～005 ｜ 输出：架构结论 + 兼容矩阵首行
  - 完成（2026-07-31）：`adr/ADR-001-acp-client-path.md`（含被否决方案、回退触发条件、兼容矩阵首行）
- [x] 07. **M1-007** Swift 项目与模块骨架（按 §5.4 结构：App/Features/Core/Shared）｜ 依赖：M1-006 ｜ 输出：可构建工程
  - 完成（2026-07-31）：Swift 6.3.3 + SPM 工程落地（Package.swift，macOS 14+），§5.4 四层结构 24 个占位文件就位，`swift build` 通过。acp-swift-sdk PoC 通过：ADR-001 四个核对点（tool_call_update 稀疏字段容忍 / configOptions[] / sessionCapabilities{list,resume} / agent_thought_chunk）全部满足，fixtures 取自 G0 脱敏样本离线解码（未驱动真实 CLI）。**两个环境事实**：① 上游 SDK 尚无 release tag（仅 main 分支），按 commit `b800b3f` 锁定，待 1.0.0 发布转语义版本；② 本机仅 Command Line Tools（无 Xcode），XCTest/swift-testing 不可用，PoC 以可执行目标 `swift run schema-poc` 承载，装 Xcode 后迁回 testTarget。**已知缺口**：SDK `SessionNew.Result` 未建模 kimi 扩展字段 `configOptions[]`（解码静默丢弃，适配层需要时自行扩展）。
- [x] 08. **M1-008** 子进程 Supervisor（§5.5 状态机：notChecked…failed(reason)，有限重启+退避）｜ 依赖：M1-007 ｜ 输出：生命周期与状态机
  - 完成（2026-07-31）：`SupervisorState` 九态全集（§5.5 原文）；`CLIEnvironmentProbe`（存在性/版本 ≥0.31.0 基线/凭据预判，对应 G1-02/03/04）；`ACPProcessSupervisor` actor（起停、stdout 流/send 唯一出入口、termination 监听、maxRestarts=3 + 退避 [1s,2s,4s] 内部配置、优雅停止＝关闭 stdin 超时升 SIGKILL 跳过 SIGTERM）。14 个单元测试全绿（fake CLI 脚本驱动，未耗额度）。**环境发现**：swift-testing 高度并发派生子进程时，子进程会卡在 dyld 启动通知阶段假死（sample 实证 `RemoteNotificationResponder::blockOnSynchronousEvent`）——派生子进程的测试套件须标 `.serialized`，已写入 AGENTS.md §8。
- [x] 09. **M1-009** ACP transport 与 adapter（§5.6 `AgentEvent` 领域事件，未知事件保守记录）｜ 依赖：M1-008 ｜ 输出：领域事件流
  - 完成（2026-07-31，分支 feat/bm1-acp-adapter）：`AgentEvent` 十类领域事件 + `ToolCallInfo`/`PermissionRequestData`/`PermissionDecision`；`SupervisorTransport`（actor，架在 supervisor 上做 NDJSON 行分帧，CRLF 防御）；`ACPEventAdapter`（SDK SessionUpdate → 领域事件，tool_call_update 稀疏字段容忍，unknown 走 hook 保守记录）；`RequestPermission` 自扩展 Method（线格式按 G0 样本）；`ACPClient`（connect 联动 supervisor 状态/newSession/prompt/cancel/disconnect/多订阅者事件流，capabilities=.minimal 避开 fs 声明，permission 默认 default deny=cancelled 待 M2-005 接策略器）。20 个新测试（adapter 离线映射 14 + fake agent 端到端 3 + 既有回归），34/34 全绿且连跑 6 次稳定。**排坑三条**：① acp-swift-sdk 的 JSONEncoder 把 `/` 转义为 `\/`（`session\/new`），fake agent 按字面 `session/new` 匹配导致永不应答、测试挂死——含斜杠 method 须双写法兼容；② swiftpm-testing-helper 与测试同进程，孙进程（bash fake agent）继承管道 FD 泄漏会让 helper 永远等不到 EOF——supervisor deinit 已加 SIGKILL 兜底；③ swift-testing 下自制 withTimeout 不能用任务组实现（任务组隐式等待不响应取消的子任务），须非结构化竞速。另实测：SDK 的 request id 混用数字（initialize=1）与 UUID 字符串（session/new 起）。
- [x] 10. **M1-010** Session 管理与路由（session ↔ thread/branch 映射）｜ 依赖：M1-009 ｜ 输出：session 映射
  - 完成（2026-07-31，分支 feat/bm1-session-store）：`SessionStore` actor——acpSessionID → thread/branch 映射、注册/摘除/启动恢复（恢复一律 isLive=false，不制造「已续接」假象，恢复策略归 M4-010）、子进程重启 `markAllStale` 整表失效不删除；事件路由＝单一订阅 ACPClient 全局流按 sessionID fan-out 为每 session 独立 AsyncStream（无归属事件走 globalEvents，无主 session 事件脱敏保守记录不崩溃）；持久化缝 `SessionMappingStore` 协议（M1-011 由 ThreadRepository 实现）。`AgentEvent` 增 sessionID 提取；FakeACPAgent 增 multiSession 行为（sess_1/sess_2 + 幽灵事件）。5 个新测试（4 映射单测 + 1 fake agent 双 session 并发路由 e2e），39/39 全绿连跑 3 次稳定，零额度消耗。
- [x] 11. **M1-011** GRDB 首版 migration（threads/messages/branches/branch_notes + §5.8 工程字段：sequence/status/updated_at/metadata_json/merge_note_id）｜ 依赖：M1-007 ｜ 输出：核心表与仓储
  - 完成（2026-07-31，分支 feat/bm1-session-store）：GRDB 7.11.1 引入（Core/Shared/CoreTests 三 target）。`Shared/Models` 四记录类型（ConversationThread/Message/Branch/BranchNote + MessageRole/Kind/Status/BranchStatus 枚举，snake_case 列映射，不存 ACP SDK 对象）；`Core/Persistence`：AppDatabase（文件库/内存库，init 即迁移）、Migrations v1（四表 + 工程字段 + 索引 idx_messages_thread_branch_seq/idx_branches_thread + 外键；anchor_message_id 因与 messages.branch_id 循环引用不建 FK——SQLite 外键开启时不允许引用未创建的表）、ThreadRepository（建线程/最近活动排序/实现 SessionMappingStore 缝）与 MessageRepository（发送即存/delta 追加/状态流转/按 sequence 读，插入同事务触碰线程 updated_at）。7 个 Persistence 测试 + 全量回归 46/46 全绿连跑 3 次，内存库零副作用。**排坑**：GRDB 7 同名同步/异步 read|write 重载在 async 上下文优先选异步版（测试直调 db 须 await）；**网络受限期依赖获取**：github.com 大传输反复断流（代理 HTTP/2 不稳），最终由用户手动下载 v7.11.1 zip（commit b83108d1），经 jsDelivr 官方清单 SHA-256 逐文件校验 229/229 一致后建本地镜像播种 SPM 缓存 + insteadOf 离线 resolve——**Package.resolved 中 GRDB revision 351f0f6f 为本地合成哈希，网络稳定后须重新 resolve 换真实哈希 b83108d1 再推送**。
- [ ] 12. **M1-012** 主对话状态机与流式 UI（§5.7：发送即存、占位消息、delta 顺序追加、中断标记、跨线程路由）｜ 依赖：M1-009~011 ｜ 输出：主对话闭环
- [ ] 13. **M1-013** 中断、重启、错误页面（CLI 缺失/版本不兼容/未登录三态区分）｜ 依赖：M1-008~012 ｜ 输出：恢复路径
- [ ] 14. **M1-014** B-M1 自动与手工验收 ｜ 依赖：全部 ｜ 输出：G1 证据 + 测试报告

### Gate G1 验收场景（§5.10，逐条执行）
- [ ] G1-01 CLI 已装已登录 → 进入可对话状态
- [ ] G1-02 CLI 缺失 → 安装引导，不崩溃
- [ ] G1-03 CLI 不支持 acp → 版本不兼容提示
- [ ] G1-04 登录失效 → 登录引导
- [ ] G1-05 创建主线程发消息 → 连续流式文本
- [ ] G1-06 流式中切换线程再切回 → 写入正确线程
- [ ] G1-07 流式中杀死子进程 → 消息标记中断，可恢复
- [ ] G1-08 重启子进程 → 可新 session；旧 session 续接按实测能力处理
- [ ] G1-09 退出重开应用 → 本地线程消息仍在
- [ ] G1-10 收到未知协议事件 → 不崩溃，保守记录

---

## B-M2：工具调用、权限策略与富文本渲染（D5～D7）

> 阶段目标：工具行为可视化、可审计；第一阶段绝对只读。
> 排期：D5 工具卡片；D6 策略器+拒绝通知；D7 Markdown/高亮+回归（G2）。

- [ ] 15. **M2-001** 工具事件领域模型（requested→running→succeeded/failed/denied，稳定 call id 关联）｜ 依赖：M1-009 ｜ 输出：工具生命周期
- [ ] 16. **M2-002** 工具调用折叠卡片（工具名/参数摘要/状态/结果摘要；大结果默认折叠；可持久化回看）｜ 依赖：M2-001 ｜ 输出：折叠 UI
- [ ] 17. **M2-003** 权限类型映射（协议工具/权限类型 → 内部操作分类，基于真实样本）｜ 依赖：M1-004 ｜ 输出：映射表
- [ ] 18. **M2-004** PermissionPolicyEngine（allowlist 仅读文件/列目录/搜索；其余一律默认拒绝，含未知与无法解析）｜ 依赖：M2-003 ｜ 输出：allowlist/default deny
- [ ] 19. **M2-005** ACP permission 响应接入（回调只进策略器，返回合规批准/拒绝响应）｜ 依赖：M2-004 ｜ 输出：实际批准/拒绝
- [ ] 20. **M2-006** 拒绝 notice 与持久化（对话流标注「已按只读策略拦截」；设置页只展示不修改）｜ 依赖：M2-002/005 ｜ 输出：透明展示
- [ ] ⬦ DEC-08：Markdown/高亮库选型（Splash vs Highlightr；依据：SwiftUI 集成/增量性能/语言覆盖/维护/许可证）→ ADR-002（B-M2 前半关闭）
- [ ] 21. **M2-007** Markdown 渲染方案验证（流式先保可见，稳定片段再解析；解析失败回退纯文本）｜ 依赖：M1-012 ｜ 输出：ADR-002
- [ ] 22. **M2-008** 代码块高亮与回退（超长块不做一次性昂贵高亮）｜ 依赖：M2-007 ｜ 输出：富文本渲染
- [ ] 23. **M2-009** 工具结果文本可选中（代码块/引用/列表/段落均保留选区能力；AppKit 选区层不与渲染层互覆）｜ 依赖：M2-002/008 ｜ 输出：B-M3 前置能力
- [ ] 24. **M2-010** SEC 全量测试 ｜ 依赖：M2-003~009 ｜ 输出：G2 证据

### Gate G2 安全测试矩阵（§6.4，不允许任何用例「暂时跳过」）
- [ ] SEC-01 读普通文件 → 自动批准
- [ ] SEC-02 列目录 → 自动批准
- [ ] SEC-03 文本/代码搜索 → 自动批准
- [ ] SEC-04 新建文件 → 自动拒绝
- [ ] SEC-05 覆盖/追加文件 → 自动拒绝
- [ ] SEC-06 编辑已有文件 → 自动拒绝
- [ ] SEC-07 删除/移动/重命名 → 默认拒绝
- [ ] SEC-08 执行任意终端命令 → 自动拒绝
- [ ] SEC-09 未知工具类型 → 自动拒绝
- [ ] SEC-10 权限请求缺分类字段 → 自动拒绝
- [ ] SEC-11 多并发权限请求 → 各自独立正确响应
- [ ] SEC-12 拒绝后模型继续回答 → 对话不断，标记可见
- [ ] SEC-13 拒绝后应用重启 → 拒绝记录可回看
- [ ] SEC-14 CLI 升级新增操作类型 → 不得默认批准
- [ ] G2 附加：拒绝不死锁/不永久挂起；未知 ACP 事件不绕过策略器；工具卡片实时与重启后一致

---

## B-M3：支线创建、嵌套、回流与右侧面板（D8～D10）

> 阶段目标：选中原文 → 追问 → 组装背景 → 独立 ACP session → 支线流式 → 可嵌套 → 可回流。
> 排期：D8 选区+锚点+创建状态机；D9 上下文组装+压缩+嵌套；D10 回流+标签栏+异常幂等（G3）。

- [ ] 25. **M3-001** NSTextView 选区监听（AI 文本与工具结果；忽略空/纯空白/跨区域选区；点击即冻结 selection snapshot）｜ 依赖：M2-008/009 ｜ 输出：selection snapshot
- [ ] ⬦ DEC-07：锚点是否增加 `anchor_start`/`anchor_length`/`anchor_context_hash`（不加则须定义重复引文定位降级规则）→ ADR-003 + 可能的 migration（B-M3 前关闭）
- [ ] 26. **M3-002** 锚点数据方案定稿 ｜ 依赖：M3-001 ｜ 输出：锚点字段/降级规则
- [ ] 27. **M3-003** 「追问」浮动入口与问题编辑界面 ｜ 依赖：M3-001 ｜ 输出：支线创建入口
- [ ] 28. **M3-004** BranchContextAssembler（锚点消息+主线问答+祖先链；§7.4 播种模板：背景/选中段落/追问三段可识别）｜ 依赖：M1-005/M3-002 ｜ 输出：seed_context
- [ ] ⬦ DEC-05 定稿：压缩阈值（基于任务 05 实测）；⬦ DEC-06：摘要用临时独立 session 还是现有 session → ADR 或实现说明（B-M3 前关闭）
- [ ] 29. **M3-005** 长历史摘要流程（只压背景不改锚点与问题；摘要失败不静默截断；记录摘要与原始范围）｜ 依赖：M3-004 ｜ 输出：压缩路径
- [ ] 30. **M3-006** 支线 session 创建状态机（§7.3：防重复创建、取消不耗额度、失败可重试、后台任务有主）｜ 依赖：M1-010/M3-004 ｜ 输出：独立 session
- [ ] 31. **M3-007** 右侧支线标签栏（标签页/锚点引文/状态/合并按钮/10 轮提示入口）｜ 依赖：M3-006 ｜ 输出：支线 UI
- [ ] 32. **M3-008** 支线多轮对话与事件路由（多支线并发流式不串线；关闭标签不删支线）｜ 依赖：M3-006/007 ｜ 输出：独立历史
- [ ] 33. **M3-009** 嵌套支线与祖先链（parent_branch_id；祖先链根→叶排序；关父不毁子；最低验收深度三级）｜ 依赖：M3-004/008 ｜ 输出：多级关系
- [ ] 34. **M3-010** 锚点引文回跳（点击引文主对话滚动+短暂高亮；失配降级到所属消息）｜ 依赖：M3-002/007 ｜ 输出：滚动高亮
- [ ] 35. **M3-011** BranchMergeService（CLI 压缩结论 → branch_notes → 主线注入带来源消息 → status=merged）｜ 依赖：M3-005/008 ｜ 输出：回流笔记
- [ ] 36. **M3-012** 回流幂等与事务（笔记+注入+状态同一事务；重复点击不重复；注入失败显示可恢复中间态）｜ 依赖：M3-011 ｜ 输出：一致性保证
- [ ] 37. **M3-013** 超 10 轮「合并并关闭」提示与 open/merged/closed 状态管理 ｜ 依赖：M3-007/008 ｜ 输出：长度管控
- [ ] 38. **M3-014** BR 全量测试 ｜ 依赖：全部 ｜ 输出：G3 证据

### Gate G3 测试矩阵（§7.9）
- [ ] BR-01 选中 AI 文本 → 追问入口 ｜ BR-02 选中工具结果 → 追问入口 ｜ BR-03 纯空白 → 无入口 ｜ BR-04 旧入口不用过期锚点
- [ ] BR-05 一级支线 → 新 session 独立历史 ｜ BR-06 双击不重复创建 ｜ BR-07 session 失败可重试 ｜ BR-08 支线追问历史独立
- [ ] BR-09 三级嵌套正确 ｜ BR-10 超阈值先摘要、锚点不改写 ｜ BR-11 摘要失败可恢复 ｜ BR-12 引文回跳高亮
- [ ] BR-13 合并生成带来源笔记 ｜ BR-14 重复合并不重复 ｜ BR-15 合并后历史仍在、状态 merged ｜ BR-16 超 10 轮提示
- [ ] BR-17 多支线并发不串线 ｜ BR-18 重启后支线树/锚点/回流状态仍在
- [ ] G3 附加：主线与工具结果均可开支线；回流幂等；标签/锚点/状态与数据库一致

---

## B-M4：左侧对话树、原文回跳、多线程与恢复（D11～D12）

> 阶段目标：本地线程/支线/锚点组织成可导航树；重启后结构不丢。
> 排期：D11 树+卡片+联动；D12 多线程+恢复+全量回归（G4、RC）。

- [ ] 39. **M4-001** 树查询与环/孤儿保护（无效 parent_branch_id 检测记录、不无限递归；流式 delta 不触发整树重建）｜ 依赖：M3-009 ｜ 输出：树模型
- [ ] 40. **M4-002** 左侧卡片式缩进树（根=主线程，支线缩进挂父节点；折叠只隐藏不改数据）｜ 依赖：M4-001 ｜ 输出：树 UI
- [ ] 41. **M4-003** 节点卡片信息（首问摘要/轮数/时间/open/merged/closed/已回流/选中态；空摘要用锚点引文占位）｜ 依赖：M4-001/002 ｜ 输出：节点信息
- [ ] 42. **M4-004** 树节点 → 支线标签联动（点击激活/打开对应右侧标签）｜ 依赖：M3-007/M4-002 ｜ 输出：导航
- [ ] 43. **M4-005** 树 → 原文回跳高亮（与引文点击行为一致；高亮后不改写选区）｜ 依赖：M3-010/M4-004 ｜ 输出：核心体验
- [ ] ⬦ DEC-09：同级排序规则（建议创建时间或最近活动）→ ADR-004（B-M4 前关闭）
- [ ] 44. **M4-006** 同级排序落地 ｜ 依赖：M4-001 ｜ 输出：固定规则
- [ ] ⬦ DEC-10：多主线程第一阶段操作集合（最低：创建/列表/切换/独立 root/最近排序/恢复选中；删除归档等另行确认）（B-M4 前关闭）
- [ ] 45. **M4-007** 主线程创建、列表、切换（每线程独立 project_root、session 映射、消息与支线树）｜ 依赖：M1-010/011 ｜ 输出：多线程基础
- [ ] 46. **M4-008** 跨线程流式事件隔离（快速切换不串线）｜ 依赖：M4-007 ｜ 输出：路由安全
- [ ] 47. **M4-009** 启动恢复本地状态（migration → 读库 → 还原左树/主对话/右侧栏 → 恢复上次选中线程）｜ 依赖：M4-001/007 ｜ 输出：本地恢复
- [ ] 48. **M4-010** ACP session 恢复/降级（区分 localHistoryAvailable/sessionResumed/sessionUnavailable/sessionRecreated；不制造「已续接」假象）｜ 依赖：M1-006/M4-009 ｜ 输出：续接策略
- [ ] 49. **M4-011** TREE/THREAD/REC 全量测试 ｜ 依赖：全部 ｜ 输出：G4 证据

### Gate G4 测试矩阵（§8.6）
- [ ] TREE-01 一级支线挂根 ｜ TREE-02 多级缩进 ｜ TREE-03 点击激活+回跳 ｜ TREE-04 已回流节点标记
- [ ] TREE-05 折叠展开不改数据 ｜ TREE-06 异常父 id 不崩不环 ｜ TREE-07 重复锚点定位/降级 ｜ TREE-08 重渲染后回跳有效
- [ ] THREAD-01 双线程独立 ｜ THREAD-02 快速切换不串线 ｜ THREAD-03 各自 project_root ｜ THREAD-04 重启恢复选中态
- [ ] REC-01 ACP 支持恢复→续接成功 ｜ REC-02 不支持→降级路径明确 ｜ REC-03 迁移失败不损原库 ｜ REC-04 子进程重启后 UI 与能力一致
- [ ] G4 附加：树与 parent_branch_id 完全一致；session 恢复能力与 UI 表述一致

- [ ] 50. **M4-012** 全量回归与候选构建（RC 前冻结：schema/协议映射/allowlist/版本/文案/范围）｜ 依赖：全部 ｜ 输出：RC

### Gate RC 检查清单（§13.2）
- [ ] 空环境首次启动通过 ｜ CLI 缺失/不兼容/未登录提示通过
- [ ] 主对话多轮流式通过 ｜ 工具调用展示通过
- [ ] SEC-01~14 全部通过（回归）
- [ ] AI 文本与工具结果均可开支线 ｜ 三级嵌套通过 ｜ 长背景压缩成功+失败路径通过 ｜ 回流幂等通过
- [ ] 右侧标签与左侧树状态一致 ｜ 树→原文回跳通过 ｜ 双主线程隔离通过
- [ ] 子进程崩溃恢复通过 ｜ 应用重启恢复通过 ｜ 空库与已有库 migration 通过
- [ ] 日志脱敏检查通过 ｜ 兼容矩阵与 ADR 已更新
- [ ] 已知问题不含写权限绕过、数据丢失、会话串线
- [ ] §16 最终演示脚本 16 步可稳定重复执行

---

## 附录 A：决策点速查

| 编号 | 事项 | 关闭位置 | 产出 |
|---|---|---|---|
| DEC-01 | ACP Swift SDK 是否可用 | 任务 02 前（D1） | ADR-001 |
| DEC-02 | Rust FFI 最小边界 | 任务 03 触发时 | ADR-001 附录 |
| DEC-03 | 通过验证的 CLI/ACP 版本 | 任务 01（D1） | 兼容矩阵 |
| DEC-04 | session 是否支持恢复 | 任务 04（D1） | 恢复策略 |
| DEC-05 | 长背景压缩阈值 | 任务 05 记录 → 任务 29 定稿 | 配置与测试记录 |
| DEC-06 | 摘要 session 策略 | 任务 29 前 | ADR/实现说明 |
| DEC-07 | 锚点 start/length/hash | 任务 26 前 | ADR-003 + migration |
| DEC-08 | Markdown/高亮库 | 任务 21 前 | ADR-002 |
| DEC-09 | 树同级排序 | 任务 44 前 | ADR-004 |
| DEC-10 | 多主线程操作集合 | 任务 45 前 | Story 验收范围 |
| DEC-11 | ACP 额度查询能力 | B-M5 评估时，不阻塞 MVP | 能力记录 |

## 附录 B：跨阶段回归原则（§10.5）

- B-M2 完成后重跑 B-M1 主对话与崩溃测试；
- B-M3 完成后重跑 SEC 矩阵（支线 session 也过同一策略器）；
- B-M4 完成后测主线+支线在切线程时的事件路由；
- RC 前跑全链路，不得只测最新功能。

## 附录 C：进度日志

（每完成一个任务或工作日后在此追加：日期 / 完成项 / 通过的验收 / 新增风险 / 协议发现 / 次日第一任务）

- 2026-07-31：TODO.md 建成（50 任务 + G0~G4/RC 门槛 + DEC-01~11 线性化）；M1-001 本机探测完成（CLI 0.31.0、`acp` 子命令在、配置有效、凭据文件存在）；DEC-03 记入首行版本。下一任务：02. M1-002 Swift SDK 可用性验证（关联 DEC-01）。
- 2026-07-31（G0 收官）：任务 02/04/05 完成，G0 门槛 6 条过 5。产出：`spike/probe_acp.py`（协议探针）、`spike/samples/sanitized/`（9 类事件脱敏样本）、`spike/g0-findings.md`（结论报告）。关键结论：ACP v1 全链路通；读免审批、写/终端 permission 可拒且文件未落盘；session list/resume/load 全支持（DEC-04 关闭）；≤128KB 播种无失败点（DEC-05 数据落档）；stdin 关闭优雅退出、SIGTERM 无效；无官方 Swift SDK（DEC-01 证据齐）。消耗：10 个最小化 prompt 的会员额度。**阻塞：DEC-01 待用户拍板（推荐 rebornix/acp-swift-sdk PoC，备选手写 transport，不建议 Rust FFI）。**
- 2026-07-31（DEC-01 关闭）：用户拍板采用 rebornix/acp-swift-sdk；任务 06 完成，`adr/ADR-001-acp-client-path.md` 定稿（含兼容矩阵首行与回退触发条件）。**Gate G0 正式通过（6/6）**。下一任务：07. M1-007 Swift 骨架 + SDK PoC。
- 2026-07-31（M1-007 完成）：Swift 6.3.3 + SPM 工程骨架落地（Package.swift + App/Features/Core/Shared 四层 24 个占位文件），`swift build` 通过。acp-swift-sdk PoC 四核对点全部通过（`swift run schema-poc`，fixtures 为 G0 脱敏样本离线解码，未耗额度）。SDK 上游无 release tag，按 commit `b800b3f` 锁定（Package.resolved）；已知缺口 `configOptions[]` 未建模已记录。环境发现：本机仅 CLT 无 Xcode，测试框架不可用，PoC 暂以可执行目标承载。新增风险：SDK 无版本化管理，升级需人工核对 schema。下一任务：08. M1-008 子进程 Supervisor。
- 2026-07-31（环境就绪+开源）：用户安装 Xcode 26.6，PoC 迁回 swift-testing testTarget（`Tests/CoreTests`，7 测试全绿）。仓库以 MIT 开源推送至 <https://github.com/ruoshuqiu-plasmas/twig>；`.gitignore` 排除 spike/samples/raw 与原始日志。分支管理授权代理代管（短分支 + Conventional Commits + 合并 main 推送）。
- 2026-07-31（M1-008 完成，分支 feat/bm1-process-supervisor）：Supervisor 九态状态机 + CLIEnvironmentProbe + ACPProcessSupervisor 落地，14 个单元测试全绿（FakeCLI 脚本驱动，零额度消耗）。排坑记录：并行派生子进程的测试在 swift-testing 下因子进程 dyld 启动通知阻塞而假死超时（与代码无关，sample 实证），解法＝相关套件 `.serialized`；另遇 Process 运行中 dealloc 抛 NSException（解法＝返回前必等退出）。下一任务：09. M1-009 ACP transport 与 adapter。

- 2026-07-31（M1-009 完成，分支 feat/bm1-acp-adapter）：ACP transport 与 adapter 落地——`AgentEvent` 领域事件流（textDelta/thoughtDelta/toolCall/permission/notice/completed/failed/unknown）、`SupervisorTransport` NDJSON 行分帧、`ACPClient` 全链路封装（握手联动 supervisor 状态机、permission 默认 default deny）。34/34 测试全绿，连跑 6 次稳定，零额度消耗（fake agent bash 驱动）。排坑三条：SDK JSON 编码把 `/` 转义为 `\/` 导致 fake agent 匹配不到 method（测试挂死的根因）；testing-helper 同进程下孙进程 FD 泄漏卡死 EOF（supervisor deinit SIGKILL 兜底）；自制 withTimeout 不可用任务组（须非结构化竞速）。协议发现：SDK request id 混用数字与 UUID 字符串，fake agent 回显须两种都容忍。下一任务：10. M1-010 Session 管理与路由。
- 2026-07-31（M1-010 完成，M1-011 进行中，分支 feat/bm1-session-store）：任务 10 已提交（commit f2fb37b）——`SessionStore`（映射/路由/失效标记/持久化缝）+ `AgentEvent.sessionID` + FakeACPAgent.multiSession，39/39 全绿连跑 3 次。任务 11 代码已落地但**未编译验证、未提交**：Package.swift 引入 GRDB（`from: "7.11.1"`，Core/Shared/CoreTests 三 target）；`Shared/Models` 四记录类型（ConversationThread/Message/Branch/BranchNote + 枚举）；`Core/Persistence` AppDatabase（文件库/内存库）、Migrations v1（threads→branches→messages→branch_notes 四表 + §5.8 工程字段 + 索引 + 外键）、Repositories（ThreadRepository 实现 SessionMappingStore 缝、MessageRepository 插入/追加/状态/按 sequence 读）；`Tests/CoreTests/PersistenceTests.swift` 7 用例（migration 四表字段/幂等/外键、映射回环、消息生命周期、事务回滚）。**阻塞与恢复点**：本机代理对 GitHub HTTP/2 不稳（framing error/连接超时），GRDB 首次拉取失败两次；第三次重试用 `GIT_CONFIG_*=http.version=HTTP/1.1` 后台进行中（若再失败，备选＝`git clone --filter=blob:none` 手动播种 SPM 缓存，哈希与上游一致）。**继续工作的下一步**：① 确认 resolve 成功且 Package.resolved 含 GRDB 锁定版本；② `swift build` + `swift test` 全量回归（Persistence 7 用例为首跑）；③ 连跑 3 次稳定性；④ AGENTS.md §2/§3 GRDB 表述更新（锁定版本以 Package.resolved 为准）；⑤ 提交任务 11、合并 main、推送。注意：任务 10 提交后工作区还有未提交改动（Package.swift/Models/Persistence/PersistenceTests/TODO.md 台账），均属任务 11 范畴，勿丢弃。
- 2026-07-31（M1-011 完成，接前条）：依赖获取落地——github.com 大传输始终断流（ls-remote 小包正常），codeload 断点续传无效、浅克隆镜像 15 次重试均中途失败；最终用户手动下载官方 zip（v7.11.1，commit b83108d1），以 jsDelivr 官方清单 SHA-256 逐文件校验 229/229 一致后建本地镜像播种 SPM 缓存 + 四依赖 insteadOf 离线 resolve（配置已还原）。测试 46/46 全绿连跑 3 次。排坑两条：SQLite 外键开启时 CREATE TABLE 不得引用未创建的表（branches.anchor_message_id 与 messages.branch_id 循环引用 → anchor FK 不建，应用层保证）；GRDB 7 同步/异步同名重载在 async 上下文优先异步版。**⚠️ 推送前收尾（置顶进度指针同载）：Package.resolved 的 GRDB revision 351f0f6f 为本地合成哈希，网络稳定后须删除 .build 与 SPM 缓存中 GRDB 后 `swift package resolve` 换真实哈希 b83108d1，复跑测试再推送。** 下一任务：12. M1-012 主对话状态机与流式 UI。
