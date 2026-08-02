import Foundation
import Shared

/// 支线上下文组装器（任务 M3-004/005，流程文档 §7.4/§7.5/§7.6）。
///
/// 职责：读锚点消息 → 收集主线问答原文 + 祖先支线链（根→叶）→
/// 超阈值时经 ``BranchSummarizer`` 压缩背景 → 按 §7.4 播种模板产出
/// ``AssembledBranchContext``。落库（branches.seed_context）与 session 创建
/// 归调用方（BranchSessionCoordinator，M3-006），本器不碰 session、不碰 UI。
///
/// DEC-05（压缩阈值，本任务关闭）：背景部分（不含模板壳）超过 **32_000 字符**
/// 才走摘要。依据 G0 实测（spike/g0-findings.md）：128KB 字符播种无截断正常
/// end_turn，阈值取显著低一档，为摘要路径留出充分余量。
///
/// DEC-06（摘要 session，本任务关闭）：摘要使用**临时独立 ACP session**
/// （生产实现见 ``ACPSummarizer``），不污染主线/支线历史。本器只依赖
/// ``BranchSummarizer`` 缝协议，不直连 ACP。
///
/// 安全约束（§7.5 / BR-10 / BR-11）：
/// - 只压缩背景部分；锚点引文（anchorQuote）与用户追问（userQuestion）**永不改写**；
/// - 摘要失败抛 ``BranchAssemblyError/summarizationFailed(reason:)``（携带原因，
///   调用方可恢复重试），**绝不静默截断**；未配置摘要器而超阈值同样按失败处理。
///
/// 第一阶段简化（择简实现，按需收紧）：
/// - 「主线相关问答」= 锚点消息**之前**的主线 user/assistant 成对消息（按 sequence）；
///   kind 为 notice/toolCall/toolResult 的一律跳过（工具卡片不带摘要行）；
/// - 嵌套支线的主线截断点取根祖先支线锚点消息在主线中的 sequence
///   （找不到时保守取全部主线，宁多勿丢）；
/// - 每级祖先支线的「关键问答」= 该支线首条 user 消息 + 最后一条 completed assistant 消息；
/// - 压缩后摘要同时覆盖主线背景与祖先链，播种模板中 [祖先支线] 段随之省略
///   （其信息已折叠进摘要，summaryNote 记录原始范围）。
public struct BranchContextAssembler: Sendable {

    /// DEC-05 拍板值：背景部分字符数阈值。
    public static let defaultCompressionThreshold = 32_000

    private let messages: MessageRepository
    private let branches: BranchRepository
    private let notes: BranchNoteRepository
    private let summarizer: (any BranchSummarizer)?
    private let compressionThreshold: Int

    public init(
        messages: MessageRepository,
        branches: BranchRepository,
        notes: BranchNoteRepository,
        summarizer: (any BranchSummarizer)? = nil,
        compressionThreshold: Int = Self.defaultCompressionThreshold
    ) {
        self.messages = messages
        self.branches = branches
        self.notes = notes
        self.summarizer = summarizer
        self.compressionThreshold = compressionThreshold
    }

