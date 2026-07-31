import Foundation

/// 环境检测结果（三类失败对应 G1-02/03/04 验收场景）。
public enum CLIProbeResult: Sendable, Equatable {
    /// 全部通过，可启动子进程。
    case ok(CLIEnvironment)
    /// CLI 不存在或不可执行。
    case cliMissing
    /// 版本无法解析或低于基线。
    case unsupportedVersion(found: String?)
    /// 凭据文件缺失（快速预判；最终以 ACP 握手为准，G0 实测已登录时 session/new 直接成功）。
    case loginRequired
}

/// 探测到的 CLI 环境信息。
public struct CLIEnvironment: Sendable, Equatable {
    public var cliPath: String
    public var version: String
}

/// CLI 环境探测（任务 M1-001 的 Swift 落地，M1-008 接入 Supervisor）。
///
/// 检测项与数据源：
/// - 存在性：`~/.kimi-code/bin/kimi` 可执行文件；
/// - 版本：`kimi --version`（实测输出裸版本号，如 `0.31.0`），要求 ≥ 基线版本
///   （ADR-001 兼容矩阵首行 0.31.0；CLI 升级导致兼容失败时回退已验证版本，见矩阵维护规则）；
/// - 登录态：`~/.kimi-code/credentials` 凭据文件存在性（快速预判，不读取内容）。
public struct CLIEnvironmentProbe: Sendable {

    public var homeDirectory: URL
    /// 兼容基线版本（ADR-001）。
    public var minimumVersion: String
    /// `kimi --version` 子命令超时。
    public var versionCommandTimeout: Duration

    public init(
        homeDirectory: URL,
        minimumVersion: String = "0.31.0",
        versionCommandTimeout: Duration = .seconds(5)
    ) {
        self.homeDirectory = homeDirectory
        self.minimumVersion = minimumVersion
        self.versionCommandTimeout = versionCommandTimeout
    }

    public var cliPath: String {
        homeDirectory.appendingPathComponent(".kimi-code/bin/kimi").path
    }

    public var credentialsPath: String {
        homeDirectory.appendingPathComponent(".kimi-code/credentials").path
    }

    public func probe() async -> CLIProbeResult {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: cliPath) else {
            return .cliMissing
        }
        guard let output = await runVersionCommand() else {
            return .unsupportedVersion(found: nil)
        }
        guard let version = Self.extractVersion(from: output) else {
            return .unsupportedVersion(found: nil)
        }
        guard Self.isVersion(version, atLeast: minimumVersion) else {
            return .unsupportedVersion(found: version)
        }
        guard fm.fileExists(atPath: credentialsPath) else {
            return .loginRequired
        }
        return .ok(CLIEnvironment(cliPath: cliPath, version: version))
    }

    /// 从命令输出中提取首个语义版本号（容忍前后噪声与换行）。
    public static func extractVersion(from output: String) -> String? {
        guard let match = output.firstMatch(of: #/[0-9]+\.[0-9]+\.[0-9]+/#) else {
            return nil
        }
        return String(match.output)
    }

    /// 语义版本比较：`version >= minimum`（逐段数值比较，缺段补 0）。
    public static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.split(separator: ".").map { Int($0) ?? 0 }
        }
        let lhs = parts(version), rhs = parts(minimum)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return true
    }

    /// 全程挂起（suspension），绝不阻塞线程：阻塞协作线程池会让 swiftpm-testing-helper
    /// 无法及时处理子进程 dyld 启动通知，导致并行测试下子进程卡在 dyld 阶段假死（2026-07-31 实测）。
    /// terminationHandler 在 run() 之前设置，避免进程秒退的竞态。
    /// 版本输出极小，不存在管道缓冲写满风险；超时直接 SIGKILL。
    private func runVersionCommand() async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        // 看门狗只负责超时 SIGKILL；退出等待统一走 finished 流，
        // 保证函数返回前进程一定已退出（否则 Process 运行中 dealloc 会抛 NSException）。
        let watchdog = Task {
            try? await Task.sleep(for: self.versionCommandTimeout)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        for await _ in finished {}
        watchdog.cancel()
        guard process.terminationStatus == 0 else {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
