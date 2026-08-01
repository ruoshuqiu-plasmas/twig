# ADR-002：Markdown 渲染与代码高亮方案

> 状态：**已决定**（2026-08-01，DEC-08 关闭）
> 决策人：用户（依据本文「依据」五要素调研结论）

## 结论

采用**块级自渲染管线**：**Apple `swift-markdown`（Apache-2.0）做 Markdown 块级解析** → SwiftUI 块级视图渲染；**`raspu/Highlightr` 2.3.x（MIT，内核 highlight.js 为 BSD）做代码块语法高亮**。

渲染管线（对应流程文档 §6.5）：

1. 流式阶段（`status == .streaming`）保持纯文本 + 光标，先保文本持续可见，不做增量解析；
2. 消息进入稳定态（completed/interrupted/failed）后对完整文本做一次 swift-markdown 解析，切成块数组（段落/标题/引用/列表/围栏代码块）；
3. 代码块用 Highlightr 产出 `NSAttributedString` → `AttributedString` 渲染，等宽字体 + 语言小标；
4. 所有块（段落/引用/列表/代码块）保留 `.textSelection(.enabled)` 选区能力；
5. **超长代码块（> 阈值）跳过昂贵高亮**，直接等宽纯文本；解析或高亮任何异常一律回退纯文本，不丢内容、不崩溃。

**锁定方式**：`Package.swift` 按 release tag 锁定（swift-markdown 与 Highlightr 均有正式 tag），具体解析结果以 `Package.resolved` 为准；升级时须重跑渲染单测与 G2 相关用例。

## 依据（决策五要素，对应流程文档 §6.5「待决策」）

| 要素 | 结论 |
|---|---|
| SwiftUI 集成 | Highlightr 输出 `NSAttributedString`，可直接转 `AttributedString` 喂给 SwiftUI `Text`；块级自渲染让段落/引用/列表/代码块各自成 View，天然适配 SwiftUI 布局与选区 |
| 增量渲染性能 | 流式不解析（纯文本）；解析只在消息稳定后执行一次；Highlightr 基于 JavaScriptCore，单次调用成本可控但不为流式 delta 反复调用；超长块阈值熔断 |
| 语言覆盖 | highlight.js 约 185 种语言（AI 回答代码块语言不可预知，覆盖广度是硬需求）；Splash 基本只覆盖 Swift |
| 维护状态 | Highlightr 曾停更，2025 年恢复维护（2.2.0 引入 SPM，2.3.0 升级 highlight.js v11.11.1，2025-06）；swift-markdown 为 Apple 官方维护 |
| 许可证 | Highlightr MIT + highlight.js BSD-3 + swift-markdown Apache-2.0，与本项目 MIT 兼容 |

## 被否决方案

| 方案 | 否决原因 |
|---|---|
| Splash（JohnSundell） | 语法覆盖基本仅 Swift，AI 对话代码块语言不可预知时不合格；最近 release 约五年前，维护停滞 |
| MarkdownUI（gonzalezreal/swift-markdown-ui） | 整段渲染为单一视图树，块级选区与 B-M3 锚点定位（NSTextView 选区层、重复引文降级）控制力差；上游已进入维护模式，新开发转向 Textual |
| Textual（gonzalezreal） | MarkdownUI 继任者，但过新、API 与生态未稳，第一阶段不冒进 |
| AttributedString(markdown:) 内建解析 | 无代码块语言标注提取能力，块级结构不可控，无法满足块级选区与代码块独立渲染需求 |

## 回退触发条件

1. Highlightr 再度停更且出现阻塞性 bug，或 JavaScriptCore 在目标 macOS 版本出现兼容问题 → 换 Splash（仅 Swift 块高亮）或纯等宽无高亮，ADR 记录降级；
2. swift-markdown API 大版本不兼容 → 解析层为纯函数边界（`MarkdownBlockParser`），可整体替换为其他 GFM 解析器；
3. 实测高亮耗时影响长回答渲染 → 收紧阈值或改为按需高亮（展开时才高亮）。

## 已知限制（不阻塞）

- Highlightr 依赖 JavaScriptCore 运行时，初始化有固定开销；首次使用时预热，高亮调用限定在代码块完成态；
- 增量（流式中）渲染不做 Markdown 结构解析，流式中的代码块不高亮，待消息稳定后一次性升级渲染——为 §6.5 允许的取舍；
- AppKit 选区层（B-M3 M3-001）落地时须复查「选区层与渲染层不得互覆」（§6.5 第 5 条）。
