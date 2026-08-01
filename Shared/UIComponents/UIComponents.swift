import SwiftUI

/// 工具调用折叠卡片（任务 M2-002）：工具名 + 状态徽标 + 路径摘要 + 结果区（超长默认折叠）。
///
/// 组件只接受原始数据类型——``ToolCallRecord`` 属 Core 层，Shared 为底层模块不反向依赖；
/// 调用方（Features）负责从消息 metadata 解码后传入。
public struct ToolCallCard: View {

    /// 工具名（ToolCallRecord.title）。
    public let title: String
    /// 状态（ToolCallStatus.rawValue 字符串；按字符串配色，不引入 Core 类型）。
    public let status: String
    /// 工具类别（kind，如 read/edit/execute）。
    public let kind: String?
    /// 关联文件路径（locations）。
    public let paths: [String]
    /// 结果摘要文本（超长默认折叠）。
    public let content: String

    @State private var expanded = false

    /// 结果区超过该长度默认折叠（截断预览 + 展开按钮）。
    private static let collapseThreshold = 400

    public init(title: String, status: String, kind: String? = nil, paths: [String] = [], content: String = "") {
        self.title = title
        self.status = status
        self.kind = kind
        self.paths = paths
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(title, systemImage: icon)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                statusBadge
                Spacer()
            }
            if !paths.isEmpty {
                Text(paths.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
                    .textSelection(.enabled)
            }
            if !content.isEmpty {
                Text(displayContent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if content.count > Self.collapseThreshold {
                    Button(expanded ? "收起" : "展开全部") { expanded.toggle() }
                        .font(.caption)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private var displayContent: String {
        if expanded || content.count <= Self.collapseThreshold { return content }
        return String(content.prefix(Self.collapseThreshold)) + " …"
    }

    private var statusBadge: some View {
        Text(statusTitle)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15), in: Capsule())
            .foregroundStyle(statusColor)
    }

    private var statusTitle: String {
        switch status {
        case "requested": return "待执行"
        case "running": return "执行中"
        case "succeeded": return "已完成"
        case "failed": return "失败"
        case "denied": return "已拒绝"
        default: return status
        }
    }

    /// 五态配色（requested/running 蓝、succeeded 绿、failed 红、denied 橙）。
    private var statusColor: Color {
        switch status {
        case "requested", "running": return .blue
        case "succeeded": return .green
        case "failed": return .red
        case "denied": return .orange
        default: return .secondary
        }
    }

    private var icon: String {
        switch kind {
        case "read": return "doc.text.magnifyingglass"
        case "edit": return "pencil.line"
        case "execute": return "terminal"
        default: return "wrench"
        }
    }
}
