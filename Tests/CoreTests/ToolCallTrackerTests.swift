import Foundation
import Testing
@testable import Core

/// 工具事件领域模型测试（M2-001）：生命周期映射、稀疏合并、累积快照、denied 派生。
/// 形态依据 G0 脱敏样本（`spike/samples/sanitized/perms-*.jsonl`）。
@Suite("ToolCallTracker：工具生命周期聚合")
struct ToolCallTrackerTests {

    private let sid = "sess-1"
    private let callID = "0:tool_abc"

    private func started(status: String = "pending", kind: String? = "read", title: String? = "Read") -> AgentEvent {
        .toolCallStarted(sessionID: sid, call: ToolCallInfo(toolCallID: callID, title: title, kind: kind, status: status))
    }

    private func update(status: String? = nil, content: String? = nil, kind: String? = nil, title: String? = nil) -> AgentEvent {
        .toolCallUpdated(sessionID: sid, call: ToolCallInfo(toolCallID: callID, title: title, kind: kind, status: status, contentText: content))
    }

    @Test("协议状态映射：pending/in_progress/completed/failed 四态，未知字符串不映射")
    func statusMapping() {
        #expect(ToolCallStatus(protocolStatus: "pending") == .requested)
        #expect(ToolCallStatus(protocolStatus: "in_progress") == .running)
        #expect(ToolCallStatus(protocolStatus: "completed") == .succeeded)
        #expect(ToolCallStatus(protocolStatus: "failed") == .failed)
        #expect(ToolCallStatus(protocolStatus: "cancelled") == nil)
    }

    @Test("完整生命周期：requested → running → succeeded，中途到达的 kind/title 被合并")
    func fullLifecycle() {
        var tracker = ToolCallTracker()
        tracker.apply(started())
        #expect(tracker.record(callID: callID)?.status == .requested)

        tracker.apply(update(status: "in_progress", content: "{"))
        // G0 实测：kind/title 可能中途才随 update 出现。
        tracker.apply(update(status: "in_progress", kind: "read", title: "Reading /x.txt"))
        tracker.apply(update(status: "completed", content: "文件内容"))
        let record = tracker.record(callID: callID)
        #expect(record?.status == .succeeded)
        #expect(record?.kind == "read")
        #expect(record?.title == "Reading /x.txt")
        #expect(record?.contentText == "文件内容")
    }

    @Test("稀疏 update：只带 status 时不丢已有字段")
    func sparseUpdateKeepsFields() {
        var tracker = ToolCallTracker()
        tracker.apply(started(kind: "edit", title: "Write"))
        tracker.apply(update(status: "in_progress"))
        let record = tracker.record(callID: callID)
        #expect(record?.kind == "edit" && record?.title == "Write")
        #expect(record?.status == .running)
    }

    @Test("累积快照：contentText 按最新替换，不追加（G0 实测形态）")
    func cumulativeContentReplaces() {
        var tracker = ToolCallTracker()
        tracker.apply(started())
        tracker.apply(update(status: "in_progress", content: "{"))
        tracker.apply(update(status: "in_progress", content: "{\"path\": \"/x"))
        tracker.apply(update(status: "completed", content: "{\"path\": \"/x\"}"))
        #expect(tracker.record(callID: callID)?.contentText == "{\"path\": \"/x\"}",
                "应为最新快照而非拼接")
    }

    @Test("denied 派生：failed 文本含 rejected → denied；普通 failed 保持 failed")
    func deniedDerivation() {
        var tracker = ToolCallTracker()
        tracker.apply(started(kind: "edit", title: "Write"))
        tracker.apply(update(status: "failed", content: "...why it was rejected, then adjust..."))
        #expect(tracker.record(callID: callID)?.status == .denied)

        var tracker2 = ToolCallTracker()
        tracker2.apply(started())
        tracker2.apply(update(status: "failed", content: "file not found"))
        #expect(tracker2.record(callID: callID)?.status == .failed)
    }

    @Test("markDenied：权限策略器显式拒绝；后续协议 update 不回退终态")
    func explicitDeny() {
        var tracker = ToolCallTracker()
        tracker.apply(started(kind: "execute", title: "Bash"))
        tracker.apply(update(status: "in_progress"))
        tracker.markDenied(callID: callID)
        #expect(tracker.record(callID: callID)?.status == .denied)
        // 协议随后到达的 failed（含 rejected 文本）不回退、不重复改写。
        tracker.apply(update(status: "failed", content: "rejected"))
        #expect(tracker.record(callID: callID)?.status == .denied)
    }

    @Test("乱序容忍：update 先于 started 到达仍建档；终态不被回退")
    func outOfOrderTolerated() {
        var tracker = ToolCallTracker()
        tracker.apply(update(status: "in_progress", content: "{"))
        #expect(tracker.record(callID: callID)?.status == .running)
        tracker.apply(started())  // 迟到的 started 不应把 running 回退为 requested
        #expect(tracker.record(callID: callID)?.status == .running)

        tracker.apply(update(status: "completed", content: "done"))
        tracker.apply(update(status: "in_progress"))  // 迟到的稀疏 update 不回退终态
        #expect(tracker.record(callID: callID)?.status == .succeeded)
    }

    @Test("未知状态字符串：保守保留原状态")
    func unknownStatusKept() {
        var tracker = ToolCallTracker()
        tracker.apply(started())
        tracker.apply(update(status: "weird_future_status"))
        #expect(tracker.record(callID: callID)?.status == .requested)
    }

    @Test("多调用并存：按稳定 call id 各自独立聚合")
    func multipleCalls() {
        var tracker = ToolCallTracker()
        tracker.apply(.toolCallStarted(sessionID: sid, call: ToolCallInfo(toolCallID: "0:a", status: "pending")))
        tracker.apply(.toolCallStarted(sessionID: sid, call: ToolCallInfo(toolCallID: "1:b", status: "pending")))
        tracker.apply(.toolCallUpdated(sessionID: sid, call: ToolCallInfo(toolCallID: "0:a", status: "completed")))
        #expect(tracker.record(callID: "0:a")?.status == .succeeded)
        #expect(tracker.record(callID: "1:b")?.status == .requested)
        #expect(tracker.records.count == 2)
    }
}
