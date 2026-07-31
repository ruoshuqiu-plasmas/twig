import Foundation
import Testing
@testable import Core
import Shared

/// ACPProcessSupervisor 单元测试（M1-008，流程文档 §5.5）。
/// 全部经 FakeCLI 脚本驱动，不触碰真实 kimi CLI（不耗会员额度）。
@Suite("ACPProcessSupervisor 生命周期与状态机", .serialized)
struct ACPProcessSupervisorTests {

    /// 轮询等待状态满足条件（测试超时兜底，避免挂死）。
    private func waitForState(
        _ supervisor: ACPProcessSupervisor,
        timeout: Duration = .seconds(5),
        where predicate: (SupervisorState) -> Bool
    ) async -> SupervisorState {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = await supervisor.state
            if predicate(current) { return current }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await supervisor.state
    }

    /// 收集状态流（验证 restarting 等中间态确实出现过）。
    private actor StateCollector {
        private(set) var seen: [SupervisorState] = []
        func add(_ s: SupervisorState) { seen.append(s) }
    }

    private func makeSupervisor(
        home: URL,
        maxRestarts: Int = 2,
        backoff: Duration = .milliseconds(10),
        shutdownTimeout: Duration = .milliseconds(500)
    ) -> ACPProcessSupervisor {
        ACPProcessSupervisor(configuration: SupervisorConfiguration(
            homeDirectory: home,
            maxRestarts: maxRestarts,
            backoffDelays: [backoff],
            gracefulShutdownTimeout: shutdownTimeout
        ))
    }

    @Test("环境检测通过 → stopped")
    func checkEnvironment() async throws {
        let home = try FakeCLI.makeHome()
        let supervisor = makeSupervisor(home: home)
        let result = await supervisor.checkEnvironment()
        guard case .ok = result else {
            Issue.record("应为 .ok，实际 \(result)")
            return
        }
        let state = await supervisor.state
        #expect(state == .stopped)
    }

    @Test("start → starting → markReady → ready → stop → stopped（完整生命周期）")
    func happyPath() async throws {
        let home = try FakeCLI.makeHome()
        let supervisor = makeSupervisor(home: home)
        await supervisor.checkEnvironment()

        await supervisor.start()
        var state = await supervisor.state
        #expect(state == .starting)

        await supervisor.markReady()
        state = await supervisor.state
        #expect(state == .ready)

        await supervisor.stop()
        state = await supervisor.state
        #expect(state == .stopped)
    }

    @Test("stdin 发送 → stdout 回显（UI 不直接读写 Pipe，经 send/stdout 流交互）")
    func stdioRoundtrip() async throws {
        let home = try FakeCLI.makeHome()
        let supervisor = makeSupervisor(home: home)
        await supervisor.checkEnvironment()
        await supervisor.start()

        // 订阅 stdout 流并收集，直到看到回显。
        let stream = await supervisor.stdout()
        let collector = StateCollector()
        let collectTask = Task {
            var buffer = Data()
            for await chunk in stream {
                buffer.append(chunk)
                if String(decoding: buffer, as: UTF8.self).contains("ACK:hello") {
                    await collector.add(.ready) // 借用 collector 做信号
                    return
                }
            }
        }

        try await supervisor.send(Data("hello\n".utf8))
        _ = await collectTask.value
        let seen = await collector.seen
        #expect(seen.count == 1, "应收到 ACK:hello 回显")

        await supervisor.stop()
    }

    @Test("优雅停止：关闭 stdin → 子进程 exit 0（G0 实测语义）")
    func gracefulStop() async throws {
        let home = try FakeCLI.makeHome()
        let supervisor = makeSupervisor(home: home, shutdownTimeout: .seconds(2))
        await supervisor.checkEnvironment()
        await supervisor.start()
        await supervisor.markReady()

        await supervisor.stop()
        // echo 行为下 stdin 关闭即退出，无需 SIGKILL，应快速到达 stopped。
        let state = await supervisor.state
        #expect(state == .stopped)
    }

    @Test("崩溃循环：有限重启 + 退避，耗尽后 failed；中间经过 restarting")
    func crashLoopExhaustsRestarts() async throws {
        let home = try FakeCLI.makeHome(acpBehavior: FakeCLI.Behavior.crash)
        let supervisor = makeSupervisor(home: home, maxRestarts: 2, backoff: .milliseconds(20))
        await supervisor.checkEnvironment()

        let collector = StateCollector()
        let states = await supervisor.states()
        let collectTask = Task {
            for await s in states {
                await collector.add(s)
                if case .failed = s { return }
            }
        }

        await supervisor.start()
        let final = await waitForState(supervisor) {
            if case .failed = $0 { return true }
            return false
        }
        guard case .failed(let reason) = final else {
            Issue.record("最终应为 failed，实际 \(final)")
            collectTask.cancel()
            return
        }
        #expect(reason.contains("重启"))
        let seen = await collector.seen
        #expect(seen.contains(.restarting), "状态流应包含 restarting，实际 \(seen)")
        collectTask.cancel()
    }

    @Test("挂死进程：优雅停止超时 → SIGKILL 升级 → stopped")
    func hungProcessKilled() async throws {
        let home = try FakeCLI.makeHome(acpBehavior: FakeCLI.Behavior.hang)
        let supervisor = makeSupervisor(home: home, shutdownTimeout: .milliseconds(300))
        await supervisor.checkEnvironment()
        await supervisor.start()
        await supervisor.markReady()

        await supervisor.stop()
        let state = await supervisor.state
        #expect(state == .stopped)
    }

    @Test("重复 start 幂等：ready 状态下再次调用不拉起新进程")
    func startIsIdempotentWhenReady() async throws {
        let home = try FakeCLI.makeHome()
        let supervisor = makeSupervisor(home: home)
        await supervisor.checkEnvironment()
        await supervisor.start()
        await supervisor.markReady()

        await supervisor.start() // 应被忽略
        let state = await supervisor.state
        #expect(state == .ready)

        await supervisor.stop()
    }
}
