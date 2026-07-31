import Foundation

/// ACP 协议适配层输出的统一领域事件（占位，M1-009 定义）。
/// 核心约束：ACP SDK 类型不得扩散到 Feature 层，协议适配集中在 ACP adapter；
/// 未知/损坏协议事件保守记录，不崩溃。
public enum AgentEvent {}
