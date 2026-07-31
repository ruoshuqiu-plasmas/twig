import Foundation

/// ACP 子进程生命周期 Supervisor（占位，M1-008 实现）。
/// 状态机 notChecked…failed(reason)，有限重启 + 退避（流程文档 §5.5）。
/// 终止方式依据 G0 实测：关闭 stdin 优雅退出（exit 0）；SIGTERM 无效；强杀用 SIGKILL。
public enum ACPProcessSupervisorNamespace {}
