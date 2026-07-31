import Foundation
import ACP

// 任务 M1-007 · acp-swift-sdk schema PoC（ADR-001 §依据的四个核对点）。
// fixtures 全部来自 spike/samples/sanitized/ 的 G0 脱敏样本（kimi 0.31.0 / ACP v1 真实线上数据），
// 离线解码，不驱动真实 CLI。
//
// 本机仅 Command Line Tools（无 Xcode），XCTest/swift-testing 不可用，
// 故 PoC 以可执行目标承载：任一检查失败即非零退出。

var failures = 0

@MainActor
func check(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        print("PASS  \(label)")
    } else {
        print("FAIL  \(label)\(detail.isEmpty ? "" : " — \(detail)")")
        failures += 1
    }
}

@MainActor
func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

let decoder = JSONDecoder()

do {
    // MARK: 核对点 3 · sessionCapabilities{list,resume}
    let result = try decoder.decode(Initialize.Result.self, from: fixture("initialize-result"))
    check(result.protocolVersion == 1, "initialize 响应 protocolVersion == 1")
    let capsObject = result.agentCapabilities.sessionCapabilities?.objectValue
    check(capsObject?["list"] != nil, "sessionCapabilities 含 list")
    check(capsObject?["resume"] != nil, "sessionCapabilities 含 resume")

    // MARK: 核对点 2 · configOptions[]
    let newResult = try decoder.decode(SessionNew.Result.self, from: fixture("session-new-result"))
    check(newResult.sessionID.hasPrefix("session_"), "session/new 响应 sessionId 可解码")
    struct WireProbe: Decodable { let configOptions: [Value]? }
    let probe = try decoder.decode(WireProbe.self, from: fixture("session-new-result"))
    let optionCount = probe.configOptions?.count ?? 0
    check(optionCount >= 2, "线上 session/new 响应含 configOptions[]（实测 \(optionCount) 项）")
    print("NOTE  已知缺口：SDK SessionNew.Result 未建模 configOptions[]，解码时静默丢弃；",
          "适配层若需要模型/思考档位选项须自行扩展。")

    // MARK: 核对点 1 · tool_call_update 稀疏字段容忍
    let sparse = try decoder.decode(SessionUpdateNotification.Parameters.self,
                                    from: fixture("tool-call-update-sparse"))
    guard case .toolCallUpdate(let sparseUpdate) = sparse.update else {
        fatalError("sparse fixture 应解码为 toolCallUpdate")
    }
    check(sparseUpdate.toolCallID.hasPrefix("0:tool_"), "tool_call_update：call id 稳定格式 0:tool_*")
    check(sparseUpdate.status != nil, "tool_call_update 稀疏条目 status 存在")
    check(sparseUpdate.title == nil && sparseUpdate.kind == nil
          && sparseUpdate.locations == nil && sparseUpdate.rawOutput == nil,
          "tool_call_update 稀疏字段容忍（title/kind/locations/rawOutput 缺省可解码）")

    let streaming = try decoder.decode(SessionUpdateNotification.Parameters.self,
                                       from: fixture("tool-call-update-streaming"))
    guard case .toolCallUpdate(let streamingUpdate) = streaming.update else {
        fatalError("streaming fixture 应解码为 toolCallUpdate")
    }
    check(streamingUpdate.status == "in_progress" && !(streamingUpdate.content?.isEmpty ?? true),
          "tool_call_update 流式中间态（in_progress + content 增量）可解码")

    let terminal = try decoder.decode(SessionUpdateNotification.Parameters.self,
                                      from: fixture("tool-call-update-terminal"))
    guard case .toolCallUpdate(let terminalUpdate) = terminal.update else {
        fatalError("terminal fixture 应解码为 toolCallUpdate")
    }
    check(["completed", "failed"].contains(terminalUpdate.status),
          "tool_call_update 终态（completed/failed）可解码")

    // MARK: 核对点 4 · agent_thought_chunk
    let thought = try decoder.decode(SessionUpdateNotification.Parameters.self,
                                     from: fixture("agent-thought-chunk"))
    guard case .agentThoughtChunk(let chunk) = thought.update else {
        fatalError("thought fixture 应解码为 agentThoughtChunk")
    }
    check(!chunk.content.text.isEmpty, "agent_thought_chunk 事件可解码且文本保留")
} catch {
    print("FAIL  解码抛出异常：\(error)")
    failures += 1
}

print(failures == 0 ? "\nPoC 通过：四个核对点全部满足。" : "\nPoC 失败：\(failures) 项未通过。")
exit(failures == 0 ? 0 : 1)
