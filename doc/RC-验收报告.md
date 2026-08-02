# RC 验收报告 · 任务 M4-012（全量回归与候选构建）

> 日期：2026-08-02 ｜ 执行：Kimi Code（自动回归）+ 用户（GUI 验收）
> 依据：`doc/分支对话面板-开发流程.md` §13（候选版本与发布流程）、§16（最终演示脚本）
> 基线文档：`doc/G1-验收报告.md`、`doc/G2-验收报告.md`、`doc/G3-验收报告.md`、`doc/G4-验收报告.md`

**构建信息**：commit `13eab6d`（main）｜ Swift 6.3.3 ｜ 最低 macOS 14 ｜ Kimi Code CLI **0.31.1**（`~/.kimi-code/bin/kimi`）｜ ACP v1（protocolVersion=1）｜ acp-swift-sdk @ `b800b3f` ｜ GRDB 7.11.1 ｜ swift-markdown 0.8.0 ｜ Highlightr 2.3.0

---

## 一、RC 前冻结核对（§13.1）

冻结后只允许修复阻断问题、安全问题和数据损坏问题。六项冻结内容核对如下：

| 冻结项 | 内容 | 核对结果 |
|---|---|---|
| 数据库 schema | migration v1（threads/branches/messages/branch_notes 四表 + 两索引，`Core/Persistence/Migrations/Migrations.swift:21-80`）+ v2（branches 追加 anchor_start/anchor_length/anchor_context_hash 三 nullable 列，:86-92）。已发布 migration 不改、只追加 | ✅ 冻结 |
| ACP adapter 协议映射 | `AgentEvent` 11 类领域事件（`Core/ACP/AgentEvent.swift:10-34`）；`ACPEventAdapter` 逐类映射 + 未知事件保守记录（`Core/ACP/EventAdapter/ACPEventAdapter.swift`）；`TwigSessionLoad` 自定义 session/load 绕过 SDK 两处不兼容（`Core/ACP/Client/TwigSessionLoad.swift:11-46`） | ✅ 冻结 |
| 权限 allowlist | 唯一放行集 `[.readFile, .listDirectory, .search]`（`Core/Policy/PermissionPolicyEngine.swift:24`）；其余含 unknown/unparseable 一律 default deny；分类规则 kind 优先 title 兜底（`Core/Policy/ToolOperationClassifier.swift:34-58`）；全仓无第二处放行路径、无 allow_always 消费 | ✅ 冻结 |
| 已验证 CLI/ACP/SDK 版本 | CLI 0.31.0（G0 基线）/ 0.31.1（M4 起实测）；ACP v1；agent sdk@0.23.0；acp-swift-sdk @ b800b3f；依赖全锁 Package.resolved | ✅ 冻结（兼容矩阵已补 0.31.1，见 §五） |
| 核心 UI 文案 | 拒绝 notice（PermissionPolicyEngine.swift:60-71）；启动三态引导（App/BranchConversationApp.swift:215-260）；session 恢复横幅四态（MainChatViewModel.swift:229-245）；设置页只读策略（SettingsView.swift:11-28）；支线生命周期（BranchPanelView.swift:213/274-351） | ✅ 冻结 |
| B-M1～B-M4 功能范围 | 主对话/只读安全/支线嵌套回流/树与多线程与恢复；第一阶段非目标（写能力、协作、云同步、多平台、画布、历史导入、签名公证）无代码入口 | ✅ 冻结 |

## 二、全量自动回归（fake 层）

- `swift test` 全量（默认不含真实 CLI）：**238 测试 / 42 套件全部通过**（2026-08-02，含 G4 后合入的 2 个树点击回归修复测试）。
- 覆盖：SEC-01~14、BR-01~18、TREE/THREAD/REC 的 fake 层全部用例，无「暂时跳过」。

## 三、真实 CLI 全量回归（TWIG_REAL_CLI=1，用户 2026-08-02 批准额度）

`TWIG_REAL_CLI=1 swift test --filter RealCLIIntegrationTests`：**6/6 全部通过**（2026-08-02，82.5s，CLI 0.31.1）：