    /// 按 §7.4 组装支线播种上下文。
    /// - Parameters:
    ///   - threadID: 所属主线程 id；
    ///   - parentBranchID: 父支线 id（一级支线为 nil）；非空时锚点消息在父支线消息流中定位；
    ///   - anchorMessageID: 锚点消息 id（必须存在于对应消息流，否则保守报错）；
    ///   - anchorQuote: 用户选中的原文引文（永不改写）；
    ///   - userQuestion: 用户对选中段落的追问（永不改写）。
    public func assemble(
        threadID: String,
        parentBranchID: String?,
        anchorMessageID: String,
        anchorQuote: String,
        userQuestion: String
    ) async throws -> AssembledBranchContext {
        // 1. 校验锚点消息存在（嵌套时在父支线消息流、否则在主线）。
        let anchorScopeMessages = try messages.messages(threadID: threadID, branchID: parentBranchID)
        guard anchorScopeMessages.contains(where: { $0.id == anchorMessageID }) else {
            throw BranchAssemblyError.anchorMessageNotFound(messageID: anchorMessageID)
        }

        // 2. 祖先链（沿 parent_branch_id 上溯，根→叶排序，§7.6）。
        let ancestorChain = try collectAncestorChain(from: parentBranchID)

        // 3. 主线问答原文：锚点之前（嵌套时取根祖先锚点在主线中的位置为截断点）。
        let mainlineCutoff = try mainlineCutoffSequence(
            threadID: threadID, anchorMessageID: anchorMessageID, ancestorChain: ancestorChain
        )
        let mainlineQA = try messages.messages(threadID: threadID, branchID: nil)
            .filter { $0.sequence < mainlineCutoff }
            .filter { $0.kind == .text && ($0.role == .user || $0.role == .assistant) }

        // 4. 背景部分文本（不含模板壳）：主线问答 + 祖先支线段。
        let mainlineSection = Self.formatMainlineQA(mainlineQA)
        let ancestorSection = try formatAncestorSection(threadID: threadID, chain: ancestorChain)
        let background = [mainlineSection, ancestorSection]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")

        // 5. 超阈值 → 摘要（只压背景；失败显式抛出，不截断）。
        let originalBackgroundLength = background.count
        var usedSummary = false
        var summaryNote: String?
        var effectiveBackground = background
        var effectiveAncestorSection = ancestorSection
        if originalBackgroundLength > compressionThreshold {
            guard let summarizer else {
                throw BranchAssemblyError.summarizationFailed(
                    reason: "背景 \(originalBackgroundLength) 字符超阈值 \(compressionThreshold)，但未配置摘要器"
                )
            }
            do {
                effectiveBackground = try await summarizer.summarize(background: background)
            } catch {
                // String(describing:) 保留 enum 关联值（localizedDescription 会丢详情）。
                throw BranchAssemblyError.summarizationFailed(
                    reason: "摘要生成失败：\(String(describing: error))"
                )
            }
            usedSummary = true
            // 摘要已折叠祖先链信息，祖先段不再单独出现。
            effectiveAncestorSection = ""
            summaryNote = "背景经摘要压缩：原始 \(originalBackgroundLength) 字符"
                + "（主线问答 \(mainlineQA.count) 条至锚点前 + 祖先支线 \(ancestorChain.count) 级）"
        }

        // 6. §7.4 播种模板组装（无嵌套/已压缩时省略 [祖先支线] 段）。
        var sections: [String] = ["[背景上下文]\n\(effectiveBackground)"]
        if !effectiveAncestorSection.isEmpty {
            sections.append("[祖先支线]\n\(effectiveAncestorSection)")
        }
        sections.append("[当前选中段落]\n\(anchorQuote)")
        sections.append("[用户追问]\n\(userQuestion)")
        sections.append("[来源说明]\n这是从主线程或父支线派生的独立支线。请围绕当前选中段落回答。")

        return AssembledBranchContext(
            seedContext: sections.joined(separator: "\n\n"),
            usedSummary: usedSummary,
            originalBackgroundLength: originalBackgroundLength,
            summaryNote: summaryNote
        )
    }

    // MARK: - 内部步骤

    /// 沿 parent_branch_id 上溯收集祖先链，返回**根→叶**排序（§7.6 避免语义顺序颠倒）。
    /// 祖先 id 悬空（数据损坏）时保守截断链条，不崩溃。
    private func collectAncestorChain(from parentBranchID: String?) throws -> [Branch] {
        var chain: [Branch] = []
        var cursor = parentBranchID
        while let id = cursor {
            guard let branch = try branches.branch(id: id) else { break }
            chain.insert(branch, at: 0)
            cursor = branch.parentBranchID
        }
        return chain
    }

