import Foundation
import Testing
@testable import Core
import Shared

/// ACPClient + SupervisorTransport 端到端离线集成测试（M1-009）。
/// 全链路：supervisor 拉起 fake ACP agent（bash）→ SupervisorTransport NDJSON 行分帧
/// → SDK Client 握手/session/prompt → ACPEventAdapter → AgentEvent 领域事件流。
/// 不驱动真实 kimi CLI（零额度消耗）。
@Suite("ACPClient 端到端（fake agent）", .serialized)
struct ACPClientIntegrationTests {

    private actor EventCollector {
        private(set) var events: [AgentEvent] = []
        func add(_ event: AgentEvent) { events.append(event) }
    }

    private actor StderrCollector {
        private(set) var lines: [String] = []
        func add(_ line: String) { lines.append(line) }
    }

    private func makeClient(
        agentBehavior: String,
        stderr: StderrCollector? = nil
    ) async throws -> (ACPClient, ACPProcessSupervisor) {
        let home = try FakeCLI.makeHome(acpBehavior: agentBehavior)
        let supervisor = ACPProcessSupervisor(configuration: SupervisorConfiguration(
            homeDirectory: home,
            gracefulShutdownTimeout: .seconds(2),
            onStderrLine: { line in Task { await stderr?.add(line) } }
        ))
        return (ACPClient(supervisor: supervisor), supervisor)
    }

    private func collectEvents(of client: ACPClient, into collector: EventCollector) -> Task<Void, Never> {
        Task {
            let stream = await client.events()
            for await event in stream {
                await collector.add(event)
            }
        }
    }

    @Test("握手 → ready → newSession → prompt：思考/正文增量 + completed 全链路")
    func chatFlow() async throws {
        let (client, supervisor) = try await makeClient(agentBehavior: FakeACPAgent.chat)
        let collector = EventCollector()
        let collectTask = collectEvents(of: client, into: collector)

        let initResult = try await withTimeout(seconds: 10, operation: "connect") {
            try await client.connect()
        }
        #expect(initResult.protocolVersion == 1)
        #expect(initResult.agentInfo?.name == "fake-agent")
        let state = await supervisor.state
        #expect(state == .ready)

        let sessionID = try await withTimeout(seconds: 10, operation: "newSession") {
            try await client.newSession(cwd: "/tmp")
        }
        #expect(sessionID == "session_fake")

        try await withTimeout(seconds: 10, operation: "prompt") {
            try await client.prompt(sessionID: sessionID, text: "hi")
        }
        // 给事件广播一点收尾时间（通知先于 prompt 响应到达，但经消息循环异步分发）。
        try? await Task.sleep(for: .milliseconds(100))

        let events = await collector.events
        #expect(events.contains(.thoughtDelta(sessionID: "session_fake", text: "思考中")))
        #expect(events.contains(.textDelta(sessionID: "session_fake", text: "你好")))
        #expect(events.contains(.completed(sessionID: "session_fake", stopReason: "end_turn")))

        collectTask.cancel()
        await client.disconnect()
        let finalState = await supervisor.state
        #expect(finalState == .stopped)
    }

    @Test("permission 请求：事件透明展示 + 策略器规范拒绝（selected + reject optionId）")
    func permissionDefaultDeny() async throws {
        let stderr = StderrCollector()
        let (client, _) = try await makeClient(agentBehavior: FakeACPAgent.permission, stderr: stderr)
        let collector = EventCollector()
        let collectTask = collectEvents(of: client, into: collector)

        try await withTimeout(seconds: 10, operation: "connect") { try await client.connect() }
        let sessionID = try await withTimeout(seconds: 10, operation: "newSession") {
            try await client.newSession(cwd: "/tmp")
        }
        try await withTimeout(seconds: 10, operation: "prompt") {
            try await client.prompt(sessionID: sessionID, text: "写个文件")
        }
        try? await Task.sleep(for: .milliseconds(100))

        let events = await collector.events
        let permissionEvent = events.first {
            if case .permissionRequested = $0 { return true }
            return false
        }
        guard case .permissionRequested(let data) = permissionEvent else {
            Issue.record("应包含 permissionRequested 事件，实际 \(events)")
            collectTask.cancel()
            await client.disconnect()
            return
        }
        #expect(data.toolCallID == "0:tool_fake")
        #expect(data.options.count == 3, "options 三档与真实样本一致")

        // 策略链路：tool_call 的 kind=edit → writeFile → default deny（规范拒绝，
        // 从 options 按 kind=reject_once 选取，optionId 不硬编码）。
        let rejectOption = data.options.first { $0.kind == "reject_once" }
        #expect(rejectOption != nil)

        // fake agent 把收到的响应写进了 stderr。
        let stderrLines = await stderr.lines
        let permResp = stderrLines.first { $0.hasPrefix("PERMRESP:") }
        #expect(permResp?.contains(#""outcome":"selected""#) == true,
                "写操作应回规范拒绝（selected），实际 \(permResp ?? "无")")
        if let rejectOption {
            #expect(permResp?.contains(#""optionId":"\#(rejectOption.optionID)""#) == true,
                    "应选中 reject_once 选项，实际 \(permResp ?? "无")")
        }

        collectTask.cancel()
        await client.disconnect()
    }

    @Test("NDJSON 行分帧：响应分片到达也能完成握手（粘包/拆包容忍）")
    func fragmentedHandshake() async throws {
        let (client, _) = try await makeClient(agentBehavior: FakeACPAgent.fragmentedHandshake)
        let initResult = try await withTimeout(seconds: 10, operation: "connect") {
            try await client.connect()
        }
        #expect(initResult.agentInfo?.name == "fake-agent")
        await client.disconnect()
    }
}
