import Foundation
import Testing
@testable import Core
import Shared

/// BranchContextAssembler 测试（任务 M3-004/005）：播种模板组装、祖先链、摘要路径。
/// 全部使用内存库 + FakeSummarizer，不触碰真实 ACP（额度零消耗）。
@Suite("BranchContextAssembler：支线上下文组装")
struct BranchContextAssemblerTests {

    /// 毫秒精度日期（GRDB 日期存储精度为毫秒）。
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    private func makeFixture() throws -> (
        MessageRepository, BranchRepository, BranchNoteRepository
    ) {
        let appDB = try AppDatabase.makeInMemory()
        try ThreadRepository(appDB).createThread(id: "t1", title: "主", projectRoot: "/a", at: t0)
        return (MessageRepository(appDB), BranchRepository(appDB), BranchNoteRepository(appDB))
    }

    private func makeMessage(
        _ id: String,
        branchID: String? = nil,
        role: MessageRole,
        kind: MessageKind = .text,
        content: String,
        sequence: Int,
        status: MessageStatus = .completed
    ) -> Message {
        Message(
            id: id, threadID: "t1", branchID: branchID,
            role: role, kind: kind, content: content,
            sequence: sequence, status: status,
            createdAt: t0, updatedAt: t0
        )
    }

    /// 标准主线：问答 ×2 + 工具卡片 + 锚点消息 + 锚点后消息 + notice。
    private func seedMainline(_ messages: MessageRepository) throws {
        try messages.insert(makeMessage("m1", role: .user, content: "第一个问题", sequence: 1))
        try messages.insert(makeMessage("m2", role: .assistant, content: "第一个回答", sequence: 2))
        try messages.insert(makeMessage("m3", role: .assistant, kind: .toolCall, content: "工具卡片内容", sequence: 3))
        try messages.insert(makeMessage("m4", role: .user, content: "第二个问题", sequence: 4))
        try messages.insert(makeMessage("m5", role: .assistant, content: "第二个回答（含选中段落）", sequence: 5))
        try messages.insert(makeMessage("m6", role: .user, content: "锚点之后的问题", sequence: 6))
        try messages.insert(makeMessage("m7", role: .assistant, kind: .notice, content: "通知内容", sequence: 7))
    }

    /// 断言多个标记在文本中按给定顺序出现。
    private func expectOrdered(_ text: String, _ markers: [String], _ comment: String) {
        var cursor = text.startIndex
        for marker in markers {
            guard let range = text.range(of: marker, range: cursor..<text.endIndex) else {
                Issue.record("\(comment)：缺少「\(marker)」")
                return
            }
            cursor = range.upperBound
        }
    }

    @Test("一级支线：模板段落齐全、顺序正确、锚点与问题原样、跳过工具/通知与锚点后消息")
    func firstLevelAssembly() async throws {
        let (messages, branches, notes) = try makeFixture()
        try seedMainline(messages)
        let assembler = BranchContextAssembler(messages: messages, branches: branches, notes: notes)

        let result = try await assembler.assemble(
            threadID: "t1", parentBranchID: nil,
            anchorMessageID: "m5", anchorQuote: "选中段落", userQuestion: "这段为什么？"
        )

        #expect(result.usedSummary == false)
        #expect(result.summaryNote == nil)
        #expect(result.originalBackgroundLength > 0)

        let seed = result.seedContext
        // 无嵌套 → 省略 [祖先支线] 段；其余四段齐全且顺序正确。
        #expect(!seed.contains("[祖先支线]"))
        expectOrdered(seed, ["[背景上下文]", "[当前选中段落]", "[用户追问]", "[来源说明]"], "模板四段顺序")

        // 背景含锚点之前的问答原文，不含工具卡片、通知与锚点之后的消息。
        #expect(seed.contains("第一个问题"))
        #expect(seed.contains("第一个回答"))
        #expect(seed.contains("第二个问题"))
        #expect(!seed.contains("工具卡片内容"), "toolCall 应跳过")
        #expect(!seed.contains("通知内容"), "notice 应跳过")
        #expect(!seed.contains("锚点之后的问题"), "锚点之后的消息不进背景")

        // 锚点引文与用户追问原样（BR-10）。
        #expect(seed.contains("[当前选中段落]\n选中段落"))
        #expect(seed.contains("[用户追问]\n这段为什么？"))
        #expect(seed.contains("这是从主线程或父支线派生的独立支线。请围绕当前选中段落回答。"))
    }

