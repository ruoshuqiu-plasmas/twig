import Foundation
import Testing
import ACP

/// 任务 M1-007 · acp-swift-sdk schema 核对（ADR-001 §依据的四个核对点）。
///
/// fixtures 全部来自 `spike/samples/sanitized/` 的 G0 脱敏样本
/// （kimi 0.31.0 / ACP v1 真实线上数据），离线解码，不驱动真实 CLI。
///
/// 核对点：
/// 1. `tool_call_update` 稀疏字段容忍（G0 实测字段可空）；
/// 2. `configOptions[]`（session/new 响应）解码；
/// 3. `sessionCapabilities{list,resume}`（initialize 响应）解码；
/// 4. `agent_thought_chunk` 事件解码。
@Suite("acp-swift-sdk schema 核对（kimi ACP v1 脱敏样本）")
struct ACPSchemaTests {

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "fixture 缺失：\(name).json"
        )
        return try Data(contentsOf: url)
    }

    // MARK: 核对点 3 · sessionCapabilities{list,resume}

    @Test("initialize 响应：sessionCapabilities{list,resume} 可解码")
    func initializeResultSessionCapabilities() throws {
        let result = try JSONDecoder().decode(
            Initialize.Result.self,
            from: fixture("initialize-result")
        )
        #expect(result.protocolVersion == 1)
        let caps = try #require(result.agentCapabilities.sessionCapabilities)
        let object = try #require(caps.objectValue, "sessionCapabilities 应为对象")
        // kimi 0.31.0 实测上报 {"list": {}, "resume": {}}（DEC-04：list/resume/load 全支持）
        #expect(object["list"] != nil)
        #expect(object["resume"] != nil)
    }

    // MARK: 核对点 2 · configOptions[]

    @Test("session/new 响应：sessionId 可解码（configOptions 为 SDK 已知缺口）")
    func sessionNewResult() throws {
        let result = try JSONDecoder().decode(
            SessionNew.Result.self,
            from: fixture("session-new-result")
        )
        #expect(result.sessionID.hasPrefix("session_"))
    }

    @Test("已知缺口：configOptions[] 在线上数据中存在，但 SDK SessionNew.Result 未建模（静默丢弃）")
    func sessionNewConfigOptionsGap() throws {
        // 用本地结构证明线上数据确实带 configOptions[]（kimi 扩展字段）；
        // SDK 解码不报错但会丢弃 → 适配层若需要模型/思考档位选项须自行扩展。
        struct WireProbe: Decodable {
            let configOptions: [Value]?
        }
        let probe = try JSONDecoder().decode(WireProbe.self, from: fixture("session-new-result"))
        let options = try #require(probe.configOptions, "线上 session/new 响应应含 configOptions[]")
        #expect(options.count >= 2) // 实测含 model、thinking 等 select 项
    }

    // MARK: 核对点 1 · tool_call_update 稀疏字段容忍

    @Test("tool_call_update 稀疏字段：缺 title/kind/locations/rawOutput 仍可解码")
    func toolCallUpdateSparse() throws {
        let params = try JSONDecoder().decode(
            SessionUpdateNotification.Parameters.self,
            from: fixture("tool-call-update-sparse")
        )
        guard case .toolCallUpdate(let update) = params.update else {
            Issue.record("应解码为 toolCallUpdate")
            return
        }
        #expect(update.toolCallID.hasPrefix("0:tool_")) // G0 实测 call id 稳定格式
        #expect(update.status != nil)
        #expect(update.title == nil)
        #expect(update.kind == nil)
        #expect(update.locations == nil)
        #expect(update.rawOutput == nil)
    }

    @Test("tool_call_update 流式中间态：content 增量可解码")
    func toolCallUpdateStreaming() throws {
        let params = try JSONDecoder().decode(
            SessionUpdateNotification.Parameters.self,
            from: fixture("tool-call-update-streaming")
        )
        guard case .toolCallUpdate(let update) = params.update else {
            Issue.record("应解码为 toolCallUpdate")
            return
        }
        #expect(update.status == "in_progress")
        let content = try #require(update.content)
        #expect(!content.isEmpty)
    }

    @Test("tool_call_update 终态：completed/failed 可解码")
    func toolCallUpdateTerminal() throws {
        let params = try JSONDecoder().decode(
            SessionUpdateNotification.Parameters.self,
            from: fixture("tool-call-update-terminal")
        )
        guard case .toolCallUpdate(let update) = params.update else {
            Issue.record("应解码为 toolCallUpdate")
            return
        }
        #expect(["completed", "failed"].contains(update.status))
    }

    // MARK: 核对点 4 · agent_thought_chunk

    @Test("agent_thought_chunk 事件可解码且文本保留")
    func agentThoughtChunk() throws {
        let params = try JSONDecoder().decode(
            SessionUpdateNotification.Parameters.self,
            from: fixture("agent-thought-chunk")
        )
        guard case .agentThoughtChunk(let chunk) = params.update else {
            Issue.record("应解码为 agentThoughtChunk")
            return
        }
        #expect(!chunk.content.text.isEmpty)
    }
}
