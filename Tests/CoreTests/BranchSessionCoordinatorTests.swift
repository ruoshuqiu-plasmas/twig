import Foundation
import GRDB
import Testing
@testable import Core
import Shared

/// BranchSessionCoordinator 测试（任务 M3-006，流程文档 §7.3；BR-06/BR-07）。
/// 全部使用内存库 + FakeDriver + FakeSummarizer/门闩组装器，不派生真实子进程（额度零消耗）。
@Suite("BranchSessionCoordinator：支线创建状态机")
struct BranchSessionCoordinatorTests {

    // MARK: - 测试替身

    /// 假驱动（actor 保证并发安全；模式照 BranchConversationTests，事件由测试手动注入）。
    actor FakeDriver: ConversationDriver {
        private var sessions: [(cwd: String, owner: SessionStore.Owner, sessionID: String)] = []
        private var sentPrompts: [(sessionID: String, text: String)] = []
        private var continuations: [String: AsyncStream<AgentEvent>.Continuation] = [:]
        private var sessionCounter = 0
        /// 设置后下一次 makeSession 抛出（消费一次）。
        private var sessionError: (any Error)?

        var sessionCount: Int { sessions.count }
        var sentPromptCount: Int { sentPrompts.count }
        func sessionID(at index: Int) -> String { sessions[index].sessionID }
        func sessionOwner(at index: Int) -> SessionStore.Owner { sessions[index].owner }
        func failNextSession(_ error: any Error) { sessionError = error }

        func makeSession(cwd: String, owner: SessionStore.Owner) async throws -> String {
            if let sessionError {
                self.sessionError = nil
                throw sessionError
            }
            sessionCounter += 1
            let sessionID = "sess-\(sessionCounter)"
            sessions.append((cwd, owner, sessionID))
            return sessionID
        }

        func sendPrompt(sessionID: String, text: String) async throws {
            sentPrompts.append((sessionID, text))
        }

        func events(for sessionID: String) async -> AsyncStream<AgentEvent> {
            AsyncStream { continuation in continuations[sessionID] = continuation }
        }

        func emit(sessionID: String, _ event: AgentEvent) {
            continuations[sessionID]?.yield(event)
        }
    }

    /// 假摘要器：直接把背景折叠成固定摘要。
    struct FakeSummarizer: BranchSummarizer {
        func summarize(background: String) async throws -> String { "压缩摘要" }
    }

    /// 门闩组装器：open() 前 assemble 一直挂起（响应任务取消），用于取消与并发防重复测试。
    final class GatedAssembler: BranchContextAssembling, @unchecked Sendable {
        private let lock = NSLock()
        private var gateOpen = false
        private(set) var assembleCalls = 0

        func open() {
            lock.lock()
            gateOpen = true
            lock.unlock()
        }

        private var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return gateOpen
        }

        func assemble(
            threadID: String,
            parentBranchID: String?,
            anchorMessageID: String,
            anchorQuote: String,
            userQuestion: String
        ) async throws -> AssembledBranchContext {
            recordCall()
            while !isOpen {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
            return AssembledBranchContext(
                seedContext: "门闩种子", usedSummary: false,
                originalBackgroundLength: 1, summaryNote: nil
            )
        }

        private func recordCall() {
            lock.lock()
            assembleCalls += 1
            lock.unlock()
        }
    }

    /// 状态流收集器（后台任务逐态追加，测试轮询读取）。
    actor StateCollector {
        private var collected: [BranchCreationState] = []

        var states: [BranchCreationState] { collected }

        var last: BranchCreationState? { collected.last }

        @discardableResult
        func collect(_ stream: AsyncStream<BranchCreationState>) -> Task<Void, Never> {
            Task {
                for await state in stream {
                    collected.append(state)
                }
            }
        }
    }

    struct FakeSessionError: Error {}

