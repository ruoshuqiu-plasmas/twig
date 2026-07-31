import Foundation

/// 测试用超时包装：到点抛 ``TimeoutError``，把挂死变成可诊断的失败。
///
/// 非结构化竞速实现：超时就绪后直接 resume，不等待被测任务结束——
/// 结构化任务组会隐式等待所有子任务，对不响应取消的挂死任务无效。
/// 超时被遗弃的任务挂起在后台，不阻塞测试进程退出。
public enum TimeoutError: Error, Sendable, CustomStringConvertible {
    case exceeded(seconds: Double, operation: String)

    public var description: String {
        switch self {
        case .exceeded(let seconds, let operation):
            return "\(operation) 超过 \(seconds)s 未完成"
        }
    }
}

/// 一次性声明器（withTimeout 内部使用）。
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

public func withTimeout<T: Sendable>(
    seconds: Double,
    operation: String,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let once = ResumeOnce()
    return try await withCheckedThrowingContinuation { continuation in
        let work = Task {
            do {
                let value = try await body()
                if once.claim() { continuation.resume(returning: value) }
            } catch {
                if once.claim() { continuation.resume(throwing: error) }
            }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if once.claim() {
                work.cancel()
                continuation.resume(throwing: TimeoutError.exceeded(seconds: seconds, operation: operation))
            }
        }
    }
}
