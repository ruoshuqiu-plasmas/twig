import Foundation
import ACP
import Logging

/// ACP 客户端封装（任务 M1-009）：对内持有 SDK `Client` 与 ``SupervisorTransport``，
/// 对上只暴露领域事件流与领域化请求接口——SDK 类型不扩散到 Feature 层（§5.4 核心约束）。
///
/// 职责：握手（含 supervisor 状态联动）、session 创建、prompt 发送、
/// session/update 通知 → ``AgentEvent`` 适配广播、permission 请求路由。
///
/// permission 路由（§5.6）：请求只进入策略链路——M2-005 起默认由
/// PermissionPolicyEngine 接管（第一阶段绝对只读，未知一律拒绝）；
/// ``permissionHandler`` 可替换（测试注入），替换后内置链路不再生效。
public actor ACPClient {

    /// permission 决策入口（可替换，测试注入）。为 nil 时走内置
    /// ToolOperationClassifier → PermissionPolicyEngine 默认链路（M2-005）。
    public var permissionHandler: (@Sendable (PermissionRequestData) async -> PermissionDecision)?

    private let supervisor: ACPProcessSupervisor
    private let client: Client
    private let adapter: ACPEventAdapter
    private let policyEngine = PermissionPolicyEngine()
    private let logger: Logger
    private var eventContinuations: [UUID: AsyncStream<AgentEvent>.Continuation] = [:]
    /// 每 session 的工具调用聚合（permission 请求自身不带 kind，须按 toolCallId
    /// 关联查 kind——G0 实测时序：tool_call 先、request_permission 后）。
    private var toolTrackers: [String: ToolCallTracker] = [:]
    /// agent 是否声明 `session/load` 能力（M4-010；G0 实测 CLI 0.31.0 为 true）。
    public private(set) var supportsLoadSession = false

    public init(
        supervisor: ACPProcessSupervisor,
        clientName: String = "twig",
        clientVersion: String = "0.1.0",
        logger: Logger = Logger(label: "twig.acp.client")
    ) {
        self.supervisor = supervisor
        self.logger = logger
        // 能力声明最小化（G0 探针同构：fs/terminal 全 false）——第一阶段不提供任何 fs/terminal 反向 RPC。
        self.client = Client(name: clientName, version: clientVersion, capabilities: .minimal, logger: logger)
        self.adapter = ACPEventAdapter { [logger] updateType in
            logger.warning("未知 session update（保守记录，仅类型）：\(updateType)")
        }
    }

    /// 拉起子进程并完成 ACP 握手；成功联动 supervisor `ready`，失败联动 `failed`。
    /// 若尚未做环境检测（notChecked）则先检测，检测不过直接抛错（对应 G1-02/03/04 引导页）。
    @discardableResult
    public func connect() async throws -> Initialize.Result {
        if await supervisor.state == .notChecked {
            let probeResult = await supervisor.checkEnvironment()
            guard case .ok = probeResult else {
                throw ACPError.internalError("CLI 环境检测未通过：\(probeResult)")
            }
        }
        await supervisor.start()
        let transport = SupervisorTransport(supervisor: supervisor, logger: logger)

        await client.onNotification(SessionUpdateNotification.self) { [adapter] message in
            let event = adapter.map(message.params)
            await self.recordToolEvent(event)
            await self.broadcast(event)
        }
        await client.onRequest(RequestPermission.self) { request in
            let data = PermissionRequestData(
                sessionID: request.params.sessionID,
                toolCallID: request.params.toolCall?.toolCallID,
                toolTitle: request.params.toolCall?.title,
                options: request.params.options.map {
                    .init(optionID: $0.optionID, name: $0.name, kind: $0.kind)
                }
            )
            await self.broadcast(.permissionRequested(data))
            let decision: PermissionDecision
            if let handler = await self.permissionHandler {
                decision = await handler(data)
            } else {
                decision = await self.defaultPermissionDecision(data)
            }
            let outcome: RequestPermission.Outcome = switch decision {
            case .selected(let optionID): .selected(optionID)
            case .cancelled: .cancelled
            }
            return RequestPermission.response(id: request.id, result: .init(outcome: outcome))
        }

        do {
            let result = try await client.connect(transport: transport)
            supportsLoadSession = result.agentCapabilities.loadSession ?? false
            await supervisor.markReady()
            return result
        } catch {
            await supervisor.markFailed(reason: "ACP 握手失败：\(error.localizedDescription)")
            throw error
        }
    }

    /// 创建 session，返回 sessionID（session ↔ 线程/支线映射归 M1-010）。
    @discardableResult
    public func newSession(cwd: String) async throws -> String {
        let result = try await client.send(
            SessionNew.request(SessionNew.Parameters(cwd: cwd, mcpServers: []))
        )
        return result.sessionID
    }

    /// 加载既有 session（M4-010，DEC-04 实测支持）。
    /// 历史重放为响应后异步到达的 session/update 通知（G0 §2），
    /// 重放窗口的处置归调用方（``LiveConversationDriver`` 的安静窗口）。
    @discardableResult
    public func loadSession(cwd: String, sessionID: String) async throws -> String {
        _ = try await client.send(
            TwigSessionLoad.request(
                TwigSessionLoad.Parameters(sessionID: sessionID, cwd: cwd, mcpServers: [])
            )
        )
        // kimi 0.31.1 实测：session/load 结果不含 sessionId（只回 configOptions），
        // 成功即沿用入参 id。
        return sessionID
    }

    /// 发送 prompt；完成广播 ``AgentEvent/completed(sessionID:stopReason:)``，
    /// 失败广播 ``AgentEvent/failed(sessionID:reason:)`` 并继续抛出。
    public func prompt(sessionID: String, text: String) async throws {
        do {
            let result = try await client.send(
                SessionPrompt.request(SessionPrompt.Parameters(sessionID: sessionID, prompt: [.text(text)]))
            )
            broadcast(.completed(sessionID: sessionID, stopReason: result.stopReason.rawValue))
        } catch {
            broadcast(.failed(sessionID: sessionID, reason: error.localizedDescription))
            throw error
        }
    }

    /// 取消进行中的 prompt（通知，无响应）。
    public func cancel(sessionID: String) async throws {
        try await client.send(
            SessionCancel.request(SessionCancel.Parameters(sessionID: sessionID))
        )
    }

    /// 优雅断开：先断协议层，再停子进程（关闭 stdin，G0 实测语义）。
    public func disconnect() async {
        await client.disconnect()
        await supervisor.stop()
    }

    /// 订阅领域事件流（先订阅后消费；支持多订阅者）。
    public func events() -> AsyncStream<AgentEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func broadcast(_ event: AgentEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    // MARK: - permission 策略链路（M2-005）

    /// 工具事件进内部聚合器（供 permission 回调按 toolCallId 查 kind；非工具事件忽略）。
    private func recordToolEvent(_ event: AgentEvent) {
        guard let sessionID = event.sessionID else { return }
        toolTrackers[sessionID, default: ToolCallTracker()].apply(event)
    }

    /// 内置默认链路：分类 → 策略器决策 → 脱敏日志 → 拒绝时对内部 tracker 标记 denied
    /// 并广播 ``AgentEvent/toolCallDenied``（M2-006：对话流 notice 与卡片收口的数据源）。
    private func defaultPermissionDecision(_ data: PermissionRequestData) -> PermissionDecision {
        let kind = data.toolCallID.flatMap { toolTrackers[data.sessionID]?.record(callID: $0)?.kind }
        let operation = ToolOperationClassifier.classify(kind: kind, title: data.toolTitle)
        let outcome = policyEngine.decide(operation: operation, options: data.options)
        logger.info("permission 决策：操作=\(operation.rawValue)，原因=\(outcome.reason)")
        if Self.isEffectiveDenial(outcome.decision, options: data.options) {
            if let callID = data.toolCallID {
                toolTrackers[data.sessionID, default: ToolCallTracker()].markDenied(callID: callID)
            }
            // 兜底 cancelled（含只读操作缺 allow_once 的边缘情况）同样视为实际未放行，
            // 一律发 notice——「没放行就一定有可见标注」。文案缺档时退到 unparseable 档。
            let noticeText = operation.denialNoticeText ?? ToolOperation.unparseable.denialNoticeText!
            broadcast(.toolCallDenied(
                sessionID: data.sessionID, callID: data.toolCallID,
                operation: operation, noticeText: noticeText
            ))
        }
        return outcome.decision
    }

    /// 决策是否实际未放行（规范拒绝选中 reject_once，或兜底 cancelled；optionId 不硬编码）。
    private static func isEffectiveDenial(_ decision: PermissionDecision, options: [PermissionRequestData.Option]) -> Bool {
        switch decision {
        case .cancelled:
            return true
        case .selected(let optionID):
            return options.first(where: { $0.optionID == optionID })?.kind == "reject_once"
        }
    }
}
