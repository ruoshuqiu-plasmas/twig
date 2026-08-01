# 分支对话面板 · 线性 TODO（执行清单）

> 来源：`doc/分支对话面板-开发文档.md`（v1.0，2026-07-25）、`doc/分支对话面板-开发流程.md`（设计规格，流程仪式自 2026-07-31 起降为参考，见该文首 v1.1 说明）
> 生成日期：2026-07-31 ｜ 执行者：Kimi Code（逐项执行，用户把关）

**状态约定**：`[ ]` 未开始 ｜ `[~]` 进行中 ｜ `[x]` 完成 ｜ `[!]` 阻塞（须记录原因）
**⑂ 条件分支**：仅当触发条件成立时执行，不占主线
**⬦ 决策点（DEC）**：硬决策（架构/数据模型/额度相关）到达前必须显式关闭并产出 ADR；琐碎决策直接在任务备注记录（免 ADR，见附录 A 标注）

**工作约定**（2026-07-31 精简版，取代原 Ready/Done 仪式）：
- 开工前明确该任务的验收条件；完成 = 测试绿 + 勾选更新 + 一行备注；
- 排坑与可复用知识记 `doc/工程笔记.md`，不写进本文件；
- 本文件是唯一执行面，每个任务只需动这里。

**▶ 当前进度**：**任务 20 已完成**（M2-006 拒绝 notice 与持久化：策略表文案透出 + notice 落库可回看 + 设置页只读策略，91 测试全绿）——下一项 `⬦ DEC-08` Markdown/高亮库选型（ADR-002，B-M2 前半关闭）→ `21. M2-007` Markdown 渲染方案验证

---

## B-M1：项目骨架、ACP 基础链路与主对话

> 阶段目标：应用启动 → 环境检测 → 子进程 → ACP 握手 → session → 发消息 → 流式接收 → 渲染并持久化。

- [x] ⬦ DEC-03：通过验证版本已记录（2026-07-31 实测握手）：**CLI 0.31.0 ｜ ACP v1（protocolVersion=1）｜ agent 侧 @agentclientprotocol/sdk@0.23.0** → 兼容矩阵首行（见 `spike/g0-findings.md` §2）
- [x] 01. **M1-001** CLI 存在、版本、`acp` 子命令、登录态探测 ｜ 依赖：无 ｜ 输出：`CLIEnvironmentProbe` 原型 + 版本记录 + 三类失败（缺失/不兼容/未登录）日志
  - 完成：CLI 0.31.0 于 `~/.kimi-code/bin/kimi`，`acp` 子命令在、登录态握手实测有效；Swift 版 CLIEnvironmentProbe 随任务 08 落地
- [x] ⬦ DEC-01：ACP Swift SDK（2026-07-31 拍板）：采用 **rebornix/acp-swift-sdk**，第一回退＝手写 NDJSON transport；Rust FFI 降为最后手段 → **ADR-001 已定稿**：`adr/ADR-001-acp-client-path.md`
- [x] 02. **M1-002** Swift SDK 可用性验证 ｜ 依赖：M1-001 ｜ 输出：SDK PoC（初始化/握手/session/收消息）
  - 完成：调研 + Python 探针 PoC 全通；Swift 侧 PoC 随任务 07 完成
- [ ] 03. ⑂ **M1-003** Rust FFI 备选验证（触发条件：DEC-01 选定的 Swift 方案失败；届时优先评估手写 transport 而非 FFI）｜ 输出：FFI PoC
  - ⬦ DEC-02：Rust FFI 最小边界（仅备选触发）→ ADR-001 附录
- [x] ⬦ DEC-04：ACP session 恢复能力（2026-07-31 实测）：`session/list` ✓、`session/resume` ✓（不重放）、`session/load` ✓（异步重放历史）；恢复策略记录于 `g0-findings.md` §2
- [x] 04. **M1-004** ACP 完整链路事件采样 ｜ 依赖：M1-002/003 ｜ 输出：脱敏事件样本（供测试替身）
  - 完成：9 类事件样本在 `spike/samples/sanitized/`（写/终端 permission 拒绝生效且文件未落盘；stdin 关闭 exit 0，SIGTERM 被忽略）