    @Test("三级嵌套：祖先链根→叶顺序，含各级引文、已回流笔记与关键问答")
    func nestedAncestorChain() async throws {
        let (messages, branches, notes) = try makeFixture()
        try seedMainline(messages)

        // 一级支线 b1（锚点在主线 m5），已回流。
        try branches.create(id: "b1", threadID: "t1", anchorMessageID: "m5", anchorQuote: "主线引文一", at: t0)
        try messages.insert(makeMessage("b1-u", branchID: "b1", role: .user, content: "支线一的问题", sequence: 1))
        try messages.insert(makeMessage("b1-a", branchID: "b1", role: .assistant, content: "支线一的最终回答", sequence: 2))
        try notes.create(note: BranchNote(id: "n1", branchID: "b1", threadID: "t1", summary: "支线一结论摘要", mergedAt: t0))

        // 二级支线 b2（锚点在 b1 的回答），未回流。
        try branches.create(id: "b2", threadID: "t1", parentBranchID: "b1", anchorMessageID: "b1-a", anchorQuote: "支线一引文二", at: t0)
        try messages.insert(makeMessage("b2-u", branchID: "b2", role: .user, content: "支线二的问题", sequence: 1))
        try messages.insert(makeMessage("b2-a", branchID: "b2", role: .assistant, content: "支线二的最终回答", sequence: 2))

        // 三级支线 b3（锚点在 b2 的回答）。
        try branches.create(id: "b3", threadID: "t1", parentBranchID: "b2", anchorMessageID: "b2-a", anchorQuote: "支线二引文三", at: t0)
        try messages.insert(makeMessage("b3-u", branchID: "b3", role: .user, content: "支线三的问题", sequence: 1))
        try messages.insert(makeMessage("b3-a", branchID: "b3", role: .assistant, content: "支线三的最终回答", sequence: 2))

        let assembler = BranchContextAssembler(messages: messages, branches: branches, notes: notes)
        let result = try await assembler.assemble(
            threadID: "t1", parentBranchID: "b3",
            anchorMessageID: "b3-a", anchorQuote: "新引文", userQuestion: "新追问"
        )

        #expect(result.usedSummary == false)
        let seed = result.seedContext
        expectOrdered(seed, ["[背景上下文]", "[祖先支线]", "[当前选中段落]", "[用户追问]", "[来源说明]"], "模板五段顺序")

        // 祖先链按根→叶（b1 → b2 → b3）。
        expectOrdered(seed, ["── 支线 1 ──", "── 支线 2 ──", "── 支线 3 ──"], "祖先链根→叶顺序")
        #expect(seed.contains("锚点引文：主线引文一"))
        #expect(seed.contains("锚点引文：支线一引文二"))
        #expect(seed.contains("锚点引文：支线二引文三"))
        // 已回流笔记摘要出现在 b1 块；关键问答 = 首条提问 + 最近完成回答。
        #expect(seed.contains("回流笔记：支线一结论摘要"))
        #expect(seed.contains("首条提问：支线二的问题"))
        #expect(seed.contains("最近回答：支线三的最终回答"))

        // 嵌套时主线截断点取根祖先锚点（m5，seq 5）：含此前问答、不含此后消息。
        #expect(seed.contains("第一个问题"))
        #expect(!seed.contains("锚点之后的问题"))
    }

    @Test("超阈值：走 FakeSummarizer 且只压背景，锚点与问题不进摘要输入（BR-10）")
    func overThresholdSummarizes() async throws {
        let (messages, branches, notes) = try makeFixture()
        try seedMainline(messages)
        let summarizer = FakeSummarizer()
        let assembler = BranchContextAssembler(
            messages: messages, branches: branches, notes: notes,
            summarizer: summarizer, compressionThreshold: 10
        )

        let result = try await assembler.assemble(
            threadID: "t1", parentBranchID: nil,
            anchorMessageID: "m5", anchorQuote: "选中段落", userQuestion: "这段为什么？"
        )

        #expect(result.usedSummary == true)
        #expect(result.summaryNote != nil)
        #expect(result.seedContext.contains("【假摘要】"))

        let received = try #require(summarizer.receivedBackgrounds.only)
        #expect(received.contains("第一个问题"), "摘要输入应含主线问答")
        #expect(!received.contains("选中段落"), "锚点引文永不进摘要输入")
        #expect(!received.contains("这段为什么？"), "用户追问永不进摘要输入")
        #expect(result.originalBackgroundLength == received.count, "originalBackgroundLength 即摘要前背景长度")

        // 摘要后锚点与问题仍原样出现在播种文本中。
        #expect(result.seedContext.contains("[当前选中段落]\n选中段落"))
        #expect(result.seedContext.contains("[用户追问]\n这段为什么？"))
    }

