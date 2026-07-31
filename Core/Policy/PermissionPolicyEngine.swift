import Foundation

/// 权限策略引擎（占位，M2-004 实现）。
/// 核心约束：permission 回调只进入本引擎，不由 View 决定。
/// 第一阶段绝对只读：allowlist 仅读文件/列目录/搜索；写、终端命令、未知类型、
/// 无法解析的请求一律默认拒绝（default deny）。
public enum PermissionPolicyEngineNamespace {}
