import SwiftUI
import AppKit
import Logging
import Core
import Features

/// 应用入口（任务 M1-012 起为真实主对话界面，M1-013 起含三态错误页与断连恢复）。
/// 启动流程：装配 AppEnvironment → 环境检测（三态引导）→ 子进程/握手 → 进入主对话；
/// 运行期：监听 supervisor 状态，异常退出 → 标记中断 + 自动重启/重连（G1-07/08）。
@main
struct BranchConversationApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment?
    @State private var viewModel: MainChatViewModel?
    @State private var branchPanel: BranchPanelViewModel?
    @State private var conversationTree: ConversationTreeViewModel?
    @State private var threadList: ThreadListViewModel?
    @State private var startupIssue: StartupIssue?
    @State private var connectionIssue: ConnectionIssue?
    @State private var recoveryObserver: Task<Void, Never>?

    /// 运行期连接状态（子进程异常退出后的恢复路径，G1-07/08）。
    enum ConnectionIssue: Equatable {
        /// 自动重启/重连进行中。
        case recovering
        /// 自动恢复失败，需手动重连。
        case failed(String)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let startupIssue {
                    StartupIssueView(issue: startupIssue) {
                        self.startupIssue = nil
                        Task { await startUp() }
                    }
                } else if let viewModel {
                    VStack(spacing: 0) {
                        if let connectionIssue {
                            connectionBanner(connectionIssue)
                        }
                        HStack(spacing: 0) {
                            // 左栏（M4-002/007）：线程列表 + 对话树。
                            if let conversationTree, let threadList {
                                VStack(spacing: 0) {
                                    ThreadListView(viewModel: threadList)
                                    Divider()
                                    ConversationTreeView(viewModel: conversationTree)
                                }
                                .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
                                Divider()
                            }
                            MainChatView(viewModel: viewModel)
                            // 右侧支线标签栏（M3-007）：有支线或创建进行中才显示。
                            if let branchPanel, branchPanel.hasVisibleContent {
                                Divider()
                                BranchPanelView(viewModel: branchPanel)
                            }
                        }
                    }
                } else {
                    ProgressView("正在连接 Kimi Code CLI…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .task { await startUp() }
        }
        // 设置页（M2-006）：只读策略展示，无修改入口。
        Settings {
            SettingsView()
        }
    }

    // MARK: - 启动（环境检测三态 → 连接）

    private func startUp() async {
        guard viewModel == nil else { return }
        do {
            let env = try AppEnvironment.make()
            appDelegate.environment = env
            environment = env
            // 先显式环境检测：三类失败走各自引导页（G1-02/03/04），不崩不混。
            let probe = await env.supervisor.checkEnvironment()
            if let issue = StartupIssue(probeResult: probe) {
                Logger(label: "twig.app").info("环境检测未通过，进入引导页：\(String(describing: issue))")
                startupIssue = issue
                return
            }
            try await env.start()
            // B-M1 临时方案：project_root 取进程工作目录（M4-007 提供选择入口）。
            let cwd = FileManager.default.currentDirectoryPath
            let projectRoot = cwd == "/" ? NSHomeDirectory() : cwd
            let chat = MainChatViewModel(store: env.conversationStore, projectRoot: projectRoot)
            // 支线面板（M3-007）：追问请求出口 → 面板创建编排（M3-003）；
            // 主线锚点回跳出口 → 主对话滚动高亮（M3-010）。weak 避免两个 VM 循环持有。
            let panel = BranchPanelViewModel(
                branches: env.branches,
                threads: env.threads,
                messages: env.messages,
                conversation: env.conversationStore,
                coordinator: env.branchCoordinator,
                mergeService: env.branchMergeService
            )
            chat.onRequestBranchCreation = { [weak panel] request in
                panel?.startCreation(request)
            }
            panel.onJumpToMainline = { [weak chat] jump in
                chat?.handleAnchorJump(jump)
            }
            // 左侧对话树（M4-002/004/005）：点击节点 → 打开右侧标签 + 回跳锚点；
            // 面板支线集合/激活标签变化 → 树刷新与选中态同步。weak 防循环持有。
            let tree = ConversationTreeViewModel(
                branches: env.branches,
                threads: env.threads,
                messages: env.messages,
                conversation: env.conversationStore
            )
            tree.onSelectBranch = { [weak panel] branchID in
                panel?.openFromTree(branchID: branchID)
                panel?.jumpToAnchor(branchID: branchID)
            }
            panel.onBranchesChanged = { [weak tree] in
                tree?.refresh()
            }
            panel.onActiveBranchChanged = { [weak tree] branchID in
                tree?.selectedBranchID = branchID
            }
            viewModel = chat
            branchPanel = panel
            conversationTree = tree
            threadList = ThreadListViewModel(threads: env.threads, store: env.conversationStore)
            observeRecovery(env)
        } catch {
            // 登录失效（凭据文件在但已过期）以协议错误形态出现，保守识别后引导登录（G1-04）。
            startupIssue = StartupIssue.isAuthRelated(errorMessage: error.localizedDescription)
                ? .loginRequired
                : .connectFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - 运行期断连恢复（G1-07/08）

    private func observeRecovery(_ env: AppEnvironment) {
        recoveryObserver?.cancel()
        recoveryObserver = Task { @MainActor in
            for await state in await env.supervisor.states() {
                if Task.isCancelled { return }
                switch state {
                case .restarting:
                    // 子进程异常退出：流式消息标记中断（保留已收内容，G1-07）。
                    await env.sessionStore.markAllStale()
                    await env.conversationStore.interruptAllStreaming()
                    connectionIssue = .recovering
                case .failed(let reason):
                    await env.sessionStore.markAllStale()
                    await env.conversationStore.interruptAllStreaming()
                    connectionIssue = .failed(reason)
                case .starting:
                    // 自动重启拉起了新进程等待握手 → 自动重连（初次启动不经此路径）。
                    guard connectionIssue == .recovering else { continue }
                    do {
                        try await env.reconnect()
                        connectionIssue = nil
                    } catch {
                        connectionIssue = .failed(error.localizedDescription)
                    }
                case .ready:
                    if connectionIssue == .recovering { connectionIssue = nil }
                default:
                    break
                }
            }
        }
    }

    private func reconnect() {
        guard let environment else { return }
        connectionIssue = .recovering
        Task {
            do {
                try await environment.reconnect()
                connectionIssue = nil
            } catch {
                connectionIssue = .failed(error.localizedDescription)
            }
        }
    }

    private func connectionBanner(_ issue: ConnectionIssue) -> some View {
        HStack(spacing: 8) {
            switch issue {
            case .recovering:
                ProgressView()
                    .controlSize(.small)
                Text("连接中断：子进程意外退出，正在自动恢复…")
            case .failed(let reason):
                Image(systemName: "exclamationmark.triangle")
                Text("连接已断开：\(reason)")
                    .lineLimit(2)
                Spacer()
                Button("重新连接") { reconnect() }
            }
        }
        .padding(8)
        .background(.orange.opacity(0.15))
    }
}

/// 启动期三态引导页（M1-013，G1-02/03/04）：
/// 文案中的安装/升级/登录命令依据官方文档（kimi.com/code/docs，2026-08-01 核对）。
private struct StartupIssueView: View {

    let issue: StartupIssue
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.yellow)
            Text(title)
                .font(.headline)
            Text(guidance)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            if let command {
                Text(command)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            Button("重试", action: onRetry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var icon: String {
        switch issue {
        case .cliMissing: return "shippingbox"
        case .unsupportedVersion: return "arrow.triangle.2.circlepath"
        case .loginRequired: return "person.badge.key"
        case .connectFailed: return "exclamationmark.triangle"
        }
    }

    private var title: String {
        switch issue {
        case .cliMissing: return "未检测到 Kimi Code CLI"
        case .unsupportedVersion: return "CLI 版本不兼容"
        case .loginRequired: return "Kimi Code CLI 未登录"
        case .connectFailed: return "无法连接 Kimi Code CLI"
        }
    }

    private var guidance: String {
        switch issue {
        case .cliMissing:
            return "本应用依赖本机的 Kimi Code CLI。请在终端执行以下命令安装，完成后点击「重试」。"
        case .unsupportedVersion(let found):
            let foundText = found ?? "无法识别的版本"
            return "检测到版本 \(foundText)，本应用已验证的基线为 0.31.0 及以上。请在终端运行 kimi upgrade 升级后点击「重试」。"
        case .loginRequired:
            return "请在终端运行 kimi，在交互界面输入 /login 完成登录（OAuth 或 API Key），然后点击「重试」。"
        case .connectFailed(let reason):
            return reason
        }
    }

    private var command: String? {
        switch issue {
        case .cliMissing:
            return "curl -fsSL https://code.kimi.com/kimi-code/install.sh | bash"
        case .unsupportedVersion:
            return "kimi upgrade"
        case .loginRequired:
            return "kimi  # 然后输入 /login"
        case .connectFailed:
            return nil
        }
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
