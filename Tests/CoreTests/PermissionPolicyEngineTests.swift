import Foundation
import Testing
@testable import Core
import Shared

/// 权限类型映射测试（M2-003）：映射依据 G0 脱敏样本，未知一律落 unknown/unparseable。
@Suite("ToolOperationClassifier：权限类型映射（M2-003）")
struct ToolOperationClassifierTests {

    @Test("kind 映射（样本实测值）：read→readFile、edit→writeFile、execute→executeCommand")
    func kindMapping() {
        #expect(ToolOperationClassifier.classify(kind: "read", title: nil) == .readFile)
        #expect(ToolOperationClassifier.classify(kind: "edit", title: nil) == .writeFile)
        #expect(ToolOperationClassifier.classify(kind: "execute", title: nil) == .executeCommand)
    }

    @Test("SEC-09/14：未知 kind（含 CLI 新增类型）→ unknown")
    func unknownKind() {
        #expect(ToolOperationClassifier.classify(kind: "delete", title: nil) == .unknown)
        #expect(ToolOperationClassifier.classify(kind: "future_new_kind", title: nil) == .unknown)
    }

    @Test("title 兜底映射（样本实测名字）：Write/Edit→writeFile、Bash/Terminal→executeCommand、Read→readFile")
    func titleFallback() {
        #expect(ToolOperationClassifier.classify(kind: nil, title: "Write") == .writeFile)
        #expect(ToolOperationClassifier.classify(kind: nil, title: "Edit") == .writeFile)
        #expect(ToolOperationClassifier.classify(kind: nil, title: "Bash") == .executeCommand)
        #expect(ToolOperationClassifier.classify(kind: nil, title: "Terminal") == .executeCommand)
        #expect(ToolOperationClassifier.classify(kind: nil, title: "Read") == .readFile)
        #expect(ToolOperationClassifier.classify(kind: nil, title: "SomeNewTool") == .unknown)
    }

    @Test("kind 优先于 title（G0 时序：tool_call 先、request_permission 后）")
    func kindTakesPrecedence() {
        #expect(ToolOperationClassifier.classify(kind: "read", title: "Write") == .readFile)
    }

    @Test("SEC-10：缺分类字段（kind/title 均缺）→ unparseable")
    func missingClassificationFields() {
        #expect(ToolOperationClassifier.classify(kind: nil, title: nil) == .unparseable)
    }
}

/// 权限策略引擎测试（M2-004）：SEC 矩阵中可单测覆盖的条目（SEC-04~11、14）逐条对应；
/// 需真实 CLI 的（SEC-01~03 端到端、12~13）留给任务 24 / Gate G2。
@Suite("PermissionPolicyEngine：只读 allowlist 与 default deny（SEC 矩阵）")
struct PermissionPolicyEngineTests {

    private let engine = PermissionPolicyEngine()

    /// options 三档（G0 样本形态：approve_once/approve_always/reject）。
    private func threeOptions() -> [PermissionRequestData.Option] {
        [
            .init(optionID: "approve_once", name: "Approve once", kind: "allow_once"),
            .init(optionID: "approve_always", name: "Approve for this session", kind: "allow_always"),
            .init(optionID: "reject", name: "Reject", kind: "reject_once"),
        ]
    }

