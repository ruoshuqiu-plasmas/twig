import Foundation
import Logging
import Shared

/// 回流结果（``BranchMergeService/merge(branchID:)`` 的返回值，BR-14 幂等语义）。
public enum BranchMergeResult: Sendable, Equatable {
    /// 首次回流成功；`injectedToACP == false` 即「本地已保存未注入」中间态
    /// （§7.8，可经 ``BranchMergeService/retryInjection(noteID:)`` 恢复）。
    case merged(noteID: String, injectedToACP: Bool)
    /// 重复合并命中幂等短路：不产生重复笔记/消息（BR-14）；
    /// `injectedToACP` 为顺带重试注入的结果（上次注入失败时自动补注）。
    case alreadyMerged(noteID: String, injectedToACP: Bool)
}

/// 回流失败（不静默、不落半成品）。
public enum BranchMergeError: Error, Sendable, Equatable {
    /// 支线（或回流笔记定位目标）不存在。
    case branchNotFound(String)
    /// closed 支线不允许合并（先判状态）。
    case alreadyClosed(String)
    /// 摘要失败（携带原因；库内零写入，调用方可恢复重试，BR-11 同原则）。
    case summarizationFailed(reason: String)
}

/// 支线结论回流服务（任务 M3-011/012，流程文档 §7.8 九步）。
///
/// 流程映射：读支线并判状态（closed 拒、merged 幂等短路）→ 收集支线对话范围 →
/// ``BranchSummarizer`` 压缩为笔记 → 组装 §7.8 四行注入消息 →
/// ``BranchRepository/recordMerge(note:mainlineMessage:branchID:at:)`` 单事务落库
/// （note + 主线消息 + status=merged + merge_note_id，幂等由仓储保证，M3-012）→
/// ``ConversationStore/injectContextToMainThread(threadID:text:)`` 向 ACP 主线程注入。
///
/// 硬要求与中间态（§7.8 / AGENTS §7）：
/// - 摘要失败抛 ``BranchMergeError/summarizationFailed(reason:)``，库内零写入；
/// - ACP 注入失败**不抛错**：注入消息 metadataJSON 的 `injectedToACP` 落 `false`，
///   返回 `.merged(noteID:, injectedToACP: false)`「本地已保存未注入」中间态，
///   UI 可经 ``retryInjection(noteID:)`` 或重复调用 ``merge(branchID:)`` 恢复；
/// - 树节点「已回流」标记由 branches.status=merged 派生（事务内已更新，§7.8 步骤 7），
///   原支线历史保留不删（步骤 8）。
///
/// 笔记 id 约定：`merge-note-<branchID>` 确定性生成——与支线一一对应，
/// ``retryInjection(noteID:)`` 借此反查支线（BranchNoteRepository 无 note(id:) 查询，
/// 不为本服务改仓储）。
public struct BranchMergeService: Sendable {

    /// 回流笔记 id 前缀（noteID ↔ branchID 双向换算依据）。
    static let noteIDPrefix = "merge-note-"

    private let branches: BranchRepository
    private let notes: BranchNoteRepository
    private let messages: MessageRepository
    private let summarizer: any BranchSummarizer
    private let conversation: ConversationStore
    private let now: @Sendable () -> Date
    private let logger: Logger

    public init(
        branches: BranchRepository,
        notes: BranchNoteRepository,
        messages: MessageRepository,
        summarizer: any BranchSummarizer,
        conversation: ConversationStore,
        now: @escaping @Sendable () -> Date = Date.init,
        logger: Logger = Logger(label: "twig.branch.merge")
    ) {
        self.branches = branches
        self.notes = notes
        self.messages = messages
        self.summarizer = summarizer
        self.conversation = conversation
        self.now = now
        self.logger = logger
    }

    /// 合并回主线（§7.8 步骤 1~6、9；幂等，重复调用安全）。
    public func merge(branchID: String) async throws -> BranchMergeResult {
        guard let branch = try branches.branch(id: branchID) else {
            throw BranchMergeError.branchNotFound(branchID)
        }
        if branch.status == .closed {
            throw BranchMergeError.alreadyClosed(branchID)
        }
        // 幂等短路（BR-14）：已回流不重复写库；上次注入失败则顺带重试注入。
        if branch.status == .merged, let note = try notes.note(forBranch: branchID) {
            let injected = try await retryInjection(noteID: note.id)
            return .alreadyMerged(noteID: note.id, injectedToACP: injected)
        }

        // 收集支线对话范围 → 摘要（失败零写入）。
        let transcript = try messages.messages(threadID: branch.threadID, branchID: branchID)
        let background = Self.formatTranscript(transcript)
        let summary: String
        do {
            summary = try await summarizer.summarize(background: background)
        } catch {
            // String(describing:) 保留 enum 关联值（localizedDescription 会丢详情）。
            throw BranchMergeError.summarizationFailed(reason: String(describing: error))
        }

        // 组装笔记 + 主线注入消息（injectedToACP 先落 pending，注入结果出来再翻牌）。
        let date = now()
        let note = BranchNote(
            id: Self.noteID(forBranch: branchID), branchID: branchID,
            threadID: branch.threadID, summary: summary, mergedAt: date
        )
        let metadataJSON = Self.encodeMetadata([
            "mergeNote": "true",
            "branchID": branchID,
            "noteID": note.id,
            "injectedToACP": "pending",
        ])
        let message = Message(
            id: UUID().uuidString, threadID: branch.threadID, branchID: nil,
            role: .system, kind: .notice,
            content: Self.noteText(note: note, branch: branch),
            sequence: try messages.nextSequence(threadID: branch.threadID),
            status: .completed, createdAt: date, updatedAt: date, metadataJSON: metadataJSON
        )

        // 单事务落库（幂等由 recordMerge 的 merge_note_id 检查兜底）。
        switch try branches.recordMerge(note: note, mainlineMessage: message, branchID: branchID, at: date) {
        case .merged(let noteID):
            let injected = try await injectIfNeeded(note: note, branch: branch)
            return .merged(noteID: noteID, injectedToACP: injected)
        case .alreadyMerged(let existingNoteID):
            // 防御路径（merge_note_id 已置但走到了全量流程）：沿用已有笔记，顺带重试注入。
            guard let existing = try notes.note(forBranch: branchID) else {
                logger.error("已回流但笔记缺失（保守处理，不重复写入）：note=\(existingNoteID.prefix(8))…")
                return .alreadyMerged(noteID: existingNoteID, injectedToACP: false)
            }
            let injected = try await retryInjection(noteID: existing.id)
            return .alreadyMerged(noteID: existing.id, injectedToACP: injected)
        }
    }