    // MARK: - 环境搭建

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    private func makeWorld(
        summarizer: (any BranchSummarizer)? = nil,
        compressionThreshold: Int = BranchContextAssembler.defaultCompressionThreshold
    ) throws -> (
        coordinator: BranchSessionCoordinator, driver: FakeDriver,
        branches: BranchRepository, messages: MessageRepository
    ) {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let branches = BranchRepository(appDB)
        let notes = BranchNoteRepository(appDB)
        try threads.createThread(id: "t1", title: "主", projectRoot: "/tmp", at: t0)

        let driver = FakeDriver()
        let store = ConversationStore(
            threads: threads, messages: messages, driver: driver, flushInterval: 0
        )
        let assembler = BranchContextAssembler(
            messages: messages, branches: branches, notes: notes,
            summarizer: summarizer, compressionThreshold: compressionThreshold
        )
        let coordinator = BranchSessionCoordinator(
            assembler: assembler, branches: branches, conversation: store, now: { self.t0 }
        )
        return (coordinator, driver, branches, messages)
    }

    private func makeCoordinatorWorld(
        assembler: any BranchContextAssembling
    ) throws -> (coordinator: BranchSessionCoordinator, driver: FakeDriver, branches: BranchRepository) {
        let appDB = try AppDatabase.makeInMemory()
        let threads = ThreadRepository(appDB)
        let messages = MessageRepository(appDB)
        let branches = BranchRepository(appDB)
        try threads.createThread(id: "t1", title: "主", projectRoot: "/tmp", at: t0)
        let driver = FakeDriver()
        let store = ConversationStore(
            threads: threads, messages: messages, driver: driver, flushInterval: 0
        )
        let coordinator = BranchSessionCoordinator(
            assembler: assembler, branches: branches, conversation: store, now: { self.t0 }
        )
        return (coordinator, driver, branches)
    }

    /// 播种主线问答（锚点消息 m2 为 assistant 回答）。
    private func seedMainline(_ messages: MessageRepository, anchorContent: String) throws {
        let base = Message(
            id: "m1", threadID: "t1", role: .user, content: "主线问题",
            sequence: 1, status: .completed, createdAt: t0, updatedAt: t0
        )
        let anchor = Message(
            id: "m2", threadID: "t1", role: .assistant, content: anchorContent,
            sequence: 2, status: .completed, createdAt: t0, updatedAt: t0
        )
        try messages.insert(base)
        try messages.insert(anchor)
    }

    private func waitFor(
        _ description: String,
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        _ = try await withTimeout(seconds: 5, operation: description) {
            while await !condition() {
                try await Task.sleep(for: .milliseconds(10))
            }
            return true
        }
    }

    /// 等播种发出后注入一条 delta + completed，驱动状态机到 ready。
    private func driveSeedToCompletion(driver: FakeDriver) async throws {
        try await waitFor("播种发出") { await driver.sentPromptCount == 1 }
        let sessionID = await driver.sessionID(at: 0)
        await driver.emit(sessionID: sessionID, .textDelta(sessionID: sessionID, text: "播种回答"))
        await driver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
    }

    // MARK: - 正常路径

    @Test("正常路径：状态链依次推进到 ready；锚点字段 Character 偏移（含 emoji）；播种消息带 seedContext metadata")
    func happyPath() async throws {
        // 渲染纯文本含 emoji（代理对 2 个 UTF-16 单元、1 个 Character）。
        let plainText = "前文😀中段后文"
        // 选中「中段」：UTF-16 偏移 start=4（前文2+😀2）、length=2；
        // Character 偏移应为 start=3（前文2+😀1）、length=2。
        let (coordinator, driver, branches, messages) = try makeWorld()
        try seedMainline(messages, anchorContent: plainText)

        let request = BranchCreationRequest(
            requestID: "req-1", threadID: "t1",
            snapshot: SelectionSnapshot(messageID: "m2", quote: "中段", start: 4, length: 2),
            anchorPlainText: plainText, userQuestion: "这段什么意思？", projectRoot: "/tmp"
        )
        let collector = StateCollector()
        await collector.collect(await coordinator.startCreation(request))

        try await driveSeedToCompletion(driver: driver)
        try await waitFor("状态机到 ready") { await collector.last == .ready }

        // §7.3 状态链（无摘要 → 不经过 compressingContext）。
        #expect(
            await collector.states == [
                .idle, .composingQuestion, .preparingContext,
                .creatingSession, .sendingSeed, .streaming, .ready,
            ]
        )

