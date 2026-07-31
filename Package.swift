// swift-tools-version: 6.0
// 分支对话面板 · Swift 6 + SPM 工程骨架（任务 M1-007）
// 分层结构依据 doc/分支对话面板-开发流程.md §5.4：
//   App（可执行入口）→ Features（界面功能）→ Core（ACP/进程/策略/支线/持久化）→ Shared（模型/组件/日志/测试支撑）
import PackageDescription

let package = Package(
    name: "BranchConversation",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BranchConversation", targets: ["App"])
    ],
    dependencies: [
        // ADR-001：rebornix/acp-swift-sdk。上游尚无版本 tag（仅 main 分支），
        // PoC 阶段按 commit 锁定（2026-07-31 实测 main HEAD），待上游发布 1.0.0 后转 from: 语义版本。
        .package(url: "https://github.com/rebornix/acp-swift-sdk.git",
                 revision: "b800b3f2c251e3453fdd10172d671123e1908301"),
        // SDK 的 Transport/Client 协议要求 swift-log；显式声明直接依赖以便 import Logging。
        .package(url: "https://github.com/apple/swift-log.git", from: "1.14.0")
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: ["Features", "Core", "Shared"],
            path: "App"
        ),
        .target(
            name: "Features",
            dependencies: ["Core", "Shared"],
            path: "Features"
        ),
        .target(
            name: "Core",
            dependencies: [
                "Shared",
                .product(name: "ACP", package: "acp-swift-sdk"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Core"
        ),
        .target(
            name: "Shared",
            path: "Shared"
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: [
                "Core",
                .product(name: "ACP", package: "acp-swift-sdk")
            ],
            path: "Tests/CoreTests",
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
