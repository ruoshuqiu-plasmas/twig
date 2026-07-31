import Foundation

/// 支线结论回流服务（占位，M3-011 实现）。
/// CLI 压缩结论 → branch_notes → 主线注入带来源消息 → status=merged；
/// 笔记 + 注入 + 状态必须同一事务（M3-012 幂等保证）。
public enum BranchMergeServiceNamespace {}