| 用例 | 覆盖 | 结果 |
|---|---|---|
| 两线程并发流式不串线 | G1-05/06 | ✅ 11.6s |
| 写文件被只读策略拒绝，文件未落盘且对话续行 | SEC-04/05/06/12 真实链路 | ✅ 7.3s |
| 支线创建/追问/嵌套/回流全生命周期 | BR-05/08/09/13/14 | ✅ 25.4s |
| 背景超阈值走真实摘要压缩 | BR-10 | ✅ 9.7s |
| 重启后 session/load 续接成功 | REC-01 | ✅ 23.3s |
| session 不可续接时降级新建 | REC-02 | ✅ 5.2s |

## 四、RC 检查清单逐条（§13.2）

| 条目 | 结论 | 证据 |
|---|---|---|
| 空环境首次启动流程通过 | ⏳ 用户 GUI | 引导页三态见 G1 报告；空环境首启走 GUI 脚本步骤 1 |
| CLI 缺失/不兼容/未登录提示通过 | ✅ | G1-02/03/04（`doc/G1-验收报告.md`）；G1-04 限制见 §六已知问题 |
| 主对话多轮与流式通过 | ✅ | G1-05/06；本次真实 CLI 回归（§三） |
| 工具调用展示通过 | ✅ | M2-002 卡片 + G2 工具卡实时/重启一致性 |
| SEC-01~14 全部通过（回归） | ✅ | G2 逐条证据 + 本次 fake 238 全绿 + 真实 CLI 写拒绝回归（§三） |
| AI 文本和工具结果都可创建支线 | ✅ | BR-01/02（G3 报告） |
| 三级嵌套支线通过 | ✅ | BR-09（fake 三级 + 真实 CLI 两级） |
| 长背景压缩成功和失败路径通过 | ✅ | BR-10/11（真实 CLI 摘要路径 + 失败零截断） |
| 回流幂等通过 | ✅ | BR-14（`.alreadyMerged` 零写入，真实 CLI 实测） |
| 右侧标签和左侧树状态一致 | ✅ | TREE-03/04 + G4 附加（面板↔树双向同步） |
| 树 → 原文回跳通过 | ✅ | TREE-03/07/08（AnchorResolver 三级降级管线） |
| 两个主线程并行状态隔离通过 | ✅ | THREAD-01/02（快速切换压测不串线） |
| 子进程崩溃恢复通过 | ✅ | G1-07/08 + REC-04；SIGKILL 恢复冒烟 |
| 应用重启恢复通过 | ✅ | G1-09 + BR-18 + THREAD-04 + REC-01/02 |
| 空库和已有测试库 migration 通过 | ✅ | REC-03（损坏库不损原文件 + migration 幂等） |
| 日志脱敏检查通过 | ✅ | 日志仅事件类型/脱敏 id/耗时/状态/错误码（决策日志见 §二输出样式）；permission 拒绝日志只留分类与原因 |
| 兼容矩阵和 ADR 已更新 | ✅ | §五；g0-findings §2 已补 0.31.1；ADR-001 矩阵新增 RC 行 |
| 已知问题不含写权限绕过、数据丢失、会话串线 | ✅ | §六已知问题清单逐条核对，三类均无 |

## 五、版本兼容矩阵更新

ADR-001 附表新增行：

| App 版本 | Kimi Code CLI | ACP/Agent 侧 SDK | 握手 | session | stream | permission | resume | 结论 |
|---|---|---|---|---|---|---|---|---|
| twig rc-1（acp-swift-sdk @ b800b3f + TwigSessionLoad） | 0.31.1 | ACP v1 / sdk@0.23.0 | ✓ | ✓（new/load/list；load 经 TwigSessionLoad 绕过 mcpServers 必填 + 响应无 sessionId 两处不兼容） | ✓ | ✓（写/终端拒绝实测） | ✓（load 异步重放续接 / 不可用降级） | 通过 2026-08-02 |

## 六、已知问题清单（不阻塞 RC，均非写权限绕过/数据丢失/会话串线）

1. **G1-04 兜底路径形态未采样**：凭据在但登录过期走协议错误关键词兜底（`StartupIssue.isAuthRelated`），真实失效错误形态未采样（G0 待验证项）。
2. **configOptions 未建模**：kimi 扩展字段（模型/思考档位）SDK 未建模，静默丢弃；不影响功能（ADR-001 已知缺口）。
3. **usage 不可查询**：协议内无额度查询能力（DEC-11，B-M5 评估，不阻塞 MVP）。
4. **浮动追问入口为右下角固定胶囊**：贴选区 firstRect 定位列工程候选（G3 已知限制 1）。
5. **回跳高亮为整消息级**：exact 范围级高亮为 stretch，回调载荷已留口（G3 已知限制 2）。
6. **session/close、logout 未实现**（CLI 侧 -32601）：应用不调用，进程随 stdin EOF 清理（g0-findings §2）。
7. **ToolCallCard 折叠态选区坐标**相对截断文本，锚点消费侧以 quote 匹配为主（G3 已知限制 5）。