- [x] 05. **M1-005** 长背景新 session 播种验证 ｜ 依赖：M1-004 ｜ 输出：测试结论 + `TBD_CONTEXT_COMPRESSION_THRESHOLD`
  - 完成：4KB/32KB/128KB 三档全部 end_turn 无截断，session 历史隔离，无 usage 上报；DEC-05 定稿留 B-M3（任务 29）

### Gate G0 退出门槛 ✅ 已通过（2026-07-31）
- [x] 已选定实现路径（ADR-001：rebornix/acp-swift-sdk；第一回退＝手写 NDJSON transport）
- [x] 握手、session、文本流、permission request 均有真实样本
- [x] ACP 消息 framing 与关闭方式已明确（NDJSON；stdin EOF 优雅退出；SIGTERM 无效；SIGKILL 后 EOF 可观测）
- [x] session 枚举/恢复/续接能力已记录（list/resume/load 全支持，load 异步重放）
- [x] 长背景播种路径已验证（≤128KB 字符无失败点）
- [x] 未确认协议能力已列入「待验证清单」（`g0-findings.md` §8，共 7 项）并有保守回退方案

- [x] 06. **M1-006** ADR-001 定稿与版本兼容矩阵 ｜ 依赖：M1-001～005 ｜ 输出：架构结论 + 兼容矩阵首行
  - 完成：`adr/ADR-001-acp-client-path.md`（含被否决方案、回退触发条件、兼容矩阵首行）
- [x] 07. **M1-007** Swift 项目与模块骨架（App/Features/Core/Shared）｜ 依赖：M1-006 ｜ 输出：可构建工程
  - 完成：SPM 骨架 + acp-swift-sdk PoC 四核对点全过，SDK 按 commit `b800b3f` 锁定（上游无 tag）；已知缺口 `configOptions[]` 未建模
- [x] 08. **M1-008** 子进程 Supervisor（§5.5 状态机：notChecked…failed(reason)，有限重启+退避）｜ 依赖：M1-007 ｜ 输出：生命周期与状态机
  - 完成：Supervisor 九态 + CLIEnvironmentProbe + ACPProcessSupervisor（maxRestarts=3 + 退避，优雅停止＝关 stdin 超时升 SIGKILL），14 测试全绿；排坑见工程笔记（dyld 假死 → 套件须 `.serialized`）
- [x] 09. **M1-009** ACP transport 与 adapter（§5.6 `AgentEvent` 领域事件，未知事件保守记录）｜ 依赖：M1-008 ｜ 输出：领域事件流
  - 完成：`AgentEvent` 十类事件 + SupervisorTransport + ACPEventAdapter + ACPClient 落地，34/34 全绿；permission 默认 default deny 待 M2-005 接策略器；排坑见工程笔记（`\/` 转义、FD 泄漏、withTimeout）
- [x] 10. **M1-010** Session 管理与路由（session ↔ thread/branch 映射）｜ 依赖：M1-009 ｜ 输出：session 映射
  - 完成：`SessionStore`（映射/按 sessionID 事件 fan-out/子进程重启整表失效/持久化缝 SessionMappingStore），39/39 全绿
- [x] 11. **M1-011** GRDB 首版 migration（threads/messages/branches/branch_notes + §5.8 工程字段）｜ 依赖：M1-007 ｜ 输出：核心表与仓储
  - 完成：GRDB 7.11.1 + 四表 migration v1 + Thread/Message 仓储，46/46 全绿；GRDB 哈希已于 2026-08-01 修正为真实提交（见工程笔记）
- [x] 12. **M1-012** 主对话状态机与流式 UI（§5.7：发送即存、占位消息、delta 顺序追加、中断标记、跨线程路由）｜ 依赖：M1-009~011 ｜ 输出：主对话闭环
  - 完成：`ConversationStore`（五态+interrupted 状态机、节流落库、显式重试、每线程独立消费循环）+ `MainChatViewModel`/`MainChatView`（纯文本流式渲染）+ App 层真实接线，53/53 全绿；启动冒烟过（真实 CLI 0.31.0 握手成功、落库 Application Support、退出子进程随 stdin EOF 清理）；发送交互冒烟待用户 GUI 验证一轮
