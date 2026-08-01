import Foundation
import Logging
import Core

/// 应用级环境装配入口（任务 M1-012 起为真实 composition root）：
/// 数据库 → 子进程 Supervisor → ACP Client → SessionStore → ConversationStore。
///
/// 分层约束：本层只做装配与生命周期编排，不含业务逻辑。
public struct AppEnvironment: Sendable {

    public let database: AppDatabase
    public let supervisor: ACPProcessSupervisor
    public let client: ACPClient
    public let sessionStore: SessionStore
    public let conversationStore: ConversationStore

    /// 生产装配：文件库（Application Support）+ 真实 CLI。
    public static func make(logger: Logger = Logger(label: "twig.app")) throws -> AppEnvironment {
        let database = try AppDatabase.makeDefault()
        let threads = ThreadRepository(database)
        let supervisor = ACPProcessSupervisor(
            configuration: SupervisorConfiguration(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                onStderrLine: { line in
                    // CLI 日志走 stderr（G0 实测）；脱敏：按需再落，默认只记长度。
                    Logger(label: "twig.cli.stderr").debug("cli stderr 行（长度 \(line.count)）")
                }
            )
        )
        let client = ACPClient(supervisor: supervisor)
        let sessionStore = SessionStore(mappingStore: threads)
        let driver = LiveConversationDriver(client: client, sessionStore: sessionStore)
        let conversationStore = ConversationStore(
            threads: threads,
            messages: MessageRepository(database),
            driver: driver
        )
        return AppEnvironment(
            database: database,
            supervisor: supervisor,
            client: client,
            sessionStore: sessionStore,
            conversationStore: conversationStore
        )
    }

    /// 启动编排：事件路由挂载 → 重建 session 映射 → 环境检测 + 拉起子进程 + ACP 握手。
    /// 抛出时由入口层展示简版错误条（三态引导页归 M1-013）。
    public func start() async throws {
        await sessionStore.attach(to: client)
        try await sessionStore.restoreFromStore()
        try await client.connect()
    }

    /// 优雅停止：断协议层 + 关 stdin 停子进程（G0 实测语义）。
    public func shutdown() async {
        await client.disconnect()
    }
}