    @Test("摘要失败：抛 summarizationFailed 且不产出截断文本（BR-11）")
    func summarizationFailureThrows() async throws {
        let (messages, branches, notes) = try makeFixture()
        try seedMainline(messages)
        let summarizer = FakeSummarizer()
        summarizer.result = .failure(BranchSummarizeError.agentFailed(reason: "模拟失败"))
        let assembler = BranchContextAssembler(
            messages: messages, branches: branches, notes: notes,
            summarizer: summarizer, compressionThreshold: 10
        )

        await #expect {
            try await assembler.assemble(
                threadID: "t1", parentBranchID: nil,
                anchorMessageID: "m5", anchorQuote: "选中段落", userQuestion: "这段为什么？"
            )
        } throws: { error in
            guard let assemblyError = error as? BranchAssemblyError,
                  case .summarizationFailed(let reason) = assemblyError else { return false }
            return reason.contains("模拟失败")
        }
    }

    @Test("超阈值但未配置摘要器：按摘要失败处理，不静默截断")
    func overThresholdWithoutSummarizer() async throws {
        let (messages, branches, notes) = try makeFixture()
        try seedMainline(messages)
        let assembler = BranchContextAssembler(
            messages: messages, branches: branches, notes: notes,
            summarizer: nil, compressionThreshold: 10
        )

        await #expect {
            try await assembler.assemble(
                threadID: "t1", parentBranchID: nil,
                anchorMessageID: "m5", anchorQuote: "选中段落", userQuestion: "这段为什么？"
            )
        } throws: { error in
            guard let assemblyError = error as? BranchAssemblyError,
                  case .summarizationFailed = assemblyError else { return false }
            return true
        }
    }

    @Test("锚点消息不存在：保守报错（含嵌套时父支线消息流定位）")
    func missingAnchorMessage() async throws {
        let (messages, branches, notes) = try makeFixture()
        try seedMainline(messages)
        let assembler = BranchContextAssembler(messages: messages, branches: branches, notes: notes)

        await #expect {
            try await assembler.assemble(
                threadID: "t1", parentBranchID: nil,
                anchorMessageID: "不存在", anchorQuote: "引文", userQuestion: "问题"
            )
        } throws: { error in
            error as? BranchAssemblyError == .anchorMessageNotFound(messageID: "不存在")
        }

        // 嵌套：锚点 id 在主线存在、但不在父支线消息流中 → 同样报错。
        try branches.create(id: "b1", threadID: "t1", anchorMessageID: "m5", anchorQuote: "引文", at: t0)
        await #expect {
            try await assembler.assemble(
                threadID: "t1", parentBranchID: "b1",
                anchorMessageID: "m5", anchorQuote: "引文", userQuestion: "问题"
            )
        } throws: { error in
            error as? BranchAssemblyError == .anchorMessageNotFound(messageID: "m5")
        }
    }
}

/// 记录输入、可脚本化成功/失败的假摘要器。
private final class FakeSummarizer: BranchSummarizer, @unchecked Sendable {
    private(set) var receivedBackgrounds: [String] = []
    var result: Result<String, Error> = .success("【假摘要】")

    func summarize(background: String) async throws -> String {
        receivedBackgrounds.append(background)
        return try result.get()
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}

// MARK: - ACPSummarizer 协议级测试（fake agent，零额度）

/// ACPSummarizer 经 ACPClient + SessionStore + FakeACPAgent 的协议级主路径测试。
/// 真实 CLI 链路（额度、真实摘要质量）归 G3 真实验收，此处只验证：
/// 临时 session 生命周期、textDelta 聚合至 completed、失败/空结果显式抛出。
@Suite("ACPSummarizer（fake agent，协议级）", .serialized)
struct ACPSummarizerTests {

    private func makeStack(agentBehavior: String) async throws -> (ACPClient, SessionStore) {
        let home = try FakeCLI.makeHome(acpBehavior: agentBehavior)
        let supervisor = ACPProcessSupervisor(configuration: SupervisorConfiguration(
            homeDirectory: home,
            gracefulShutdownTimeout: .seconds(2)
        ))
        let client = ACPClient(supervisor: supervisor)
        let store = SessionStore()
        await store.attach(to: client)
        try await withTimeout(seconds: 10, operation: "connect") {
            try await client.connect()
        }
        return (client, store)
    }