- [x] 13. **M1-013** 中断、重启、错误页面（CLI 缺失/版本不兼容/未登录三态区分）｜ 依赖：M1-008~012 ｜ 输出：恢复路径
  - 完成：`StartupIssue` 三态映射 + 引导页（安装/升级/登录命令依官方文档）；断连监听（restarting/failed → markAllStale + interruptAll）+ 自动重连重建 session（不做续接假象）；登录失效走协议错误关键词兜底（形态待验证）；57/57 全绿 + SIGKILL 恢复冒烟通过
- [x] 14. **M1-014** B-M1 自动与手工验收 ｜ 依赖：全部 ｜ 输出：G1 证据 + 测试报告
  - 完成：`doc/G1-验收报告.md`（十条全过）；新增 `RealCLIIntegrationTests`（真实 CLI 两线程并发不串线，`TWIG_REAL_CLI=1` 才跑，默认跳过防额度消耗）；G1-04 失效兜底路径形态待验证已如实记录

### Gate G1 验收场景（§5.10，逐条执行）✅ 已通过（2026-08-01，证据见 `doc/G1-验收报告.md`）
- [x] G1-01 CLI 已装已登录 → 进入可对话状态
- [x] G1-02 CLI 缺失 → 安装引导，不崩溃
- [x] G1-03 CLI 不支持 acp → 版本不兼容提示
- [x] G1-04 登录失效 → 登录引导（凭据在但过期的兜底路径形态待验证，报告已记录）
- [x] G1-05 创建主线程发消息 → 连续流式文本
- [x] G1-06 流式中切换线程再切回 → 写入正确线程（切回 UI 归 M4-007，能力已验证）
- [x] G1-07 流式中杀死子进程 → 消息标记中断，可恢复
- [x] G1-08 重启子进程 → 可新 session；旧 session 续接按实测能力处理
- [x] G1-09 退出重开应用 → 本地线程消息仍在
- [x] G1-10 收到未知协议事件 → 不崩溃，保守记录

---

## B-M2：工具调用、权限策略与富文本渲染

> 阶段目标：工具行为可视化、可审计；第一阶段绝对只读。

- [x] 15. **M2-001** 工具事件领域模型（requested→running→succeeded/failed/denied，稳定 call id 关联）｜ 依赖：M1-009 ｜ 输出：工具生命周期
  - 完成：`ToolCallStatus`/`ToolCallRecord`/`ToolCallTracker`（稀疏合并、累积快照替换、单调状态、denied 派生含 markDenied 显式口），9 用例全绿；协议事实（累积快照/无 denied 状态）已补记 g0-findings §4
- [x] 16. **M2-002** 工具调用折叠卡片（工具名/参数摘要/状态/结果摘要；大结果默认折叠；可持久化回看）｜ 依赖：M2-001 ｜ 输出：折叠 UI
  - 完成：ConversationStore 接线（ToolCallTracker 进 ThreadContext，一次调用一条 kind=tool_call 消息，record JSON 入 metadata_json，节流+终态强制落库，中断一并收口）+ ToolCallCard（五态徽标配色、路径摘要、超 400 字默认折叠）+ MessageRow 按 kind 分支渲染（解码失败回退纯文本）
- [x] 17. **M2-003** 权限类型映射（协议工具/权限类型 → 内部操作分类，基于真实样本）｜ 依赖：M1-004 ｜ 输出：映射表
  - 完成：`ToolOperationClassifier`（七类操作；kind 优先 read/edit/execute，title 兜底 Read/Write/Bash/Edit/Terminal，映射来源注明 perms/terminal 脱敏样本；未知 kind→unknown、字段全缺→unparseable）
- [x] 18. **M2-004** PermissionPolicyEngine（allowlist 仅读文件/列目录/搜索；其余一律默认拒绝，含未知与无法解析）｜ 依赖：M2-003 ｜ 输出：allowlist/default deny
  - 完成：纯函数 `decide(operation:options:)`（allowlist 选 allow_once、其余选 reject_once 回 selected+optionId，缺档兜底 cancelled；决策带脱敏 reason）；SEC-04~11/14 单测逐条覆盖
