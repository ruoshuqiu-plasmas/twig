import Foundation
import Testing
import ACP
@testable import Core

/// ACPEventAdapter 离线映射测试（M1-009）。
/// JSON 依据 G0 脱敏样本线格式构造，不驱动真实 CLI。
@Suite("ACPEventAdapter 领域事件映射")
struct ACPEventAdapterTests {

    private let adapter = ACPEventAdapter()

    private func params(_ json: String) throws -> SessionUpdateNotification.Parameters {
        try JSONDecoder().decode(
            SessionUpdateNotification.Parameters.self,
            from: Data(json.utf8)
        )
    }

    @Test("agent_message_chunk → textDelta")
    func textDelta() throws {
        let event = adapter.map(try params("""
        {"sessionId": "session_x", "update": {"sessionUpdate": "agent_message_chunk",
          "content": {"type": "text", "text": "你好"}}}
        """))
        #expect(event == .textDelta(sessionID: "session_x", text: "你好"))
    }

    @Test("agent_thought_chunk → thoughtDelta（G0 实测 kimi 上报思考流）")
    func thoughtDelta() throws {
        let event = adapter.map(try params("""
        {"sessionId": "session_x", "update": {"sessionUpdate": "agent_thought_chunk",
          "content": {"type": "text", "text": "Simple"}}}
        """))
        #expect(event == .thoughtDelta(sessionID: "session_x", text: "Simple"))
    }

    @Test("user_message_chunk → userTextDelta（session/load 重放场景）")
    func userTextDelta() throws {
        let event = adapter.map(try params("""
        {"sessionId": "session_x", "update": {"sessionUpdate": "user_message_chunk",
          "content": {"type": "text", "text": "历史问题"}}}
        """))
        #expect(event == .userTextDelta(sessionID: "session_x", text: "历史问题"))
    }

    @Test("tool_call → toolCallStarted，字段完整映射")
    func toolCallStarted() throws {
        let event = adapter.map(try params("""
        {"sessionId": "session_x", "update": {"sessionUpdate": "tool_call",
          "toolCallId": "0:tool_abc", "title": "Read", "kind": "read", "status": "pending",
          "locations": [{"path": "/tmp/a.txt"}]}}
        """))
        #expect(event == .toolCallStarted(sessionID: "session_x", call: ToolCallInfo(
            toolCallID: "0:tool_abc", title: "Read", kind: "read", status: "pending",
            paths: ["/tmp/a.txt"]
        )))
    }

    @Test("tool_call_update 稀疏字段 → toolCallUpdated，缺省容忍")
    func toolCallUpdateSparse() throws {
        let event = adapter.map(try params("""
        {"sessionId": "session_x", "update": {"sessionUpdate": "tool_call_update",
          "toolCallId": "0:tool_abc", "status": "completed"}}
        """))
        #expect(event == .toolCallUpdated(sessionID: "session_x", call: ToolCallInfo(
            toolCallID: "0:tool_abc", status: "completed"
        )))
    }

    @Test("tool_call_update 文本增量聚合；diff/terminal 以占位摘要表达")
    func toolCallUpdateContent() throws {
        let event = adapter.map(try params("""
        {"sessionId": "session_x", "update": {"sessionUpdate": "tool_call_update",
          "toolCallId": "0:tool_abc", "status": "in_progress",
          "content": [{"type": "content", "content": {"type": "text", "text": "abc"}},
                      {"type": "diff", "path": "/tmp/b.txt", "newText": "x"}]}}
        """))
        guard case .toolCallUpdated(_, let call) = event else {
            Issue.record("应为 toolCallUpdated，实际 \(event)")
            return
        }
        #expect(call.contentText == "abc[diff: /tmp/b.txt]")
    }

    @Test("plan/已知未建模事件 → notice，不崩溃")
    func planNotice() throws {
        let event = adapter.map(try params("""
        {"sessionId": "session_x", "update": {"sessionUpdate": "plan",
          "entries": [{"content": "步骤1"}]}}
        """))
        #expect(event == .notice("plan 更新（1 项）"))
    }

    @Test("未知事件类型 → unknown 且保守记录 hook 被调用（不崩溃）")
    func unknownUpdate() async throws {
        let recorder = UnknownRecorder()
        let adapter = ACPEventAdapter { type in Task { await recorder.add(type) } }
        let event = adapter.map(try params("""
        {"sessionId": "session_x", "update": {"sessionUpdate": "totally_new_thing", "foo": 1}}
        """))
        #expect(event == .unknown(updateType: "totally_new_thing", sessionID: "session_x"))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await recorder.types == ["totally_new_thing"])
    }

    // MARK: - session/request_permission 线格式（G0 perms 样本）

    @Test("RequestPermission 请求参数解码（perms 样本线格式）")
    func permissionRequestDecode() throws {
        let request = try JSONDecoder().decode(Request<RequestPermission>.self, from: Data("""
        {"jsonrpc": "2.0", "id": 0, "method": "session/request_permission",
         "params": {"sessionId": "session_x",
           "options": [{"optionId": "approve_once", "name": "Approve once", "kind": "allow_once"},
                       {"optionId": "reject", "name": "Reject", "kind": "reject_once"}],
           "toolCall": {"toolCallId": "1:tool_abc", "title": "Write",
             "content": [{"type": "content", "content": {"type": "text", "text": "..."}}]}}}
        """.utf8))
        #expect(request.params.sessionID == "session_x")
        #expect(request.params.options.count == 2)
        #expect(request.params.options[0].kind == "allow_once")
        #expect(request.params.toolCall?.toolCallID == "1:tool_abc")
    }

    @Test("permission 响应线格式：selected 与 cancelled 两种 outcome")
    func permissionResponseEncode() throws {
        let rejected = RequestPermission.response(
            id: .number(0),
            result: .init(outcome: .selected("reject"))
        )
        let rejectedJSON = String(decoding: try JSONEncoder().encode(rejected), as: UTF8.self)
        #expect(rejectedJSON.contains(#""outcome":"selected""#))
        #expect(rejectedJSON.contains(#""optionId":"reject""#))

        let cancelled = RequestPermission.response(
            id: .number(0),
            result: .init(outcome: .cancelled)
        )
        let cancelledJSON = String(decoding: try JSONEncoder().encode(cancelled), as: UTF8.self)
        #expect(cancelledJSON.contains(#""outcome":"cancelled""#))
        #expect(!cancelledJSON.contains("optionId"))
    }

    private actor UnknownRecorder {
        private(set) var types: [String] = []
        func add(_ type: String) { types.append(type) }
    }
}
