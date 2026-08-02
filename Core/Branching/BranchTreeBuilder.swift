import Foundation
import Shared

/// 树构建发现的数据异常（M4-001，TREE-06）：检测并记录，不崩溃、不无限递归。
public enum BranchTreeIssue: Equatable, Sendable {
    /// parent_branch_id 指向不存在（或跨线程）的支线：节点改挂根节点，标记 orphan。
    case orphanParent(branchID: String, missingParentID: String)
    /// 父链成环：环节点改挂根节点并截断递归，标记 orphan。
    case cycle(branchIDs: [String])
}

/// 对话树节点（M4-001）：持有支线本体 + 层级 + 已排序子节点。
public struct BranchTreeNode: Equatable, Sendable {
    public let branch: Branch
    public let depth: Int
    /// 父引用无效（孤儿）或父链成环被截断：挂到根下展示但不丢弃数据。
    public let isOrphan: Bool
    public var children: [BranchTreeNode]

    public var id: String { branch.id }

    public init(branch: Branch, depth: Int, isOrphan: Bool, children: [BranchTreeNode]) {
        self.branch = branch
        self.depth = depth
        self.isOrphan = isOrphan
        self.children = children
    }
}

/// 对话树构建结果（纯数据，不依赖当前打开的右侧标签）。
public struct BranchTree: Equatable, Sendable {
    public var roots: [BranchTreeNode]
    public let issues: [BranchTreeIssue]

    public init(roots: [BranchTreeNode], issues: [BranchTreeIssue]) {
        self.roots = roots
        self.issues = issues
    }

    /// 先序展平（深度已在节点上），供 UI 直接渲染缩进列表。
    public func flattened() -> [BranchTreeNode] {
        var result: [BranchTreeNode] = []
        func walk(_ node: BranchTreeNode) {
            result.append(node)
            for child in node.children { walk(child) }
        }
        for root in roots { walk(root) }
        return result
    }
}

/// 对话树构建器（M4-001，§8.2）：纯函数一次性构建，流式 delta 期间不重建。
///
/// 结构规则：parent_branch_id == null → 根的直接子节点；否则挂到对应支线之下。
/// 排序规则（DEC-09，任务 44 定稿）：同级按最近活动 updated_at **降序**，
/// 并列按 created_at 升序、再按 id 升序兜底（保证确定性）。
///
/// 保护规则（TREE-06）：
/// - parent_branch_id 指向不存在/跨线程支线 → 记 ``BranchTreeIssue/orphanParent``，节点挂根；
/// - 父链成环 → 记 ``BranchTreeIssue/cycle``，环节点挂根并截断，不无限递归。
public enum BranchTreeBuilder {

    public static func build(branches: [Branch]) -> BranchTree {
        let byID = Dictionary(branches.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var childrenOf: [String?: [Branch]] = [:]
        for branch in branches {
            childrenOf[branch.parentBranchID, default: []].append(branch)
        }

        var issues: [BranchTreeIssue] = []
        var visited: Set<String> = []

        func sortedChildren(of parentID: String?) -> [Branch] {
            (childrenOf[parentID] ?? []).sorted(by: siblingOrder)
        }

        func siblingOrder(_ a: Branch, _ b: Branch) -> Bool {
            if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }  // DEC-09 最近活动降序
            if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
            return a.id < b.id
        }

        /// 递归构建；`path` 为当前父链，用于成环截断。
        func makeNode(_ branch: Branch, depth: Int, isOrphan: Bool, path: Set<String>) -> BranchTreeNode {
            visited.insert(branch.id)
            var nextPath = path
            nextPath.insert(branch.id)
            var children: [BranchTreeNode] = []
            for child in sortedChildren(of: branch.id) {
                if nextPath.contains(child.id) {
                    // 子节点已在父链上 → 成环边，截断不递归（环节点在收尾阶段统一挂根）。
                    continue
                }
                if visited.contains(child.id) { continue }
                children.append(makeNode(child, depth: depth + 1, isOrphan: false, path: nextPath))
            }
            return BranchTreeNode(branch: branch, depth: depth, isOrphan: isOrphan, children: children)
        }

        var roots: [BranchTreeNode] = []

        // 1) 正常根：parent_branch_id == null。
        for branch in sortedChildren(of: nil) where !visited.contains(branch.id) {
            roots.append(makeNode(branch, depth: 0, isOrphan: false, path: []))
        }

        // 2) 孤儿：parent_branch_id 指向不存在（含跨线程）的支线。
        for branch in branches where !visited.contains(branch.id) {
            guard let parentID = branch.parentBranchID else { continue }
            if byID[parentID] == nil {
                issues.append(.orphanParent(branchID: branch.id, missingParentID: parentID))
                roots.append(makeNode(branch, depth: 0, isOrphan: true, path: []))
            }
        }

        // 3) 成环节点：父引用都在表内但互指成环，上面两轮不可达。
        let cyclicIDs = branches.map(\.id).filter { !visited.contains($0) }.sorted()
        if !cyclicIDs.isEmpty {
            issues.append(.cycle(branchIDs: cyclicIDs))
            for branch in branches where cyclicIDs.contains(branch.id) && !visited.contains(branch.id) {
                roots.append(makeNode(branch, depth: 0, isOrphan: true, path: []))
            }
        }

        // 根层同样按 DEC-09 排序（孤儿/环节点与正常根混合时顺序确定）。
        roots.sort(by: { siblingOrder($0.branch, $1.branch) })

        return BranchTree(roots: roots, issues: issues)
    }
}
