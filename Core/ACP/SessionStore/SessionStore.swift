import Foundation
import Logging

/// session 映射的持久化缝（M1-011 起由 ThreadRepository 等实现）。
/// 核心约束：复合写入同事务由实现方保证；本协议不感知数据库细节。
public protocol SessionMappingStore: Sendable {
    /// 保存/更新一条 session ↔ 本地归属映射。
    func saveMapping(sessionID: String, owner: SessionStore.Owner) async throws
    /// 删除映射（本地线程/支线删除时调用）。
    func removeMapping(sessionID: String) async throws
    /// 读取全部映射（应用启动时重建内存表）。
    func loadMappings() async throws -> [SessionStore.Registration]
}

/// ACP session 与本地线程/支线的映射及按 session 的事件路由（任务 M1-010）。
///
/// 职责：
/// - 维护 `acpSessionID → Owner`（thread/branch）映射，可选经 ``SessionMappingStore`` 持久化；
/// - 单一订阅 ``ACPClient`` 全局事件流，按 sessionID fan-out 为每 session 独立事件流
///   （G1-06 切线程不串线、B-M3 多支线并发的路由基础）；
/// - 子进程重启后整表标记失效：session 活在 agent 进程内，进程死亡后旧 sessionID
///   不再可用（恢复策略 list/resume/load 归 M4-010，本层只保证不制造「已续接」假象）。
///
/// 无主 sessionID 的事件保守记录（脱敏，仅前缀），不崩溃。
public actor SessionStore {

    /// session 的本地归属。
    public enum Owner: Sendable, Equatable, Hashable {
        /// 主线程（B-M1 唯一实际使用）。
        case thread(String)
        /// 支线（B-M3 起用，先建模）。
        case branch(String)
    }

    /// 单条映射记录。
    public struct Registration: Sendable, Equatable {
        public var sessionID: String
        public var owner: Owner
        /// 是否对当前 agent 进程有效；子进程重启/应用重启恢复后为 false。
        public var isLive: Bool

        public init(sessionID: String, owner: Owner, isLive: Bool = true) {
            self.sessionID = sessionID
            self.owner = owner
            self.isLive = isLive
        }
    }

    private let mappingStore: (any SessionMappingStore)?
    private let logger: Logger

    private var registrations: [String: Registration] = [:]

    private var routingTask: Task<Void, Never>?
    private var sessionContinuations: [String: [UUID: AsyncStream<AgentEvent>.Continuation]] = [:]
    private var globalContinuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]

    public init(
        mappingStore: (any SessionMappingStore)? = nil,
        logger: Logger = Logger(label: "twig.acp.sessionstore")
    ) {
        self.mappingStore = mappingStore
        self.logger = logger
    }

    deinit {
        routingTask?.cancel()
    }

    // MARK: - 映射管理

    /// 注册映射（newSession 成功后调用）；配置持久化缝时同步落库。
    @discardableResult
    public func register(sessionID: String, owner: Owner) async throws -> Registration {
        let registration = Registration(sessionID: sessionID, owner: owner)
        registrations[sessionID] = registration
        try await mappingStore?.saveMapping(sessionID: sessionID, owner: owner)
        return registration
    }

    /// 摘除映射（本地线程/支线删除时调用）。
    public func remove(sessionID: String) async throws {
        registrations.removeValue(forKey: sessionID)
        sessionContinuations.removeValue(forKey: sessionID)
        try await mappingStore?.removeMapping(sessionID: sessionID)
    }

    public func registration(of sessionID: String) -> Registration? {
        registrations[sessionID]
    }

    public func allRegistrations() -> [Registration] {
        Array(registrations.values)
    }

    /// 子进程重启/崩溃后调用：所有映射标记失效（不删除，留待 M4-010 恢复策略判定）。
    public func markAllStale() {
        for key in registrations.keys {
            registrations[key]?.isLive = false
        }
        logger.info("agent 进程重启，全部 session 映射已标记失效（共 \(registrations.count) 条）")
    }

    /// 应用启动时从持久化缝重建映射；恢复出的映射一律 isLive=false
    /// （session 不跨进程存活，续接与否由 M4-010 按实测能力处理）。
    public func restoreFromStore() async throws {
        guard let mappingStore else { return }
        let stored = try await mappingStore.loadMappings()
        for var registration in stored {
            registration.isLive = false
            registrations[registration.sessionID] = registration
        }
    }

    // MARK: - 事件路由

    /// 接入事件源（``ACPClient``）。重复调用会先取消旧订阅再重挂（如重连后）。
    /// 调用方须保证在 newSession/prompt 之前完成 attach 与 ``events(for:)`` 订阅，
    /// 本层不做事件缓冲。
    public func attach(to client: ACPClient) {
        routingTask?.cancel()
        routingTask = Task { [weak self] in
            let stream = await client.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.route(event)
            }
        }
    }

    /// 订阅指定 session 的事件流（仅含该 sessionID 的事件；支持多订阅者）。
    public func events(for sessionID: String) -> AsyncStream<AgentEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            sessionContinuations[sessionID, default: [:]][id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSessionContinuation(sessionID: sessionID, id: id) }
            }
        }
    }

    /// 全局事件流（无 session 归属的事件，如 ``AgentEvent/notice(_:)``）。
    public func globalEvents() -> AsyncStream<AgentEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            globalContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeGlobalContinuation(id) }
            }
        }
    }

    private func removeSessionContinuation(sessionID: String, id: UUID) {
        sessionContinuations[sessionID]?.removeValue(forKey: id)
        if sessionContinuations[sessionID]?.isEmpty == true {
            sessionContinuations.removeValue(forKey: sessionID)
        }
    }

    private func removeGlobalContinuation(_ id: UUID) {
        globalContinuations.removeValue(forKey: id)
    }

    private func route(_ event: AgentEvent) {
        guard let sessionID = event.sessionID else {
            for continuation in globalContinuations.values {
                continuation.yield(event)
            }
            return
        }
        guard let subscribers = sessionContinuations[sessionID], !subscribers.isEmpty else {
            // 无主事件保守记录（脱敏：仅 session id 前缀与事件类型），不崩溃。
            logger.debug("收到无订阅者的 session 事件（保守记录）：session=\(sessionID.prefix(8))…")
            return
        }
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }
}
