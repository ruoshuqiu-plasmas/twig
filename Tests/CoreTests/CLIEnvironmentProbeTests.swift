import Foundation
import Testing
@testable import Core
import Shared

/// CLIEnvironmentProbe 单元测试（M1-008）。
/// 三类失败对应 G1-02（缺失）/ G1-03（版本不兼容）/ G1-04（未登录）验收场景。
@Suite("CLIEnvironmentProbe 环境检测", .serialized)
struct CLIEnvironmentProbeTests {

    @Test("CLI 缺失 → cliMissing（G1-02）")
    func cliMissing() async throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("empty-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let result = await CLIEnvironmentProbe(homeDirectory: home).probe()
        #expect(result == .cliMissing)
    }

    @Test("环境齐备 → ok，版本与路径正确")
    func probeOK() async throws {
        let home = try FakeCLI.makeHome(version: "0.31.0")
        let probe = CLIEnvironmentProbe(homeDirectory: home)
        let result = await probe.probe()
        guard case .ok(let env) = result else {
            Issue.record("应为 .ok，实际 \(result)")
            return
        }
        #expect(env.version == "0.31.0")
        #expect(env.cliPath == probe.cliPath)
    }

    @Test("版本低于基线 → unsupportedVersion（G1-03）")
    func unsupportedLowVersion() async throws {
        let home = try FakeCLI.makeHome(version: "0.20.0")
        let result = await CLIEnvironmentProbe(homeDirectory: home).probe()
        #expect(result == .unsupportedVersion(found: "0.20.0"))
    }

    @Test("版本输出无法解析 → unsupportedVersion(nil)")
    func unparsableVersion() async throws {
        let home = try FakeCLI.makeHome(version: "not-a-version")
        let result = await CLIEnvironmentProbe(homeDirectory: home).probe()
        #expect(result == .unsupportedVersion(found: nil))
    }

    @Test("凭据缺失 → loginRequired（G1-04）")
    func loginRequired() async throws {
        let home = try FakeCLI.makeHome(withCredentials: false)
        let result = await CLIEnvironmentProbe(homeDirectory: home).probe()
        #expect(result == .loginRequired)
    }

    @Test("版本提取容忍噪声")
    func extractVersion() {
        #expect(CLIEnvironmentProbe.extractVersion(from: "0.31.0\n") == "0.31.0")
        #expect(CLIEnvironmentProbe.extractVersion(from: "kimi 1.2.3 (build 9)") == "1.2.3")
        #expect(CLIEnvironmentProbe.extractVersion(from: "no version") == nil)
    }

    @Test("版本比较：等于/高于基线通过，低于拒绝")
    func versionComparison() {
        #expect(CLIEnvironmentProbe.isVersion("0.31.0", atLeast: "0.31.0"))
        #expect(CLIEnvironmentProbe.isVersion("0.31.1", atLeast: "0.31.0"))
        #expect(CLIEnvironmentProbe.isVersion("1.0.0", atLeast: "0.31.0"))
        #expect(!CLIEnvironmentProbe.isVersion("0.30.9", atLeast: "0.31.0"))
        #expect(!CLIEnvironmentProbe.isVersion("0.31.0", atLeast: "1.0.0"))
    }
}
