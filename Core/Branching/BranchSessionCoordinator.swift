import Foundation
import Logging
import Shared

/// 支线创建状态机阶段（任务 M3-006，流程文档 §7.3 原文路径）：
/// `idle → composingQuestion → preparingContext → compressingContext（可选）
///  → creatingSession → sendingSeed → streaming → ready`；任一步骤 → `failed`。
public enum BranchCreationState: Sendable, Equatable {
    /// 初始态（请求已登记，编排尚未推进）。
    case idle
    /// 用户已提交追问（冻结选区快照与问题文本）。
    case composingQuestion
    /// 正在组装背景上下文（BranchContextAssembler）。
    case preparingContext
    /// 背景超阈值经摘要压缩（仅 Assembler 产物 usedSummary 时经过；
    /// 压缩发生在组装器内部，本态作为「已压缩」标记在推进到创建 session 前发出）。
    case compressingContext
    /// 正在创建支线 ACP session（openBranch）。
    case creatingSession
    /// 正在发送播种消息（首条 user message，metadata 带 seedContext 标记）。
    case sendingSeed
    /// 播种已发出，等待支线流式回答完成。
    case streaming
    /// 播种回答完成，支线可用（§7.3：创建 session 前不得标记可用，此态为唯一可用信号）。
    case ready
    /// 失败；`retryable` 区分可重试/不可重试（与 ConversationStore.isRetryable 同款规则）。
    case failed(retryable: Bool, reason: String)
}

/// 支线创建请求（一次「追问」点击的全部冻结输入）。
public struct BranchCreationRequest: Sendable, Equatable {
    /// 请求唯一 id（取消/重试凭据；调用方生成）。
    public var requestID: String
    /// 所属主线程 id。
    public var threadID: String
    /// 父支线 id（一级支线为 nil）。
    public var parentBranchID: String?
    /// 冻结选区快照（messageID/quote/start/length；start/length 为 UTF-16 偏移）。
    public var snapshot: SelectionSnapshot
    /// 锚点消息渲染后纯文本（坐标换算与上下文指纹的基准）。
    public var anchorPlainText: String
    /// 用户对选中段落的追问（永不改写）。
    public var userQuestion: String
    /// 工作目录（创建 session 的 cwd）。
    public var projectRoot: String

    public init(
        requestID: String,
        threadID: String,
        parentBranchID: String? = nil,
        snapshot: SelectionSnapshot,
        anchorPlainText: String,
        userQuestion: String,
        projectRoot: String
    ) {
        self.requestID = requestID
        self.threadID = threadID
        self.parentBranchID = parentBranchID
        self.snapshot = snapshot
        self.anchorPlainText = anchorPlainText
        self.userQuestion = userQuestion
        self.projectRoot = projectRoot
    }
}

/// 背景组装缝（生产注入 ``BranchContextAssembler``；测试可注入慢速/门闩实现）。
public protocol BranchContextAssembling: Sendable {
    func assemble(
        threadID: String,
        parentBranchID: String?,
        anchorMessageID: String,
        anchorQuote: String,
        userQuestion: String
    ) async throws -> AssembledBranchContext
}

extension BranchContextAssembler: BranchContextAssembling {}

