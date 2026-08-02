import Foundation
import GRDB
import Testing
@testable import Core
import Shared

/// DEC-07 / ADR-003 落地测试（任务 M3-002）：
/// migration v2 升级路径 + AnchorResolver 三条解析规则。
/// 全部使用内存库，不触碰应用真实数据库文件。
@Suite("锚点坐标：migration v2 升级")
struct AnchorMigrationV2Tests {

    /// 毫秒精度日期（GRDB 日期存储精度为毫秒，避免往返比较误差）。
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    @Test("v1 库升级 v2：三列存在、旧数据无损、重复迁移幂等")
    func upgradeFromV1PreservesData() async throws {
        // 只跑到 v1，模拟 v1 时期的既有数据库。
        let queue = try DatabaseQueue()
        try Migrations.migrator.migrate(queue, upTo: "v1-core-tables")

        // 写入 v1 时期的旧支线行（无锚点坐标列，用裸 SQL 避免模型引用尚不存在的列）。
        try await queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO threads (id, title, project_root, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: ["t1", "主线程", "/tmp", t0, t0]
            )
            try db.execute(
                sql: """
                    INSERT INTO branches (id, thread_id, anchor_message_id, anchor_quote,
                                          status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: ["b1", "t1", "m1", "旧引文", BranchStatus.open.rawValue, t0, t0]
            )
        }

        // 升级 v2；再重复跑一遍验证幂等（模拟应用二次启动）。
        try Migrations.migrator.migrate(queue)
        try Migrations.migrator.migrate(queue)

        let columns = try await queue.read { db in
            Set(try Row.fetchAll(db, sql: "PRAGMA table_info(branches)").map { $0["name"] as String })
        }
        #expect(columns.isSuperset(of: ["anchor_start", "anchor_length", "anchor_context_hash"]))

        // 旧行数据无损，新列为 NULL。
        let branch = try await queue.read { db in try Branch.fetchOne(db, key: "b1") }
        #expect(branch?.anchorQuote == "旧引文")
        #expect(branch?.anchorMessageID == "m1")
        #expect(branch?.createdAt == t0)
        #expect(branch?.anchorStart == nil)
        #expect(branch?.anchorLength == nil)
        #expect(branch?.anchorContextHash == nil)
    }

    @Test("新支线带坐标入库回环：三字段完整往返")
    func anchorCoordinatesRoundtrip() async throws {
        let appDB = try AppDatabase.makeInMemory()
        try await appDB.db.write { db in
            try ConversationThread(
                id: "t1", title: "主", projectRoot: "/a", createdAt: t0, updatedAt: t0
            ).insert(db)
            try Branch(
                id: "b1", threadID: "t1",
                anchorMessageID: "m1", anchorQuote: "引文",
                anchorStart: 6, anchorLength: 2,
                anchorContextHash: AnchorResolver.contextHash(of: "渲染后的纯文本"),
                createdAt: t0, updatedAt: t0
            ).insert(db)
        }

        let branch = try await appDB.db.read { db in try Branch.fetchOne(db, key: "b1") }
        #expect(branch?.anchorStart == 6)
        #expect(branch?.anchorLength == 2)
        #expect(branch?.anchorContextHash == AnchorResolver.contextHash(of: "渲染后的纯文本"))
    }
}

@Suite("AnchorResolver：回跳解析规则（ADR-003）")
struct AnchorResolverTests {

    private let plainText = "hello world hello"
    // 字符布局：hello(0-4) 空格(5) world(6-10) 空格(11) hello(12-16)

    @Test("上下文指纹：SHA256 前 16 位 hex、确定性")
    func contextHashFormat() {
        let hash = AnchorResolver.contextHash(of: plainText)
        #expect(hash.count == 16)
        #expect(hash.allSatisfy { $0.isHexDigit })
        #expect(hash == AnchorResolver.contextHash(of: plainText))
        #expect(hash != AnchorResolver.contextHash(of: "hello world hello!"))
    }

    @Test("规则 1：start/length 切片命中 → exact")
    func rule1Exact() {
        let result = AnchorResolver.resolve(
            plainText: plainText, messageID: "m1", quote: "world",
            start: 6, length: 5, contextHash: nil
        )
        #expect(result == .exact(start: 6, length: 5, ambiguous: false))
    }

    @Test("规则 2：坐标失效但 hash 匹配、quote 唯一命中 → exact")
    func rule2UniqueHit() {
        let result = AnchorResolver.resolve(
            plainText: plainText, messageID: "m1", quote: "world",
            start: 0, length: 5,  // 切片为 "hello"，与 quote 不符
            contextHash: AnchorResolver.contextHash(of: plainText)
        )
        #expect(result == .exact(start: 6, length: 5, ambiguous: false))
    }

    @Test("规则 2：坐标字段为空、hash 匹配、quote 唯一命中 → exact")
    func rule2WithoutCoordinates() {
        let result = AnchorResolver.resolve(
            plainText: plainText, messageID: "m1", quote: "world",
            start: nil, length: nil,
            contextHash: AnchorResolver.contextHash(of: plainText)
        )
        #expect(result == .exact(start: 6, length: 5, ambiguous: false))
    }

    @Test("规则 2：多处命中取第一个 → exact(ambiguous)")
    func rule2Ambiguous() {
        let result = AnchorResolver.resolve(
            plainText: plainText, messageID: "m1", quote: "hello",
            start: nil, length: nil,
            contextHash: AnchorResolver.contextHash(of: plainText)
        )
        #expect(result == .exact(start: 0, length: 5, ambiguous: true))
    }

    @Test("规则 3：hash 不匹配（原文已变化）→ 降级消息级")
    func rule3HashMismatch() {
        let result = AnchorResolver.resolve(
            plainText: plainText, messageID: "m1", quote: "world",
            start: 0, length: 5,
            contextHash: AnchorResolver.contextHash(of: "别的文本")
        )
        #expect(result == .degradedToMessage(messageID: "m1"))
    }

    @Test("规则 3：hash 匹配但 quote 已不存在 → 降级消息级")
    func rule3QuoteNotFound() {
        let result = AnchorResolver.resolve(
            plainText: plainText, messageID: "m1", quote: "不存在",
            start: nil, length: nil,
            contextHash: AnchorResolver.contextHash(of: plainText)
        )
        #expect(result == .degradedToMessage(messageID: "m1"))
    }

    @Test("规则 3：坐标越界且无 hash → 降级消息级")
    func rule3OutOfBounds() {
        let result = AnchorResolver.resolve(
            plainText: plainText, messageID: "m1", quote: "world",
            start: 100, length: 5, contextHash: nil
        )
        #expect(result == .degradedToMessage(messageID: "m1"))
    }

    @Test("规则 3：空 quote 直接降级；messageID 缺失时降级结果为空串")
    func rule3EmptyQuote() {
        #expect(
            AnchorResolver.resolve(
                plainText: plainText, messageID: "m1", quote: "",
                start: 6, length: 5, contextHash: nil
            ) == .degradedToMessage(messageID: "m1")
        )
        #expect(
            AnchorResolver.resolve(
                plainText: plainText, messageID: nil, quote: "world",
                start: nil, length: nil, contextHash: nil
            ) == .degradedToMessage(messageID: "")
        )
    }
}