    /// 主线截断 sequence：锚点在主线时取其 sequence；嵌套时取根祖先锚点消息
    /// 在主线中的 sequence；根祖先锚点缺失/找不到时返回 Int.max（保守保留全部主线）。
    private func mainlineCutoffSequence(
        threadID: String,
        anchorMessageID: String,
        ancestorChain: [Branch]
    ) throws -> Int {
        let lookupID = ancestorChain.isEmpty
            ? anchorMessageID
            : ancestorChain.first?.anchorMessageID
        guard let lookupID else { return Int.max }
        let mainline = try messages.messages(threadID: threadID, branchID: nil)
        return mainline.first(where: { $0.id == lookupID })?.sequence ?? Int.max
    }

    /// 主线问答排版：一问一答按 sequence 原样列出。
    private static func formatMainlineQA(_ qa: [Message]) -> String {
        qa.map { message in
            let speaker = message.role == .user ? "【用户】" : "【助手】"
            return "\(speaker)\(message.content)"
        }.joined(separator: "\n")
    }

    /// 祖先支线段排版（根→叶编号）：锚点引文 + 已回流笔记摘要 + 首条提问 + 最近完成回答。
    private func formatAncestorSection(threadID: String, chain: [Branch]) throws -> String {
        guard !chain.isEmpty else { return "" }
        var blocks: [String] = []
        for (index, branch) in chain.enumerated() {
            var lines: [String] = [
                "── 支线 \(index + 1) ──",
                "锚点引文：\(branch.anchorQuote)",
            ]
            if let note = try notes.note(forBranch: branch.id) {
                lines.append("回流笔记：\(note.summary)")
            }
            let branchMessages = try messages.messages(threadID: threadID, branchID: branch.id)
            let firstQuestion = branchMessages.first { $0.role == .user && $0.kind == .text }
            let lastAnswer = branchMessages.last {
                $0.role == .assistant && $0.kind == .text && $0.status == .completed
            }
            lines.append("首条提问：\(firstQuestion?.content ?? "（无）")")
            lines.append("最近回答：\(lastAnswer?.content ?? "（无）")")
            blocks.append(lines.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }
}

/// 组装产物（落库与发送归调用方）。
public struct AssembledBranchContext: Sendable, Equatable {
    /// §7.4 播种模板成品（注入支线新 session 的首条 user message）。
    public var seedContext: String
    /// 背景是否经过摘要压缩（true 时 seed_context 中 [祖先支线] 段已折叠）。
    public var usedSummary: Bool
    /// 摘要前背景部分的字符数（未压缩时为实际背景长度）。
    public var originalBackgroundLength: Int
    /// 摘要说明（原始范围与压缩事实），供调用方落 branches.seed_context 头注或日志。
    public var summaryNote: String?

    public init(seedContext: String, usedSummary: Bool, originalBackgroundLength: Int, summaryNote: String?) {
        self.seedContext = seedContext
        self.usedSummary = usedSummary
        self.originalBackgroundLength = originalBackgroundLength
        self.summaryNote = summaryNote
    }
}

/// 组装失败（保守报错，不产生半成品）。
public enum BranchAssemblyError: Error, Sendable, Equatable, CustomStringConvertible {
    /// 锚点消息在对应消息流（主线/父支线）中不存在。
    case anchorMessageNotFound(messageID: String)
    /// 背景超阈值但摘要失败（含未配置摘要器）；携带原因，调用方可恢复（BR-11）。
    case summarizationFailed(reason: String)

    public var description: String {
        switch self {
        case .anchorMessageNotFound(let messageID):
            return "锚点消息不存在：\(messageID)"
        case .summarizationFailed(let reason):
            return "背景摘要失败：\(reason)"
        }
    }
}

/// 背景摘要缝协议（DEC-06）：生产实现 ``ACPSummarizer`` 用临时独立 ACP session
/// 压缩背景，测试注入假实现。失败必须抛出（调用方显式处理，不静默截断）。
public protocol BranchSummarizer: Sendable {
    /// 压缩背景文本；失败抛出。
    func summarize(background: String) async throws -> String
}
