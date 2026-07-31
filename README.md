# twig · 分支对话面板

macOS 原生桌面应用（Swift + SwiftUI），作为 **ACP（Agent Client Protocol）客户端**驱动本机的 Kimi Code CLI（`kimi acp` 子进程），消耗 Kimi Code 会员额度而非 API token 计费。

核心特色：**选中 AI 回答或工具调用结果中的任意文字，就地开启支线对话**（独立 ACP session，可嵌套、可将结论回流主线），配合左侧卡片式对话树与右侧支线标签栏——就像从主干上随手掰下一根细枝（twig）。

> 当前状态：早期开发中。已完成 G0 协议验证与 Swift 工程骨架（含 acp-swift-sdk schema PoC），功能界面尚未实现。执行台账见 [TODO.md](TODO.md)。

## 构建

要求：Swift 6+（Command Line Tools 或 Xcode），macOS 14+。

```bash
swift build                  # 构建全部目标
swift run BranchConversation # 启动应用（当前为骨架占位窗口）
swift run schema-poc         # ACP SDK schema 离线验证（fixtures 来自脱敏协议样本）
```

## 仓库结构

- `App/` `Features/` `Core/` `Shared/` — Swift 工程四层（SPM target 与目录一一对应）
- `PoC/SchemaPoC/` — acp-swift-sdk schema 验证（可执行目标）
- `doc/` — 产品文档与开发流程（简体中文）
- `adr/` — 架构决策记录
- `spike/` — G0 协议探针（Python 3，stdlib-only）与脱敏协议样本
- `AGENTS.md` — 面向 AI 编码代理的项目说明（结构、约束、测试策略）

## 许可证

[MIT](LICENSE)
