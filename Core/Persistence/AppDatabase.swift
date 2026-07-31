import Foundation

/// 应用数据库入口（占位，M1-011 实现，GRDB）。
/// 核心约束：数据库存取通过 Repository 层；不把完整 ACP SDK 对象直接序列化进库；
/// 每次 schema 变化新增 migration（不改已发布 migration）。
public enum AppDatabaseNamespace {}
