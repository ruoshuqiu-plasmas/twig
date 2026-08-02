import Foundation
import Testing
@testable import Core
import Shared

/// M4-001 对话树构建测试：结构（TREE-01/02 数据面）、DEC-09 同级排序、
/// 环/孤儿保护（TREE-06）、展平顺序与构建确定性。
@Suite("对话树构建（BranchTreeBuilder）")
struct BranchTreeBuilderTests {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.000)

    /// 构造支线；createdAt/updatedAt 默认相同，测试按需覆盖。
    private func makeBranch(
        _ id: String,
        parent: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        status: BranchStatus = .open
    ) -> Branch {
        Branch(
            id: id,
            threadID: "t1",
            parentBranchID: parent,
            acpSessionID: nil,
            anchorMessageID: "m1",
            anchorQuote: "引文-\(id)",
            anchorStart: nil,
            anchorLength: nil,
            anchorContextHash: nil,
            seedContext: nil,
            status: status,
            createdAt: createdAt ?? t0,
            updatedAt: updatedAt ?? createdAt ?? t0
        )
    }

    @Test("空输入 → 空树无异常")
    func emptyInput() {
        let tree = BranchTreeBuilder.build(branches: [])
        #expect(tree.roots.isEmpty)
        #expect(tree.issues.isEmpty)
        #expect(tree.flattened().isEmpty)
    }

    @Test("一级支线挂根（TREE-01 数据面）")
    func singleLevel() {
        let tree = BranchTreeBuilder.build(branches: [makeBranch("b1"), makeBranch("b2")])
        #expect(tree.roots.map(\.id).sorted() == ["b1", "b2"])
        #expect(tree.roots.allSatisfy { $0.depth == 0 && !$0.isOrphan && $0.children.isEmpty })
        #expect(tree.issues.isEmpty)
    }

    @Test("三级嵌套缩进层级正确（TREE-02 数据面）")
    func threeLevelNesting() {
        let tree = BranchTreeBuilder.build(branches: [
            makeBranch("b1"),
            makeBranch("b2", parent: "b1"),
            makeBranch("b3", parent: "b2"),
        ])
        #expect(tree.issues.isEmpty)
        #expect(tree.roots.count == 1)
        let flat = tree.flattened()
        #expect(flat.map(\.id) == ["b1", "b2", "b3"])
        #expect(flat.map(\.depth) == [0, 1, 2])
    }

    @Test("DEC-09 同级按最近活动降序，并列按创建时间升序")
    func siblingSorting() {
        let old = t0
        let mid = t0.addingTimeInterval(60)
        let new = t0.addingTimeInterval(120)
        let tree = BranchTreeBuilder.build(branches: [
            makeBranch("idle", createdAt: new, updatedAt: old),        // 创建新但久未活动
            makeBranch("active", createdAt: old, updatedAt: new),      // 最近活动
            makeBranch("tieA", createdAt: old, updatedAt: mid),        // 并列组：创建早
            makeBranch("tieB", createdAt: mid, updatedAt: mid),        // 并列组：创建晚
        ])
        #expect(tree.roots.map(\.id) == ["active", "tieA", "tieB", "idle"])
    }

    @Test("孤儿：parent_branch_id 指向不存在的支线 → 挂根 + 记录异常（TREE-06）")
    func orphanParent() {
        let tree = BranchTreeBuilder.build(branches: [
            makeBranch("b1"),
            makeBranch("ghost", parent: "missing-parent"),
        ])
        #expect(tree.roots.count == 2)
        let ghost = tree.roots.first { $0.id == "ghost" }
        #expect(ghost?.isOrphan == true)
        #expect(ghost?.depth == 0)
        #expect(tree.issues.contains(.orphanParent(branchID: "ghost", missingParentID: "missing-parent")))
    }

    @Test("孤儿支线的子支线仍挂在孤儿之下，不丢结构")
    func orphanKeepsChildren() {
        let tree = BranchTreeBuilder.build(branches: [
            makeBranch("orphan", parent: "missing"),
            makeBranch("child", parent: "orphan"),
        ])
        #expect(tree.roots.count == 1)
        #expect(tree.roots[0].id == "orphan")
        #expect(tree.roots[0].isOrphan)
        #expect(tree.roots[0].children.map(\.id) == ["child"])
        #expect(tree.roots[0].children[0].depth == 1)
        #expect(!tree.roots[0].children[0].isOrphan)
    }

    @Test("父链成环：不崩溃、不无限递归、环节点挂根并记录（TREE-06）")
    func cycleProtection() {
        let tree = BranchTreeBuilder.build(branches: [
            makeBranch("a", parent: "b"),
            makeBranch("b", parent: "a"),
        ])
        // 两个节点都必须出现在树中（挂根），且只出现一次。
        let flat = tree.flattened()
        #expect(flat.count == 2)
        #expect(Set(flat.map(\.id)) == ["a", "b"])
        #expect(tree.issues.contains(.cycle(branchIDs: ["a", "b"])))
    }

    @Test("成环祖先的后代支线也能展示，不随环丢失")
    func cycleDescendantStillVisible() {
        let tree = BranchTreeBuilder.build(branches: [
            makeBranch("a", parent: "b"),
            makeBranch("b", parent: "a"),
            makeBranch("c", parent: "a"),
        ])
        let flat = tree.flattened()
        #expect(Set(flat.map(\.id)) == ["a", "b", "c"])
        #expect(flat.count == 3)
    }

    @Test("先序展平：父先子后、深度随行")
    func flattenedOrder() {
        let tree = BranchTreeBuilder.build(branches: [
            makeBranch("b1", createdAt: t0, updatedAt: t0.addingTimeInterval(300)),
            makeBranch("b2", createdAt: t0, updatedAt: t0.addingTimeInterval(200)),
            makeBranch("b1c", parent: "b1"),
        ])
        let flat = tree.flattened()
        #expect(flat.map(\.id) == ["b1", "b1c", "b2"])
        #expect(flat.map(\.depth) == [0, 1, 0])
    }

    @Test("同一输入重复构建结果一致（确定性；流式 delta 不触发重建的前提）")
    func deterministic() {
        let branches = [
            makeBranch("b1", updatedAt: t0.addingTimeInterval(10)),
            makeBranch("b2", parent: "b1"),
            makeBranch("ghost", parent: "missing"),
        ]
        let first = BranchTreeBuilder.build(branches: branches)
        let second = BranchTreeBuilder.build(branches: branches)
        #expect(first == second)
    }
}