        // branches 行：组装成功后才建行，锚点坐标为 Character 偏移（ADR-003）。
        let rows = try branches.listBranches(threadID: "t1")
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.anchorMessageID == "m2")
        #expect(row.anchorQuote == "中段")
        #expect(row.anchorStart == 3, "UTF-16(4) 应换算为 Character(3)：😀 占 2 UTF-16 单元、1 Character")
        #expect(row.anchorLength == 2)
        #expect(row.anchorContextHash == AnchorResolver.contextHash(of: plainText))
        #expect(row.seedContext != nil)
        #expect(row.status == .open)
        #expect(row.acpSessionID == nil, "session 映射在 ConversationStore，不写 branches 行")

        // 坐标切片应精确命中引文（换算正确性的端到端验证）。
        let start = plainText.index(plainText.startIndex, offsetBy: row.anchorStart!)
        let end = plainText.index(start, offsetBy: row.anchorLength!)
        #expect(String(plainText[start..<end]) == "中段")

        // 播种消息落库：支线维度首条 user 消息，metadata 带 seedContext 标记。
        let branchMessages = try messages.messages(threadID: "t1", branchID: row.id)
        #expect(branchMessages.count == 2, "播种 user + 占位/完成 assistant")
        let seed = branchMessages[0]
        #expect(seed.role == .user && seed.branchID == row.id)
        #expect(seed.content == row.seedContext)
        #expect(seed.metadataJSON?.contains("seedContext") == true)
        #expect(await driver.sessionCount == 1)
        #expect(await driver.sessionOwner(at: 0) == .branch(row.id))
        #expect(await driver.sentPromptCount == 1)
    }

    @Test("摘要路径：usedSummary 时状态链经过 compressingContext")
    func compressingPath() async throws {
        let (coordinator, driver, _, messages) = try makeWorld(
            summarizer: FakeSummarizer(), compressionThreshold: 1
        )
        try seedMainline(messages, anchorContent: "锚点原文")

        let request = BranchCreationRequest(
            requestID: "req-sum", threadID: "t1",
            snapshot: SelectionSnapshot(messageID: "m2", quote: "锚点", start: 0, length: 2),
            anchorPlainText: "锚点原文", userQuestion: "追问", projectRoot: "/tmp"
        )
        let collector = StateCollector()
        await collector.collect(await coordinator.startCreation(request))

        try await driveSeedToCompletion(driver: driver)
        try await waitFor("状态机到 ready") { await collector.last == .ready }

        #expect(
            await collector.states == [
                .idle, .composingQuestion, .preparingContext, .compressingContext,
                .creatingSession, .sendingSeed, .streaming, .ready,
            ]
        )
    }

    // MARK: - BR-06 防重复

    @Test("BR-06：同锚点同问题并发两次 startCreation → 只建一行、只建一个 session、只发一次播种")
    func duplicateCreationIsDeduplicated() async throws {
        let assembler = GatedAssembler()
        let (coordinator, driver, branches) = try makeCoordinatorWorld(assembler: assembler)

        let snapshot = SelectionSnapshot(messageID: "m2", quote: "引文", start: 0, length: 2)
        let first = BranchCreationRequest(
            requestID: "req-a", threadID: "t1", snapshot: snapshot,
            anchorPlainText: "引文原文", userQuestion: "同一追问", projectRoot: "/tmp"
        )
        let second = BranchCreationRequest(
            requestID: "req-b", threadID: "t1", snapshot: snapshot,
            anchorPlainText: "引文原文", userQuestion: "同一追问", projectRoot: "/tmp"
        )
        let collectorA = StateCollector()
        let collectorB = StateCollector()
        // 门闩关闭时两次 startCreation：第二次命中进行中的相同创建，复用状态流。
        await collectorA.collect(await coordinator.startCreation(first))
        await collectorB.collect(await coordinator.startCreation(second))

        assembler.open()
        try await waitFor("播种发出") { await driver.sentPromptCount == 1 }
        let sessionID = await driver.sessionID(at: 0)
        await driver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
        try await waitFor("两路订阅都到 ready") {
            let lastA = await collectorA.last
            let lastB = await collectorB.last
            return lastA == .ready && lastB == .ready
        }

        #expect(assembler.assembleCalls == 1, "相同创建只组装一次")
        #expect(await driver.sessionCount == 1, "同一点击不得重复创建 ACP session（§7.3）")
        #expect(await driver.sentPromptCount == 1, "播种只发一次")
        #expect(try branches.listBranches(threadID: "t1").count == 1, "只建一行 branches")
    }

    // MARK: - BR-07 显式重试

    @Test("BR-07：创建 session 失败 → failed(retryable: true)；retryCreation 复用已建行 → ready，播种只发一次")
    func retryAfterSessionFailure() async throws {
        let (coordinator, driver, branches, messages) = try makeWorld()
        try seedMainline(messages, anchorContent: "锚点原文")
        await driver.failNextSession(FakeSessionError())

        let request = BranchCreationRequest(
            requestID: "req-retry", threadID: "t1",
            snapshot: SelectionSnapshot(messageID: "m2", quote: "锚点", start: 0, length: 2),
            anchorPlainText: "锚点原文", userQuestion: "追问", projectRoot: "/tmp"
        )
        let collector = StateCollector()
        await collector.collect(await coordinator.startCreation(request))

        try await waitFor("状态机到 failed") {
            if case .failed = await collector.last { return true }
            return false
        }
        guard case .failed(let retryable, _) = await collector.last else {
            Issue.record("应为 failed 终态")
            return
        }
        #expect(retryable == true, "进程/链路类失败默认可重试")
        #expect(try branches.listBranches(threadID: "t1").count == 1, "§7.3：保留失败记录用于重试")
        #expect(await driver.sentPromptCount == 0, "session 未建成不得发播种")

        // 显式重试：行已存在（branch(id:) 判断）→ 跳过组装与建行，直接重建 session 并播种。
        // （FakeDriver 首次 makeSession 失败不登记，故成功 session 在 index 0。）
        await coordinator.retryCreation(requestID: "req-retry")
        try await waitFor("重试播种发出") { await driver.sentPromptCount == 1 }
        let sessionID = await driver.sessionID(at: 0)
        await driver.emit(sessionID: sessionID, .completed(sessionID: sessionID, stopReason: "end_turn"))
        try await waitFor("重试到 ready") { await collector.last == .ready }

        #expect(try branches.listBranches(threadID: "t1").count == 1, "重试不重复建行")
        #expect(await driver.sessionCount == 1, "重试只建成一个 session（首次失败未登记）")
        #expect(await driver.sentPromptCount == 1, "播种只发一次，不自动重发")
    }

    // MARK: - 取消（§7.3 取消不耗额度）

    @Test("取消：preparingContext 阶段取消 → 绝不发 prompt、不建行（无痕），状态归 failed(已取消) 供重试")
    func cancelDuringPreparingContext() async throws {
        let assembler = GatedAssembler()
        let (coordinator, driver, branches) = try makeCoordinatorWorld(assembler: assembler)

        let request = BranchCreationRequest(
            requestID: "req-cancel", threadID: "t1",
            snapshot: SelectionSnapshot(messageID: "m2", quote: "引文", start: 0, length: 2),
            anchorPlainText: "引文原文", userQuestion: "追问", projectRoot: "/tmp"
        )
        let collector = StateCollector()
        await collector.collect(await coordinator.startCreation(request))

        try await waitFor("进入 preparingContext") { await collector.last == .preparingContext }
        await coordinator.cancelCreation(requestID: "req-cancel")

        try await waitFor("取消收口到 failed") {
            if case .failed = await collector.last { return true }
            return false
        }
        #expect(await collector.last == .failed(retryable: true, reason: "已取消"))
        #expect(await driver.sentPromptCount == 0, "sendingSeed 之前取消绝不发 prompt")
        #expect(await driver.sessionCount == 0, "取消不得创建 session")
        #expect(try branches.listBranches(threadID: "t1").isEmpty, "行未建则无痕")

        // 门闩组装器挂起的任务已取消；activeCreations 不再有该请求。
        let active = await coordinator.activeCreations
        #expect(active["req-cancel"] == nil)
    }
}

