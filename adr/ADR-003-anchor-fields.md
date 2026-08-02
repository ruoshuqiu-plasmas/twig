# ADR-003：支线锚点字段方案

> 状态：**已决定**（2026-08-02，DEC-07 关闭）
> 决策人：用户（任务 M3-002 落地：migration v2 + Branch 模型 + AnchorResolver）

## 结论

branches 表新增三个 nullable 列：**anchor_start / anchor_length / anchor_context_hash**（migration `v2-anchor-coordinates`，只 ALTER TABLE 追加列，**不重建表、不补 FK**——anchor_message_id 的循环引用问题见 migration v1 注释，SQLite ALTER 亦不支持加 FK，锚点关系继续由应用层保证）。

**坐标语义**：

- `anchor_start` / `anchor_length`：相对锚点消息**渲染后纯文本**（Markdown 块渲染产物的 `NSAttributedString.string`，渲染确定性保证可复现）的偏移，**不是原始 markdown 源**；代码约定为 Swift Character 偏移（见 `AnchorResolver` 注释，消费端如需 UTF-16 自行换算）；
- `anchor_context_hash`：锚点消息渲染后纯文本的 **SHA256 前 16 位 hex**（CryptoKit），用于检测原文是否变化；
- **重复引文消歧不另设「出现序号」列**：start 本身即定位；坐标失效时按 quote 在纯文本中搜索，多处出现取第一个并标注 ambiguous（序号同样会被文本插入打乱，存了也不可靠）。

**回跳解析规则**（`Core/Branching/AnchorResolver.swift`，纯函数，供 M3-010 树→原文回跳消费；输入为 branch 锚点字段 + 该消息当前渲染后纯文本）：

1. start/length 非空、在范围内、且切片 == quote → `.exact`；
2. 否则若 contextHash 与纯文本指纹匹配：搜索 quote，唯一命中 → `.exact`，多处命中取第一个 → `.exact(ambiguous: true)`；
3. 其余一律 → `.degradedToMessage`（hash 不匹配、quote 找不到或 quote 为空，降级到消息整体高亮）。

## 背景与问题

- **重复引文**：同一 quote 在一条消息中可出现多次，仅靠 quote 无法唯一定位，回跳会跳错位置；
- **Markdown 源 ≠ 渲染文本**：用户选区发生在渲染层，以原始 markdown 源为基准的坐标须做源/渲染偏移换算（围栏代码块、列表符号、引用前缀都会错位），脆弱且不可维护；
- **原文可能变化**：消息重试/编辑或渲染管线升级后，坐标与 quote 都可能失效，需要指纹检测原文变化，并提供明确的降级路径，而不是高亮到错误位置。

## 被否决方案

| 方案 | 否决原因 |
|---|---|
| 只用 quote + 降级规则 | 重复引文无法消歧，回跳命中率低；消息越长越容易跳错 |
| 以原始 markdown 源为坐标基准 | 选区发生在渲染层，源/渲染偏移换算脆弱（代码块、列表、引用块均会错位） |
| 补 FK / 重建 branches 表 | v1 注释已说明 anchor_message_id 与 messages.branch_id 循环引用；SQLite ALTER 不支持加 FK，重建表代价与数据迁移风险不值得，应用层保证已足够 |
| 另存「出现序号」列 | 冗余：start 即定位；坐标失效场景下序号同样被文本插入打乱，不比「多处取第一个」更可靠 |

## 回退触发条件

1. 实测坐标命中率仍低（如渲染管线块切分不稳定）→ 评估改为「渲染块索引 + 块内偏移」二级坐标，重开 DEC-07；
2. 消息可编辑需求落地 → 重开 DEC-07 评估版本化锚点（每次编辑生成新指纹与坐标）；
3. SHA256 前 16 位 hex 出现实际碰撞问题（可能性极低）→ 加长指纹，新增 migration 迁移旧值。

## 已知限制（不阻塞）

- 渲染管线升级（块切分或渲染规则变化）会使旧支线 hash 不匹配 → 自动走 quote 搜索或降级消息级高亮，属设计内行为，不视为数据损坏；
- 坐标为 Character 偏移约定；NSTextView 选区层（M3-010）消费时须换算 UTF-16 偏移，换算逻辑归渲染层；
- v1 时期已存在的支线三列为 NULL，回跳直接走规则 2/3（hash 为空即不匹配 → 降级），无需数据回填。