    @Test("主路径：聚合 textDelta 至 completed 返回文本，临时映射事后摘除")
    func aggregatesUntilCompleted() async throws {
        let (client, store) = try await makeStack(agentBehavior: FakeACPAgent.chat)
        let summarizer = ACPSummarizer(client: client, sessionStore: store, cwd: "/tmp")

        let summary = try await summarizer.summarize(background: "一段超长背景")

        // FakeACPAgent.chat 回思考 chunk「思考中」+ 正文 chunk「你好」：
        // 只聚合 agent_message_chunk（thoughtDelta 不进摘要正文）。
        #expect(summary == "你好")
        // 临时 session 映射已摘除（session_fake 为 FakeACPAgent 固定 sessionId）。
        let registration = await store.registration(of: "session_fake")
        #expect(registration == nil)

        await client.disconnect()
    }

    @Test("prompt 期间 agent 进程死亡：显式抛出（短超时兜底）且不残留临时映射")
    func agentDeathDuringPromptThrows() async throws {
        let (client, store) = try await makeStack(agentBehavior: SummarizerFakeAgent.crashOnPrompt)
        // 短超时：进程死亡后挂起的 prompt 由超时兜底抛出，验证不静默挂死。
        let summarizer = ACPSummarizer(client: client, sessionStore: store, cwd: "/tmp", timeoutSeconds: 3)

        await #expect(throws: (any Error).self) {
            try await summarizer.summarize(background: "背景")
        }
        let registration = await store.registration(of: "session_fake")
        #expect(registration == nil)

        await client.disconnect()
    }

    @Test("completed 到达但无正文：抛 emptyResult（不返回空摘要）")
    func emptyResultThrows() async throws {
        let (client, store) = try await makeStack(agentBehavior: SummarizerFakeAgent.noChunks)
        let summarizer = ACPSummarizer(client: client, sessionStore: store, cwd: "/tmp")

        await #expect {
            try await summarizer.summarize(background: "背景")
        } throws: { error in
            error as? BranchSummarizeError == .emptyResult
        }
        let registration = await store.registration(of: "session_fake")
        #expect(registration == nil)

        await client.disconnect()
    }
}

/// ACPSummarizer 专用 fake agent 脚本（与 Shared/TestSupport/FakeACPAgent 同构的
/// bash NDJSON 应答；注意 SDK 会把 `/` 转义为 `\/`，method 匹配须容忍两种写法）。
private enum SummarizerFakeAgent {

    private static let replyFn = """
    reply() {
      local line="$1" result="$2"
      if [[ "$line" =~ \\"id\\":([0-9]+) ]]; then
        echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":${BASH_REMATCH[1]},\\"result\\":$result}"
      elif [[ "$line" =~ \\"id\\":\\"([^\\"]+)\\" ]]; then
        echo "{\\"jsonrpc\\":\\"2.0\\",\\"id\\":\\"${BASH_REMATCH[1]}\\",\\"result\\":$result}"
      fi
    }
    """

    private static let initializeResponse = """
    {"protocolVersion":1,"agentCapabilities":{"loadSession":true,"sessionCapabilities":{"list":{},"resume":{}}},"agentInfo":{"name":"fake-agent","version":"0.0.1"}}
    """

    /// prompt 到达即 exit 1（模拟摘要中途 agent 进程死亡；挂起的 prompt 由调用方超时兜底）。
    static let crashOnPrompt = """
    \(replyFn)
    while IFS= read -r line; do
      case "$line" in
        *notifications/initialized* | *notifications\\\\/initialized*) : ;;
        *\\"initialize\\"*)
          reply "$line" '\(initializeResponse)' ;;
        *\\"session/new\\"* | *\\"session\\\\/new\\"*)
          reply "$line" '{"sessionId":"session_fake"}' ;;
        *\\"session/prompt\\"* | *\\"session\\\\/prompt\\"*)
          exit 1 ;;
      esac
    done
    exit 0
    """

    /// prompt 直接 end_turn，不发任何 chunk（模拟空摘要）。
    static let noChunks = """
    \(replyFn)
    while IFS= read -r line; do
      case "$line" in
        *notifications/initialized* | *notifications\\\\/initialized*) : ;;
        *\\"initialize\\"*)
          reply "$line" '\(initializeResponse)' ;;
        *\\"session/new\\"* | *\\"session\\\\/new\\"*)
          reply "$line" '{"sessionId":"session_fake"}' ;;
        *\\"session/prompt\\"* | *\\"session\\\\/prompt\\"*)
          reply "$line" '{"stopReason":"end_turn"}' ;;
      esac
    done
    exit 0
    """
}
