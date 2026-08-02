import Foundation
import Testing
@testable import Core
@testable import Features
import Shared

/// 追问入口（M3-003）与引文回跳（M3-010）的 MainChatViewModel 侧可测逻辑。
/// 浮动按钮位置/面板布局等 SwiftUI 细节归 G3 手工冒烟清单。
@Suite("MainChatViewModel：追问入口与回跳")
@MainActor
struct MainChatFollowUpTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    private func makeMessage(
        id: String, role: MessageRole, kind: MessageKind = .text, content: String
    ) -> Message {
        Message(
            id: id, threadID: "t1", role: role, kind: kind, content: content,
            sequence: 1, status: .completed, createdAt: t0, updatedAt: t0
        )
    }

    private func makeViewModel() throws -> MainChatViewModel {
        let appDB = try AppDatabase.makeInMemory()
        let store = ConversationStore(
            threads: ThreadRepository(appDB),
            messages: MessageRepository(appDB),
            driver: BranchSessionCoordinatorTests.FakeDriver(),
            flushInterval: 0
        )
        return MainChatViewModel(store: store, projectRoot: "/tmp")
    }

    // MARK: - 锚点纯文本助手

    @Test("anchorPlainText：assistant 正文取 Markdown 渲染产物纯文本；工具卡片等其他消息取 content 本身")
    func anchorPlainText() {
        let assistant = makeMessage(id: "m1", role: .assistant, content: "**粗体**和普通")
        let rendered = MainChatViewModel.anchorPlainText(for: assistant)
        #expect(rendered.contains("粗体"))
        #expect(!rendered.contains("**"), "应为渲染后纯文本，不含 markdown 记号")

        let toolCall = makeMessage(id: "m2", role: .assistant, kind: .toolCall, content: "文件结果原文")
        #expect(MainChatViewModel.anchorPlainText(for: toolCall) == "文件结果原文")
    }

    // MARK: - 追问冻结与请求组装

    @Test("BR-04：点击追问冻结快照后，用户改选区不影响本次追问；确认组装 BranchCreationRequest 交出口")
    func freezeAndConfirm() throws {
        let viewModel = try makeViewModel()
        viewModel.messages = [makeMessage(id: "m1", role: .assistant, content: "锚点原文")]
        viewModel.threadID = "t1"
        let snapshot = SelectionSnapshot(messageID: "m1", quote: "锚点", start: 0, length: 2)

        // 无选区时点击追问：保守忽略，不展开面板。
        viewModel.beginBranchComposition()
        #expect(!viewModel.isComposingBranchQuestion)

        viewModel.currentSelection = snapshot
        viewModel.beginBranchComposition()
        #expect(viewModel.isComposingBranchQuestion)
        #expect(viewModel.frozenSelection == snapshot)
        #expect(viewModel.frozenAnchorPlainText == "锚点原文")

        // 冻结后用户改选区/取消选区：冻结快照不受影响（BR-04）。
        viewModel.currentSelection = SelectionSnapshot(messageID: "m1", quote: "原文", start: 2, length: 2)
        viewModel.currentSelection = nil
        #expect(viewModel.frozenSelection == snapshot)

        var captured: BranchCreationRequest?
        viewModel.onRequestBranchCreation = { captured = $0 }

        // 空问题不组装请求。
        viewModel.branchQuestionInput = "   "
        viewModel.confirmBranchQuestion()
        #expect(captured == nil)

        viewModel.branchQuestionInput = "  这段什么意思？ "
        viewModel.confirmBranchQuestion()
        let request = try #require(captured)
        #expect(request.threadID == "t1")
        #expect(request.parentBranchID == nil)
        #expect(request.snapshot == snapshot)
        #expect(request.anchorPlainText == "锚点原文")
        #expect(request.userQuestion == "这段什么意思？")
        #expect(request.projectRoot == "/tmp")
        // 确认后面板收起、冻结清理。
        #expect(!viewModel.isComposingBranchQuestion)
        #expect(viewModel.frozenSelection == nil)
        #expect(viewModel.branchQuestionInput.isEmpty)
    }

    @Test("取消追问：丢弃冻结快照，不发出任何请求（composingQuestion 阶段零额度）")
    func cancelComposition() throws {
        let viewModel = try makeViewModel()
        viewModel.messages = [makeMessage(id: "m1", role: .assistant, content: "锚点原文")]
        viewModel.threadID = "t1"
        viewModel.currentSelection = SelectionSnapshot(messageID: "m1", quote: "锚点", start: 0, length: 2)
        viewModel.beginBranchComposition()

        var captured: BranchCreationRequest?
        viewModel.onRequestBranchCreation = { captured = $0 }
        viewModel.cancelBranchComposition()

        #expect(!viewModel.isComposingBranchQuestion)
        #expect(viewModel.frozenSelection == nil)
        #expect(viewModel.frozenAnchorPlainText == nil)
        #expect(captured == nil)
    }

    // MARK: - 引文回跳

    @Test("回跳：记录 jump 请求并短暂高亮锚点消息，高亮到时自动清除")
    func anchorJumpHighlight() async throws {
        let viewModel = try makeViewModel()
        let jump = AnchorJump(messageID: "m1", resolution: .degradedToMessage(messageID: "m1"))
        viewModel.handleAnchorJump(jump)

        #expect(viewModel.anchorJump == jump)
        #expect(viewModel.highlightedMessageID == "m1")

        // 高亮约 1.2s 后清除（等待留出调度余量）。
        try await Task.sleep(for: .milliseconds(1600))
        #expect(viewModel.highlightedMessageID == nil)
    }
}
