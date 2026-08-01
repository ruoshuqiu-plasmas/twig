import Foundation
import Logging
import Core

/// 应用级环境装配入口（任务 M1-012 起为真实 composition root）：
/// 数据库 → 子进程 Supervisor → ACP Client → SessionStore → ConversationStore。
///
/// 分层约束：本层只做装配与生命周期编排，不含业务逻辑。
/// class 而非 struct：重连（M1-013）需要替换 ``client``。
public final class AppEnvironment: @unchecked Sendable {

    public let database: AppDatabase
    public let supervisor: ACPProcessSupervisor
    /// 当前 ACP 客户端；重连后指向新实例（旧实例绑定的进程管道已死，随 deinit 释放）。
    public private(set) var client: ACPClient
    public let sessionStore: SessionStore
    public let conversationStore: ConversationStore

    private init(
        database: AppDatabase,
        supervisor: ACPProcessSupervisor,
        client: ACPClient,
        sessionStore: SessionStore,
        conversationStore: ConversationStore
    ) {
        self.database = database
        self.supervisor = supervisor
        self.client = client
        self.sessionStore = sessionStore
        self.conversationStore = conversationStore
    }

    /// 生产装配：文件库（Application Support）+ 真实 CLI。
    public static func make(logger: Logger = Logger(label: "twig.app")) throws -> AppEnvironment {
        // `TWIG_HOME`：验收/测试用 home 覆盖（G1-02/03/04 需要可重复构造缺失/旧版本/未登录环境；
        // macOS 的 homeDirectoryForCurrentUser 不吃 HOME 环境变量）。生产启动不要设置。
        let home = ProcessInfo.processInfo.environment["TWIG_HOME"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let database = try AppDatabase.makeDefault()
        let threads = ThreadRepository(database)
        let supervisor = ACPProcessSupervisor(
            configuration: SupervisorConfiguration(
                homeDirectory: home,
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
    /// 抛出时由入口层展示三态引导页（M1-013）。
    public func start() async throws {
        await sessionStore.attach(to: client)
        try await sessionStore.restoreFromStore()
        try await client.connect()
    }

    /// 重连（M1-013，G1-08）：子进程异常退出/自动重启后重建整条 ACP 链路——
    /// 新 ACPClient（旧实例的 SDK handler 绑定死管道，不复用）→ 重挂事件路由 →
    /// 握手 → 替换会话层驱动 → 为全部线程**新建** session（不做「已续接」假象，
    /// 旧 session 续接策略归 M4-010）。supervisor 侧进程恢复（自动重启/从 failed 启动）
    /// 由 ACPClient.connect 内的 supervisor.start() 触发。
    public func reconnect() async throws {
        let newClient = ACPClient(supervisor: supervisor)
        await sessionStore.attach(to: newClient)
        try await newClient.connect()
        client = newClient
        await conversationStore.updateDriver(
            LiveConversationDriver(client: newClient, sessionStore: sessionStore)
        )
        try await conversationStore.renewSessions()
    }

    /// 优雅停止：断协议层 + 关 stdin 停子进程（G0 实测语义）。
    public func shutdown() async {
        await client.disconnect()
    }
}
