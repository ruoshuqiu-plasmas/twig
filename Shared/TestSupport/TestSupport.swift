import Foundation

/// 测试用 fake CLI 生成器：在临时目录构造 `home/.kimi-code/` 结构，
/// 供 CLIEnvironmentProbe / ACPProcessSupervisor 测试注入。
///
/// 生成的 `kimi` 为 bash 脚本：`--version` 输出指定版本号；
/// 其余参数（`acp` 模式）执行调用方给定的 bash 片段（``Behavior``）。
public enum FakeCLI {

    /// acp 模式下 fake CLI 的行为脚本。
    public enum Behavior {
        /// 逐行回显（`ACK:<行>`），stdin 关闭后 exit 0（模拟 G0 优雅退出语义）。
        public static let echo = """
        while IFS= read -r line; do
          echo "ACK:$line"
        done
        exit 0
        """
        /// 立即以 42 退出（模拟崩溃循环）。
        public static let crash = "exit 42"
        /// 忽略 SIGTERM 且不读 stdin 的死循环（验证优雅停止超时后的 SIGKILL 升级）。
        public static let hang = """
        trap '' TERM
        while true; do
          sleep 0.05
        done
        """
    }

    /// 创建 fake home 目录，返回其 URL。
    /// - Parameters:
    ///   - version: `--version` 输出的版本号（任意字符串，用于不可解析场景）。
    ///   - acpBehavior: acp 模式 bash 片段，默认 ``Behavior/echo``。
    ///   - withCredentials: 是否生成 `credentials` 凭据文件。
    public static func makeHome(
        version: String = "0.31.0",
        acpBehavior: String = Behavior.echo,
        withCredentials: Bool = true
    ) throws -> URL {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fake-home-\(UUID().uuidString)")
        let bin = home.appendingPathComponent(".kimi-code/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let script = """
        #!/bin/bash
        if [ "$1" = "--version" ]; then
          echo '\(version)'
          exit 0
        fi
        \(acpBehavior)
        """
        let cli = bin.appendingPathComponent("kimi")
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        if withCredentials {
            try Data().write(to: home.appendingPathComponent(".kimi-code/credentials"))
        }
        return home
    }
}
