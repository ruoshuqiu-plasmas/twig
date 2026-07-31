import Foundation
import GRDB

/// 应用数据库入口（任务 M1-011）。
///
/// 核心约束：
/// - 数据库存取通过 Repository 层，本类型只持有连接与迁移；
/// - 每次 schema 变化新增 migration（不改已发布 migration，见 ``Migrations``）；
/// - 应用用文件库（Application Support），测试用内存库。
public struct AppDatabase: Sendable {

    public let db: any DatabaseWriter

    public init(_ db: any DatabaseWriter) throws {
        self.db = db
        try Migrations.migrator.migrate(db)
    }

    /// 应用默认文件库（`~/Library/Application Support/twig/twig.sqlite`）。
    public static func makeDefault(
        directory: URL = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("twig", isDirectory: true)
    ) throws -> AppDatabase {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("twig.sqlite")
        return try AppDatabase(DatabasePool(path: url.path))
    }

    /// 内存库（测试用；每个实例独立）。
    public static func makeInMemory() throws -> AppDatabase {
        try AppDatabase(DatabaseQueue())
    }
}
