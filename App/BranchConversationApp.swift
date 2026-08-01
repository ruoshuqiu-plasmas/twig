import SwiftUI
import AppKit
import Core
import Features

/// 应用入口（任务 M1-012 起为真实主对话界面）。
/// 启动流程：装配 AppEnvironment → 事件路由/子进程/握手（``AppEnvironment/start()``）→ 进入主对话。
/// CLI 缺失/版本不兼容/未登录三态引导页归 M1-013，此处仅简版错误页 + 重试。
@main
struct BranchConversationApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var viewModel: MainChatViewModel?
    @State private var startupError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let viewModel {
                    MainChatView(viewModel: viewModel)
                } else if let startupError {
                    startupErrorView(startupError)
                } else {
                    ProgressView("正在连接 Kimi Code CLI…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .task { await startUp() }
        }
    }

    private func startUp() async {
        guard viewModel == nil, startupError == nil else { return }
        do {
            let environment = try AppEnvironment.make()
            appDelegate.environment = environment
            try await environment.start()
            // B-M1 临时方案：project_root 取进程工作目录（M4-007 提供选择入口）。
            let cwd = FileManager.default.currentDirectoryPath
            let projectRoot = cwd == "/" ? NSHomeDirectory() : cwd
            viewModel = MainChatViewModel(store: environment.conversationStore, projectRoot: projectRoot)
        } catch {
            startupError = error.localizedDescription
        }
    }

    private func startupErrorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text("无法连接 Kimi Code CLI")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Button("重试") {
                startupError = nil
                Task { await startUp() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 应用生命周期：退出时优雅停止 ACP 子进程（关 stdin，G0 实测语义）。
/// `applicationWillTerminate` 无法 async 等待，用信号量限时同步（正常为毫秒级）。
final class AppDelegate: NSObject, NSApplicationDelegate {

    var environment: AppEnvironment?

    /// 裸可执行文件（无 .app bundle/Info.plist）默认按 accessory 策略运行，
    /// 窗口无法成为 key window，键盘焦点留在终端——须显式改为 regular 并激活。
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let environment else { return }
        let done = DispatchSemaphore(value: 0)
        Task {
            await environment.shutdown()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 3)
    }
}
