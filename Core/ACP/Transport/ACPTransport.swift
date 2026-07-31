import Foundation
import ACP
import Logging

/// 架在 ``ACPProcessSupervisor`` 之上的 ACP transport（任务 M1-009）。
///
/// 职责：把 supervisor 的原始 stdout 字节流按 **NDJSON 行分帧**（G0 实测 framing：
/// 每行一个完整 JSON-RPC 消息）后交给 SDK `Client`；发送侧追加换行写入 stdin。
///
/// 核心约束：UI 不直接读写 Pipe——本子进程管道唯一的协议出入口在这里，
/// 上层的进程生命周期管理仍归 supervisor（transport 不负责拉起/停止进程）。
public actor SupervisorTransport: Transport {

    public nonisolated let logger: Logger

    private let supervisor: ACPProcessSupervisor
    private var connected = false
    private var forwardTask: Task<Void, Never>?
    private var lineBuffer = Data()
    private var streamContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation?
    private var stream: AsyncThrowingStream<Data, Swift.Error>?

    public init(supervisor: ACPProcessSupervisor, logger: Logger = Logger(label: "twig.acp.transport")) {
        self.supervisor = supervisor
        self.logger = logger
    }

    /// 幂等；重复调用直接返回。
    public func connect() async throws {
        guard !connected else { return }
        connected = true
        let (stream, continuation) = AsyncThrowingStream<Data, Swift.Error>.makeStream()
        self.stream = stream
        self.streamContinuation = continuation

        let stdout = await supervisor.stdout()
        forwardTask = Task {
            for await chunk in stdout {
                self.ingest(chunk)
            }
            self.finishStream()
        }
    }

    public func disconnect() async {
        guard connected else { return }
        connected = false
        forwardTask?.cancel()
        forwardTask = nil
        finishStream()
    }

    public func send(_ data: Data) async throws {
        guard connected else { throw TransportError.notConnected }
        var payload = data
        if !payload.contains(0x0A) {
            payload.append(0x0A) // NDJSON：每条消息以换行结尾
        } else if payload.last != 0x0A {
            payload.append(0x0A)
        }
        try await supervisor.send(payload)
    }

    /// SDK `Client` 的消息循环只调用一次（connect 之后）。
    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        guard let stream else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: TransportError.notConnected)
            }
        }
        return stream
    }

    // MARK: - NDJSON 行分帧

    private func ingest(_ chunk: Data) {
        lineBuffer.append(chunk)
        while let newlineIndex = lineBuffer.firstIndex(of: 0x0A) {
            var line = lineBuffer[lineBuffer.startIndex..<newlineIndex]
            lineBuffer.removeSubrange(lineBuffer.startIndex...newlineIndex)
            // 容忍 CRLF（防御性；G0 实测为 LF）。
            if line.last == 0x0D { line = line.dropLast() }
            guard !line.isEmpty else { continue }
            streamContinuation?.yield(Data(line))
        }
    }

    private func finishStream() {
        streamContinuation?.finish()
        streamContinuation = nil
        stream = nil
    }
}