    private func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures") else {
            Issue.record("fixture 缺失：\(name).json")
            return Data()
        }
        return try Data(contentsOf: url)
    }

    /// permission 请求线格式探针（只取 params，由 ``RequestPermission`` 建模核对）。
    private struct WireProbe: Codable {
        let params: RequestPermission.Parameters
    }

    @Test("SEC-01~03 分类面：读文件/列目录/搜索在 allowlist 内 → 批准（选 allow_once 选项）")
    func allowlistApproved() {
        for operation in [ToolOperation.readFile, .listDirectory, .search] {
            let outcome = engine.decide(operation: operation, options: threeOptions())
            #expect(outcome.decision == .selected(optionID: "approve_once"),
                    "\(operation) 应批准一次")
            #expect(outcome.operation == operation)
            #expect(!outcome.reason.isEmpty, "决策须带脱敏原因供日志")
        }
    }

    @Test("SEC-04~08：写文件/执行命令 → 规范拒绝（选 reject_once 选项）")
    func writeAndExecuteRejected() {
        for operation in [ToolOperation.writeFile, .executeCommand] {
            let outcome = engine.decide(operation: operation, options: threeOptions())
            #expect(outcome.decision == .selected(optionID: "reject"),
                    "\(operation) 应 default deny（规范拒绝）")
        }
    }

    @Test("SEC-09/14：未知操作类型 → 拒绝（CLI 新增类型不得默认批准）")
    func unknownRejected() {
        let outcome = engine.decide(operation: .unknown, options: threeOptions())
        #expect(outcome.decision == .selected(optionID: "reject"))
    }

    @Test("SEC-10：缺分类字段（unparseable）→ 拒绝")
    func unparseableRejected() {
        let outcome = engine.decide(operation: .unparseable, options: threeOptions())
        #expect(outcome.decision == .selected(optionID: "reject"))
    }

    @Test("optionId 不硬编码：自定义 optionId 也能按 kind 选中")
    func optionIDNotHardcoded() {
        let options = [
            PermissionRequestData.Option(optionID: "ok-1", name: "OK", kind: "allow_once"),
            PermissionRequestData.Option(optionID: "no-1", name: "No", kind: "reject_once"),
        ]
        #expect(engine.decide(operation: .readFile, options: options).decision == .selected(optionID: "ok-1"))
        #expect(engine.decide(operation: .writeFile, options: options).decision == .selected(optionID: "no-1"))
    }

    @Test("兜底 cancelled：只读操作缺 allow_once、非只读缺 reject_once、options 为空")
    func cancelledFallback() {
        let rejectOnly = [PermissionRequestData.Option(optionID: "reject", name: "Reject", kind: "reject_once")]
        let allowOnly = [PermissionRequestData.Option(optionID: "approve_once", name: "Approve", kind: "allow_once")]
        #expect(engine.decide(operation: .readFile, options: rejectOnly).decision == .cancelled)
        #expect(engine.decide(operation: .writeFile, options: allowOnly).decision == .cancelled)
        #expect(engine.decide(operation: .writeFile, options: []).decision == .cancelled)
        #expect(engine.decide(operation: .readFile, options: []).decision == .cancelled)
    }

    @Test("SEC-11：多请求各自独立（纯函数决策，无共享状态）")
    func concurrentRequestsIndependent() {
        let read = engine.decide(operation: .readFile, options: threeOptions())
        let write = engine.decide(operation: .writeFile, options: threeOptions())
        let unknown = engine.decide(operation: .unknown, options: threeOptions())
        #expect(read.decision == .selected(optionID: "approve_once"))
        #expect(write.decision == .selected(optionID: "reject"))
        #expect(unknown.decision == .selected(optionID: "reject"))
    }

    @Test("真实样本 fixtures：Write/Bash 权限请求 → 分类正确且选中样本中的 reject 选项")
    func realSampleFixtures() throws {
        for (fixtureName, expectedOperation) in [
            ("permission-request-write", ToolOperation.writeFile),
            ("permission-request-terminal", ToolOperation.executeCommand),
        ] {
            let probe = try JSONDecoder().decode(WireProbe.self, from: fixture(fixtureName))
            let params = probe.params
            // 样本中的 permission 请求自身不带 kind → 走 title 兜底映射。
            let operation = ToolOperationClassifier.classify(kind: nil, title: params.toolCall?.title)
            #expect(operation == expectedOperation, "\(fixtureName) 分类应为 \(expectedOperation)")
            let options = params.options.map {
                PermissionRequestData.Option(optionID: $0.optionID, name: $0.name, kind: $0.kind)
            }
            let outcome = engine.decide(operation: operation, options: options)
            let sampleReject = params.options.first { $0.kind == "reject_once" }
            #expect(sampleReject != nil, "样本 options 应含 reject_once 档")
            #expect(outcome.decision == .selected(optionID: sampleReject!.optionID),
                    "\(fixtureName) 应选中样本中的 reject 选项")
        }
    }
}