/// AnchorCoordinates 单测（DEC-07 / ADR-003）：UTF-16 偏移 → Character 偏移换算。
@Suite("AnchorCoordinates：UTF-16→Character 换算")
struct AnchorCoordinateConversionTests {

    private func convert(
        _ start: Int, _ length: Int, in text: String
    ) -> (start: Int, length: Int)? {
        AnchorCoordinates.characterRange(utf16Start: start, utf16Length: length, in: text)
    }

    private func slice(_ text: String, _ range: (start: Int, length: Int)) -> String {
        let from = text.index(text.startIndex, offsetBy: range.start)
        let to = text.index(from, offsetBy: range.length)
        return String(text[from..<to])
    }

    @Test("ASCII：两种约定一致")
    func ascii() throws {
        let range = try #require(convert(6, 5, in: "hello world"))
        #expect(range == (6, 5))
        #expect(slice("hello world", range) == "world")
    }

    @Test("中文（BMP）：UTF-16 与 Character 一一对应")
    func chinese() throws {
        let range = try #require(convert(2, 2, in: "你好世界"))
        #expect(range == (2, 2))
        #expect(slice("你好世界", range) == "世界")
    }

    @Test("emoji（代理对）：2 个 UTF-16 单元 = 1 个 Character")
    func emoji() throws {
        // "a😀b"：😀 占 UTF-16 [1,3)。
        let emojiRange = try #require(convert(1, 2, in: "a😀b"))
        #expect(emojiRange == (1, 1))
        #expect(slice("a😀b", emojiRange) == "😀")

        let bRange = try #require(convert(3, 1, in: "a😀b"))
        #expect(bRange == (2, 1))
        #expect(slice("a😀b", bRange) == "b")
    }

