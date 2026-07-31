import Foundation

/// ACP 子进程生命周期 Supervisor（任务 M1-008，流程文档 §5.5）。
///
/// 职责：环境检测接入、拉起 `kimi acp` 子进程并持有 stdio 管道、
/// 转发 stdout 给上层（ACP transport，M1-009 接入）、监听终止、
/// 异常退出时有限重启 + 退避、应用退出时优雅关闭。
///
/// G0 实测依据（`spike/g0-findings.md`，勿凭猜测改动）：
/// - 优雅终止唯一可靠方式：关闭 stdin → exit 0；SIGTERM 被忽略，强杀用 SIGKILL；
/// - framing 为 NDJSON over stdio，日志走 stderr（经 ``SupervisorConfiguration/onStderrLine`` 上抛）。
///
/// 核心约束：UI 不直接读写 Pipe；上层通过 ``stdout()`` 流与 ``send(_:)`` 交互。
public actor ACPProcessSupervisor {

    public private(set) var state: SupervisorState = .notChecked
    private let config: SupervisorConfiguration

    private var process: Process?
    private var stdinHandle: FileHandle?
    /// 区分「应用主动停止」与「异常退出」（terminationHandler 共用入口）。
    private var intentionalStop = false
    private var restartCount = 0
    private var restartTask: Task<Void, Never>?
    private var stderrBuffer = ""

    private var stateContinuations: [UUID: AsyncStream<SupervisorState>.Continuation] = [:]
    private var stdoutContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    public init(configuration: SupervisorConfiguration) {
        self.config = configuration
    }

    deinit {
        restartTask?.cancel()
    }

    // MARK: - 状态观测

    /// 订阅状态流（先回放当前值，再推送后续变更；支持多订阅者）。
    public func states() -> AsyncStream<SupervisorState> {
        let id = UUID()
        return AsyncStream { continuation in
            stateContinuations[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func transition(_ newState: SupervisorState) {
        state = newState
        for continuation in stateContinuations.values {
            continuation.yield(newState)
        }
    }

    // MARK: - 环境检测（状态：notChecked → cliMissing/unsupportedVersion/loginRequired/stopped）

    /// 执行环境检测并迁移状态；返回检测结果供上层展示对应引导页。
    @discardableResult
    public func checkEnvironment() async -> CLIProbeResult {
        let result = await CLIEnvironmentProbe(homeDirectory: config.homeDirectory).probe()
        switch result {
        case .ok:
            transition(.stopped)
        case .cliMissing:
            transition(.cliMissing)
        case .unsupportedVersion(let found):
            transition(.unsupportedVersion(found: found))
        case .loginRequired:
            transition(.loginRequired)
        }
        return result
    }

    // MARK: - 启动与就绪

    /// 拉起子进程（幂等：starting/ready/restarting 调度中时不重复拉起）。
    /// 仅允许从 stopped / failed / restarting 进入；其余状态调用为编程错误，直接忽略。
    public func start() async {
        restartTask?.cancel()
        restartTask = nil
        switch state {
        case .stopped, .failed, .restarting:
            break
        default:
            return
        }
        transition(.starting)
        intentionalStop = false

        let child = Process()
        child.executableURL = URL(fileURLWithPath: config.cliPath)
        child.arguments = config.arguments
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            // EOF 不单独上抛：子进程终止统一经 terminationHandler → 状态机体现。
            guard !data.isEmpty else { return }
            Task { await self?.broadcastStdout(data) }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.consumeStderr(data) }
        }
        child.terminationHandler = { [weak self] terminated in
            Task { await self?.handleTermination(of: terminated) }
        }

        do {
            try child.run()
            process = child
            stdinHandle = stdinPipe.fileHandleForWriting
        } catch {
            transition(.failed(reason: "无法启动 CLI 子进程：\(error.localizedDescription)"))
        }
    }

    /// ACP 握手成功（M1-009 适配层调用）：进入 ready，并重置重启计数（健康会话已建立）。
    public func markReady() {
        guard state == .starting else { return }
        restartCount = 0
        transition(.ready)
    }

    /// 启动阶段失败（如握手/登录失败，M1-009 适配层调用）。
    public func markFailed(reason: String) {
        transition(.failed(reason: reason))
    }

    // MARK: - stdio 交互（上层唯一出入口）

    /// 订阅 stdout 数据流（原始字节，NDJSON framing 由 ACP transport 负责）。
    public func stdout() -> AsyncStream<Data> {
        let id = UUID()
        return AsyncStream { continuation in
            stdoutContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStdoutContinuation(id) }
            }
        }
    }

    private func removeStdoutContinuation(_ id: UUID) {
        stdoutContinuations.removeValue(forKey: id)
    }

    private func broadcastStdout(_ data: Data) {
        for continuation in stdoutContinuations.values {
            continuation.yield(data)
        }
    }

    /// 写入 stdin（向 agent 发送协议消息）。
    public func send(_ data: Data) throws {
        guard let stdinHandle else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try stdinHandle.write(contentsOf: data)
    }

    private func consumeStderr(_ data: Data) {
        stderrBuffer += String(decoding: data, as: UTF8.self)
        while let newline = stderrBuffer.firstIndex(of: "\n") {
            let line = String(stderrBuffer[stderrBuffer.startIndex..<newline])
            stderrBuffer.removeSubrange(stderrBuffer.startIndex...newline)
            config.onStderrLine(line)
        }
    }

    // MARK: - 停止

    /// 优雅停止：关闭 stdin 等待 exit 0（G0 实测唯一可靠方式），
    /// 超时升级为 SIGKILL（SIGTERM 被 kimi 忽略，跳过）。
    public func stop() async {
        restartTask?.cancel()
        restartTask = nil
        guard let child = process, child.isRunning else {
            if state != .notChecked {
                transition(.stopped)
            }
            return
        }
        intentionalStop = true
        try? stdinHandle?.close()

        let clock = ContinuousClock()
        let deadline = clock.now + config.gracefulShutdownTimeout
        while child.isRunning && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if child.isRunning {
            kill(child.processIdentifier, SIGKILL)
            // SIGKILL 后 stdout EOF 立即可观测（G0 实测），稍等其退出。
            let killDeadline = clock.now + .seconds(2)
            while child.isRunning && clock.now < killDeadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        transition(.stopped)
    }

    // MARK: - 终止处理与自动重启

    private func handleTermination(of terminated: Process) {
        // 迟到的旧进程终止事件（先杀后重启的竞态）直接忽略。
        guard terminated === process else { return }
        process = nil
        stdinHandle = nil

        if intentionalStop {
            transition(.stopped)
            return
        }

        let exitCode = terminated.terminationStatus
        restartCount += 1
        if restartCount <= config.maxRestarts {
            transition(.restarting)
            let index = min(restartCount - 1, config.backoffDelays.count - 1)
            let delay = config.backoffDelays[index]
            restartTask = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self.start()
            }
        } else {
            transition(.failed(reason: "子进程异常退出（exit \(exitCode)），自动重启 \(config.maxRestarts) 次仍未恢复"))
        }
    }
}