/// 支线 session 创建状态机（任务 M3-006，流程文档 §7.3；BR-06 防重复、BR-07 显式重试）。
///
/// 编排顺序（硬性）：
/// 1. 状态推进 → Assembler 组装背景；**组装成功后才建 branches 行**
///    （锚点坐标经 ``AnchorCoordinates`` 换算为 Character 偏移 + ``AnchorResolver`` 上下文指纹，
///    seed_context 一并落库，status open）；
/// 2. ``ConversationStore/openBranch`` 创建 session（creatingSession）；
/// 3. ``ConversationStore/sendBranchMessage`` 发送播种消息（sendingSeed，
///    metadata `["seedContext": "true"]`）；
/// 4. 订阅 ``ConversationStore/branchSnapshots`` 观察 phase：completed → ready；
///    failed/interrupted → failed（retryable 按 ConversationStore.isRetryable 同款规则）。
///
/// §7.3 硬性要求落实：
/// - **取消不耗额度**：sendingSeed 之前取消则绝不发 prompt（发 prompt 前最后一刻复查取消标记）；
///   行未建则无痕（create 原子，未执行即无痕迹）；行已建未播种则保留行
///   （status open、无 session），状态归 `failed(retryable: true, reason: "已取消")` 供重试。
/// - **防重复（BR-06）**：进行中存在同 (anchorMessageID + quote + question) 的创建时，
///   ``startCreation(_:)`` 直接返回该创建的已有状态流（新订阅者），不新建 session/行。
/// - **显式重试（BR-07）**：失败后 ``retryCreation(requestID:)`` 用保留的请求重跑编排；
///   行已存在（``BranchRepository/branch(id:)`` 判断）则跳过组装与建行（避免重复摘要耗额度），
///   已播种过则直接转 streaming 观察。绝不自动重发（额度意识）。
/// - **后台任务有主**：全部编排 Task 登记在对应 CreationRecord 内；``activeCreations``
///   可查进行中创建。**面板关闭契约**：调用方按 activeCreations 逐条决定
///   ``cancelCreation(requestID:)`` 或任其继续（继续时播种与落库在后台完成，下次打开面板
///   可直接看到 ready 支线），不存在无主任务。
///
/// 不属本层：追问 UI（Features/BranchPanel）、权限决策（PermissionPolicyEngine）、
/// 回流（BranchMergeService）。
public actor BranchSessionCoordinator {

    /// 单次创建的运行记录（actor 内私有；全部编排 Task 登记在册）。
    private struct CreationRecord {
        var request: BranchCreationRequest
        var state: BranchCreationState = .idle
        /// 已建 branches 行 id（建行成功后登记；重试据此跳过建行）。
        var branchID: String?
        /// 播种消息是否已发出（已发出的重试不再重复播种）。
        var seedSent = false
        /// 取消标记（编排检查点在关键步骤前复查）。
        var cancelled = false
        var task: Task<Void, Never>?
        /// 状态流订阅者（BR-06 重复请求会追加订阅同一记录）。
        var continuations: [UUID: AsyncStream<BranchCreationState>.Continuation] = [:]
    }

    private let assembler: any BranchContextAssembling
    private let branches: BranchRepository
    private let conversation: ConversationStore
    private let now: @Sendable () -> Date
    private let logger: Logger

    /// requestID → 记录。失败记录保留供重试；ready 后移除。
    private var records: [String: CreationRecord] = [:]
    /// 防重复键 → requestID（仅进行中；终态即移除）。
    private var inFlightKeys: [String: String] = [:]

    public init(
        assembler: any BranchContextAssembling,
        branches: BranchRepository,
        conversation: ConversationStore,
        now: @escaping @Sendable () -> Date = Date.init,
        logger: Logger = Logger(label: "twig.branch.coordinator")
    ) {
        self.assembler = assembler
        self.branches = branches
        self.conversation = conversation
        self.now = now
        self.logger = logger
    }

    // MARK: - 公开接口

    /// 发起支线创建，返回状态流（回放当前态，随后逐态推进；ready 时流结束，
    /// failed 时流保持开启以便 ``retryCreation(requestID:)`` 后续推进）。
    /// 进行中有同 (anchorMessageID + quote + question) 的创建时，返回该创建的状态流（BR-06）。
    public func startCreation(_ request: BranchCreationRequest) -> AsyncStream<BranchCreationState> {
        let key = Self.dedupeKey(of: request)
        if let existingID = inFlightKeys[key], records[existingID] != nil {
            logger.debug("命中进行中的相同创建，复用状态流（BR-06）")
            return subscribe(requestID: existingID)
        }
        records[request.requestID] = CreationRecord(request: request)
        inFlightKeys[key] = request.requestID
        // 先注册订阅者（回放 idle）再起跑，避免漏掉早期状态。
        let stream = subscribe(requestID: request.requestID)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(requestID: request.requestID)
        }
        records[request.requestID]?.task = task
        return stream
    }

    /// 取消创建（§7.3「取消不耗额度」）：sendingSeed 之前取消则绝不发 prompt；
    /// 行未建则无痕，行已建未播种则保留行。播种已发出后调用保守忽略（额度已耗，无法回收）。
    public func cancelCreation(requestID: String) {
        guard let record = records[requestID] else { return }
        switch record.state {
        case .idle, .composingQuestion, .preparingContext, .compressingContext,
             .creatingSession, .sendingSeed:
            records[requestID]?.cancelled = true
            // 唤醒挂起在组装器门闩等处的编排任务；检查点统一收口到 failed(已取消)。
            record.task?.cancel()
        case .streaming, .ready, .failed:
            logger.debug("当前状态不接受取消（保守忽略）：request=\(requestID.prefix(8))…")
        }
    }

    /// 显式重试（BR-07）：仅 failed 状态可重试；行已存在则跳过组装与建行，
    /// 已播种过则直接转 streaming 观察。重试产生明确的新推进，不自动重发。
    public func retryCreation(requestID: String) {
        guard let record = records[requestID], case .failed = record.state else {
            logger.debug("当前状态不支持重试（保守忽略）：request=\(requestID.prefix(8))…")
            return
        }
        records[requestID]?.cancelled = false
        inFlightKeys[Self.dedupeKey(of: record.request)] = requestID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(requestID: requestID)
        }
        records[requestID]?.task = task
    }

    /// 进行中的创建（requestID → 当前状态）。**面板关闭契约**：调用方据此逐条决定
    /// 取消或继续（继续时后台完成播种与落库）；本表之外没有游离任务。
    public var activeCreations: [String: BranchCreationState] {
        records.compactMapValues { record in
            if case .failed = record.state { return nil }
            return record.state
        }
    }

    // MARK: - 编排

    private func run(requestID: String) async {
        guard let record = records[requestID] else { return }
        let request = record.request
        do {
            var branchID = record.branchID
            var seedContext: String?

            // 重试且行已存在（branch(id:) 判断）：跳过组装与建行，
            // seed_context 已在库，避免重复摘要耗额度。行意外丢失则落回完整路径重建。
            if let existingID = branchID {
                if let existing = try branches.branch(id: existingID) {
                    seedContext = existing.seedContext
                } else {
                    branchID = nil
                    records[requestID]?.branchID = nil
                }
            }

            if seedContext == nil {
                // 1. 组装背景（composingQuestion → preparingContext；摘要路径经过 compressingContext）。
                advance(requestID: requestID, to: .composingQuestion)
                advance(requestID: requestID, to: .preparingContext)
                let assembled = try await assembler.assemble(
                    threadID: request.threadID,
                    parentBranchID: request.parentBranchID,
                    anchorMessageID: request.snapshot.messageID,
                    anchorQuote: request.snapshot.quote,
                    userQuestion: request.userQuestion
                )
                if assembled.usedSummary {
                    advance(requestID: requestID, to: .compressingContext)
                }
                // 取消检查点：组装后、建行前（此阶段取消则无痕）。
                try throwIfCancelled(requestID: requestID)
                seedContext = assembled.seedContext

                // 2. 组装成功后才建 branches 行（ADR-003：UTF-16 → Character 坐标换算 + 上下文指纹）。
                let coordinates = AnchorCoordinates.characterRange(
                    utf16Start: request.snapshot.start,
                    utf16Length: request.snapshot.length,
                    in: request.anchorPlainText
                )
                let branch = try branches.create(
                    threadID: request.threadID,
                    parentBranchID: request.parentBranchID,
                    anchorMessageID: request.snapshot.messageID,
                    anchorQuote: request.snapshot.quote,
                    anchorStart: coordinates?.start,
                    anchorLength: coordinates?.length,
                    anchorContextHash: AnchorResolver.contextHash(of: request.anchorPlainText),
                    seedContext: assembled.seedContext,
                    at: now()
                )
                branchID = branch.id
                records[requestID]?.branchID = branch.id
            }

            guard let branchID, let seedContext else { return }

            // 3-4. 创建 session 并播种（已播种过的重试直接转 streaming 观察）。
            if !record.seedSent {
                advance(requestID: requestID, to: .creatingSession)
                try throwIfCancelled(requestID: requestID)
                _ = try await conversation.openBranch(
                    branchID: branchID, threadID: request.threadID, projectRoot: request.projectRoot
                )
                advance(requestID: requestID, to: .sendingSeed)
                // §7.3「取消不耗额度」：发 prompt 前最后一刻复查取消标记。
                try throwIfCancelled(requestID: requestID)
                try await conversation.sendBranchMessage(
                    branchID: branchID, text: seedContext, metadata: ["seedContext": "true"]
                )
                records[requestID]?.seedSent = true
            }

            // 5. 观察支线阶段：completed → ready；failed → 同款可重试分类。
            advance(requestID: requestID, to: .streaming)
            await observeBranch(requestID: requestID, branchID: branchID)
        } catch is CancellationError {
            failCancelled(requestID: requestID)
        } catch {
            if records[requestID]?.cancelled == true {
                failCancelled(requestID: requestID)
            } else {
                let reason = String(describing: error)
                logger.warning("支线创建失败（request=\(requestID.prefix(8))…）：\(reason)")
                advance(
                    requestID: requestID,
                    to: .failed(retryable: ConversationStore.isRetryable(reason: reason), reason: reason)
                )
            }
        }
    }

    /// 观察支线快照流直到终态（completed/failed/interrupted）。
    private func observeBranch(requestID: String, branchID: String) async {
        let stream = await conversation.branchSnapshots(branchID: branchID)
        for await snapshot in stream {
            switch snapshot.phase {
            case .completed:
                advance(requestID: requestID, to: .ready)
                return
            case .failed(let retryable, let reason):
                advance(requestID: requestID, to: .failed(retryable: retryable, reason: reason))
                return
            case .interrupted:
                advance(requestID: requestID, to: .failed(retryable: true, reason: "播种流式中断"))
                return
            default:
                continue
            }
        }
        // 事件流意外终止（进程死亡等）：保守标失败可重试，不悬挂在 streaming。
        if records[requestID]?.state == .streaming {
            advance(requestID: requestID, to: .failed(retryable: true, reason: "支线事件流终止"))
        }
    }

    // MARK: - 内部

    /// 取消收口：行未建则无痕（create 未执行）；行已建未播种则保留行供重试。
    private func failCancelled(requestID: String) {
        advance(requestID: requestID, to: .failed(retryable: true, reason: "已取消"))
    }

    private func throwIfCancelled(requestID: String) throws {
        if records[requestID]?.cancelled == true { throw CancellationError() }
    }

    /// 状态推进：更新记录并广播；ready 终态结束全部订阅并移除记录，
    /// failed 终态移出防重复表（记录保留供重试、订阅保持开启）。
    private func advance(requestID: String, to state: BranchCreationState) {
        guard var record = records[requestID] else { return }
        record.state = state
        records[requestID] = record
        for continuation in record.continuations.values {
            continuation.yield(state)
        }
        switch state {
        case .ready:
            for continuation in record.continuations.values {
                continuation.finish()
            }
            records.removeValue(forKey: requestID)
            inFlightKeys.removeValue(forKey: Self.dedupeKey(of: record.request))
        case .failed:
            inFlightKeys.removeValue(forKey: Self.dedupeKey(of: record.request))
        default:
            break
        }
    }

    /// 订阅指定创建的状态流（回放当前态；BR-06 重复请求复用同一记录）。
    private func subscribe(requestID: String) -> AsyncStream<BranchCreationState> {
        let id = UUID()
        return AsyncStream { continuation in
            guard let record = records[requestID] else {
                continuation.finish()
                return
            }
            records[requestID]?.continuations[id] = continuation
            continuation.yield(record.state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(requestID: requestID, id: id) }
            }
        }
    }

    private func removeContinuation(requestID: String, id: UUID) {
        records[requestID]?.continuations.removeValue(forKey: id)
    }

    /// 防重复键（BR-06）：锚点消息 + 引文 + 追问。
    private static func dedupeKey(of request: BranchCreationRequest) -> String {
        [request.snapshot.messageID, request.snapshot.quote, request.userQuestion]
            .joined(separator: "\u{1F}")
    }
}