- [x] 19. **M2-005** ACP permission 响应接入（回调只进策略器，返回合规批准/拒绝响应）｜ 依赖：M2-004 ｜ 输出：实际批准/拒绝
  - 完成：ACPClient 内置「per-session ToolCallTracker 查 kind → Classifier → PolicyEngine」默认链路（拒绝时 markDenied；permissionHandler 仍可注入替换）；fake agent 集成测试验证 Write 回 selected+reject optionId（optionId 不硬编码）
- [x] 20. **M2-006** 拒绝 notice 与持久化（对话流标注「已按只读策略拦截」；设置页只展示不修改）｜ 依赖：M2-002/005 ｜ 输出：透明展示
  - 完成：`ToolOperation.denialNoticeText` 策略表文案（策略层统一来源）+ `AgentEvent.toolCallDenied`（ACPClient 拒绝/兜底取消一律广播，「没放行就有标注」）+ ConversationStore 卡片立即收口 denied 强制落库、notice 消息（kind=notice，metadata 记 operation/toolCallID 不记内容）即时落库可回看（SEC-12/13 数据面）+ MessageRow notice 渲染 + Settings scene 只读策略页（⌘,）；91 测试全绿
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

## B-M3：支线创建、嵌套、回流与右侧面板

> 阶段目标：选中原文 → 追问 → 组装背景 → 独立 ACP session → 支线流式 → 可嵌套 → 可回流。

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

## B-M4：左侧对话树、原文回跳、多线程与恢复

> 阶段目标：本地线程/支线/锚点组织成可导航树；重启后结构不丢。

- [ ] 39. **M4-001** 树查询与环/孤儿保护（无效 parent_branch_id 检测记录、不无限递归；流式 delta 不触发整树重建）｜ 依赖：M3-009 ｜ 输出：树模型
- [ ] 40. **M4-002** 左侧卡片式缩进树（根=主线程，支线缩进挂父节点；折叠只隐藏不改数据）｜ 依赖：M4-001 ｜ 输出：树 UI
- [ ] 41. **M4-003** 节点卡片信息（首问摘要/轮数/时间/open/merged/closed/已回流/选中态；空摘要用锚点引文占位）｜ 依赖：M4-001/002 ｜ 输出：节点信息
- [ ] 42. **M4-004** 树节点 → 支线标签联动（点击激活/打开对应右侧标签）｜ 依赖：M3-007/M4-002 ｜ 输出：导航
- [ ] 43. **M4-005** 树 → 原文回跳高亮（与引文点击行为一致；高亮后不改写选区）｜ 依赖：M3-010/M4-004 ｜ 输出：核心体验
- [ ] ⬦ DEC-09：同级排序规则（建议创建时间或最近活动）→ **免 ADR**，决策直接记入任务 44 备注（B-M4 前关闭）
- [ ] 44. **M4-006** 同级排序落地 ｜ 依赖：M4-001 ｜ 输出：固定规则
- [ ] ⬦ DEC-10：多主线程第一阶段操作集合（最低：创建/列表/切换/独立 root/最近排序/恢复选中）→ **免 ADR**，决策直接记入任务 45 备注（B-M4 前关闭）
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
| DEC-01 | ACP Swift SDK 是否可用 | ✅ 已关闭 | ADR-001 |
| DEC-02 | Rust FFI 最小边界 | 任务 03 触发时 | ADR-001 附录 |
| DEC-03 | 通过验证的 CLI/ACP 版本 | ✅ 已关闭 | 兼容矩阵 |
| DEC-04 | session 是否支持恢复 | ✅ 已关闭 | 恢复策略 |
| DEC-05 | 长背景压缩阈值 | 任务 29 定稿 | ADR/实现说明 |
| DEC-06 | 摘要 session 策略 | 任务 29 前 | ADR/实现说明 |
| DEC-07 | 锚点 start/length/hash | 任务 26 前 | ADR-003 + migration |
| DEC-08 | Markdown/高亮库 | 任务 21 前 | ADR-002 |
| DEC-09 | 树同级排序 | 任务 44 前 | **免 ADR**，TODO 备注记录 |
| DEC-10 | 多主线程操作集合 | 任务 45 前 | **免 ADR**，TODO 备注记录 |
| DEC-11 | ACP 额度查询能力 | B-M5 评估时，不阻塞 MVP | 能力记录 |