    @Test("组合字符（e + 组合重音符）：2 个 UTF-16 单元 = 1 个 Character")
    func combiningCharacter() throws {
        let text = "e\u{0301}x"  // "éx"，é 为组合序列
        #expect(text.count == 2)
        #expect(text.utf16.count == 3)

        let eRange = try #require(convert(0, 2, in: text))
        #expect(eRange == (0, 1))
        #expect(slice(text, eRange) == "e\u{0301}")

        let xRange = try #require(convert(2, 1, in: text))
        #expect(xRange == (1, 1))
        #expect(slice(text, xRange) == "x")
    }

    @Test("国旗（区域指示符对）：4 个 UTF-16 单元 = 1 个 Character")
    func flag() throws {
        let text = "🇨🇳ab"
        let aRange = try #require(convert(4, 1, in: text))
        #expect(aRange == (1, 1))
        #expect(slice(text, aRange) == "a")
    }

    @Test("越界/非法区间：保守返回 nil；落在代理对中间则对齐到整个 Character")
    func invalidRanges() throws {
        #expect(convert(10, 5, in: "abc") == nil, "越界")
        #expect(convert(2, 5, in: "abc") == nil, "尾端越界")
        #expect(convert(-1, 2, in: "abc") == nil, "负起点")
        #expect(convert(0, 0, in: "abc") == nil, "零长度")
        // 落在 😀 代理对中间：Foundation 对齐到最近 Character 边界，扩展覆盖整个 😀。
        let rounded = try #require(convert(2, 1, in: "a😀b"))
        #expect(rounded == (1, 1))
        #expect(slice("a😀b", rounded) == "😀")
    }
}