    /// 重试注入（UI 恢复「本地已保存未注入」中间态用）。
    /// 返回注入是否成功；已成功注入过的笔记直接返回 true（不重复发 prompt）。
    /// noteID 非本服务生成格式或对应支线/笔记不存在时抛 ``BranchMergeError/branchNotFound(_:)``。
    @discardableResult
    public func retryInjection(noteID: String) async throws -> Bool {
        guard noteID.hasPrefix(Self.noteIDPrefix) else {
            throw BranchMergeError.branchNotFound(noteID)
        }
        let branchID = String(noteID.dropFirst(Self.noteIDPrefix.count))
        guard let branch = try branches.branch(id: branchID) else {
            throw BranchMergeError.branchNotFound(branchID)
        }
        guard let note = try notes.note(forBranch: branchID), note.id == noteID else {
            throw BranchMergeError.branchNotFound(noteID)
        }
        return try await injectIfNeeded(note: note, branch: branch)
    }

    // MARK: - 注入与中间态

    /// 注入 ACP 主线程并按结果翻 metadata 的 `injectedToACP`（true/false）；
    /// 已成功注入的直接返回 true。注入失败不抛错（§7.8 中间态），metadata 落 false。
    private func injectIfNeeded(note: BranchNote, branch: Branch) async throws -> Bool {
        guard let message = try injectionMessage(for: note) else {
            logger.error("回流注入消息缺失（保守视为未注入）：branch=\(note.branchID.prefix(8))…")
            return false
        }
        var metadata = Self.decodeMetadata(message.metadataJSON)
        guard metadata["injectedToACP"] != "true" else { return true }
        do {
            try await conversation.injectContextToMainThread(
                threadID: note.threadID, text: Self.acpInjectionText(note: note, branch: branch)
            )
            metadata["injectedToACP"] = "true"
        } catch {
            metadata["injectedToACP"] = "false"
            logger.error("回流注入失败（本地已保存未注入，可 retryInjection 恢复）：\(error.localizedDescription)")
        }
        try messages.updateMetadata(
            messageID: message.id, content: message.content,
            metadataJSON: Self.encodeMetadata(metadata), status: message.status, at: now()
        )
        return metadata["injectedToACP"] == "true"
    }

    /// 反查该笔记对应的主线注入消息（metadata 双标记定位）。
    private func injectionMessage(for note: BranchNote) throws -> Message? {
        try messages.messages(threadID: note.threadID).first {
            let metadata = Self.decodeMetadata($0.metadataJSON)
            return metadata["mergeNote"] == "true" && metadata["branchID"] == note.branchID
        }
    }

    // MARK: - 文本组装与 metadata

    static func noteID(forBranch branchID: String) -> String {
        noteIDPrefix + branchID
    }

    /// §7.8 建议格式（持久化到主线的四行笔记消息；来源取 branch_id 前 8 位）。
    static func noteText(note: BranchNote, branch: Branch) -> String {
        """
        [支线回流笔记]
        来源支线：\(branch.id.prefix(8))
        锚点：\(branch.anchorQuote)
        结论：\(note.summary)
        """
    }

    /// ACP 注入文本：在笔记格式上补一行「无需回复」，避免 agent 把背景补充当提问展开回答。
    static func acpInjectionText(note: BranchNote, branch: Branch) -> String {
        noteText(note: note, branch: branch) + "\n（以上是支线回流的结论笔记，请知悉，无需回复）"
    }

    /// 支线对话范围排版（§7.8 步骤 2）：仅 text 消息；种子背景消息与
    /// notice/toolCall 一律跳过（工具卡片择简不带摘要行——其终态摘要对结论
    /// 压缩收益低、实现成本高，与 Assembler 的跳过约定一致）。
    static func formatTranscript(_ messages: [Message]) -> String {
        messages
            .filter { $0.kind == .text }
            .filter { !isSeedMessage($0) }
            .map { message in
                let speaker: String
                switch message.role {
                case .user: speaker = "【用户】"
                case .assistant: speaker = "【助手】"
                case .system: speaker = "【系统】"
                }
                return "\(speaker)\(message.content)"
            }
            .joined(separator: "\n")
    }

    /// 种子消息识别：ConversationStore 种子标记为 `{"kind":"seed_context"}`；
    /// 兼容手写/历史样本的 camelCase 写法（metadataJSON 含 "seedContext"）。
    /// （public：B-M3 支线面板 seed 折叠与轮数统计复用同一识别规则，M3-007。）
    public static func isSeedMessage(_ message: Message) -> Bool {
        guard let metadataJSON = message.metadataJSON else { return false }
        if metadataJSON.contains("seedContext") { return true }
        return decodeMetadata(metadataJSON)["kind"] == "seed_context"
    }

    static func encodeMetadata(_ metadata: [String: String]) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeMetadata(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }
}