## 七、GUI 验收脚本（用户执行）

> 构建产物与启动方式见 §八。建议按顺序执行；每项标注通过/失败/备注，反馈后回填本报告。

### A. RC 清单 GUI 项

1. **空环境首次启动**：（可选）先退出应用并重命名 `~/Library/Application Support/` 下本应用数据目录做备份，再启动 → 应直接进入可对话状态（CLI 已装已登录）；新建线程发一条消息验证。
2. **启动异常三态**（可选，需临时改环境）：CLI 缺失/未登录提示在 G1 已验证，此处可不重复。
3. **设置页**（⌘,）：只读展示 allowlist 三项 + default deny 说明，无修改入口。
4. **日志脱敏抽查**：`log show --predicate 'subsystem BEGINSWITH "twig"' --last 10m`（或 Console.app），确认无完整提问/回答/文件内容落日志。

### B. §16 最终演示脚本（16 步，连续执行）

1. 启动应用，环境检测通过；
2. 选择一个项目根目录并创建主线程；
3. 向 Kimi Code 发起问题，观察流式 Markdown 和代码块；
4. 触发一个读文件或搜索工具调用（如「读一下 README.md」），观察工具卡片；
5. 触发写文件或终端意图（如「把结果写入 a.txt」/「跑一下 ls」），观察自动拒绝和可见标注；
6. 在 AI 回答中选中一段文字，点击「追问」创建支线；
7. 在支线中继续两轮对话；
8. 在支线回答中再次选中文字，创建嵌套支线；
9. 从左侧树点击嵌套节点，主对话回跳并高亮锚点；
10. 将一级或二级支线结论合并回主线；
11. 确认主线出现带来源的补充笔记，树节点显示「已回流」；
12. 创建第二个主线程并发起对话；
13. 在线程间切换，确认消息和支线不串线；
14. 关闭并重启应用；
15. 确认线程、消息、支线树、锚点和回流状态恢复；
16. 确认旧 session 已续接（横幅「已续接」）或明确展示不可续接的降级状态。

### C. G4 遗留 GUI 冒烟（如时间允许）

- 左栏三栏布局同时呈现；树节点缩进/卡片信息/选中态；折叠只隐藏子树；
- 树节点点击 → 右侧标签激活 + 主对话滚动高亮；
- 「+」新建对话 sheet（标题可空 + 文件夹选取）；双击线程就地重命名；
- 支线超 10 轮出现「合并并关闭」提示；拒绝 notice 重启后仍可回看。

## 八、候选构建归档（§13.3 回滚原则）

- 归档位置：`dist/twig-rc-1/`（`BranchConversation` 二进制 + `MANIFEST.md`，dist/ 已入 .gitignore 不入库）
- 构建：commit `13eab6d76b49b64f4dd03b9141b2abeea5dd8ea6`（main），`swift build -c release`，2026-08-02 18:18
- SHA256：`2c232fe449acc424da54b02cfa4a4dc28b841a2c1284c8d210493a330a9b18b8`
- 启动冒烟：release 二进制启动后存活、握手 Kimi Code CLI v0.31.1 成功、退出后无孤儿 `kimi acp` 进程（2026-08-02 实测）
- 启动方式：`./dist/twig-rc-1/BranchConversation`（需 CLI 已装已登录；无签名公证，本地自用）
- 回滚：本归档即首个可用本地构建，后续版本失败时回退此目录；数据库 migration 已有失败不损原库保护（REC-03）

## 九、结论

**自动化部分全部通过**：六项冻结内容核对完毕；fake 层 238/238 全绿；真实 CLI 6/6 全过（CLI 0.31.1）；RC 检查清单 17/18 条有证据（「空环境首次启动」列 GUI 脚本步骤 1 待用户执行）；已知问题 7 条均非写权限绕过/数据丢失/会话串线；候选构建已归档并通过启动冒烟。

**待用户 GUI 验收**：按 §七脚本（A 四项 + B 十六步 + C 七项）执行并反馈，全部通过后勾选 TODO.md 的 Gate RC 清单、任务 50 收官，第一阶段完成。
