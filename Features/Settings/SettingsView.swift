import SwiftUI

/// 设置页（任务 M2-006）：只读展示第一阶段的权限策略，不提供任何修改入口
/// （流程文档 §6.3 实现顺序 7；§6.6 交付物「设置页只读策略说明」）。
public struct SettingsView: View {

    public init() {}

    public var body: some View {
        Form {
            Section("权限策略（只读）") {
                Text("第一阶段为绝对只读策略：以下策略由应用内置，不可修改。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("自动批准（allowlist）") {
                policyRow("读文件", detail: "读取普通文件内容", decision: "自动批准")
                policyRow("列目录", detail: "列出目录内容", decision: "自动批准")
                policyRow("搜索", detail: "文本/代码搜索", decision: "自动批准")
            }
            Section("自动拒绝（default deny）") {
                policyRow("写文件", detail: "新建/覆盖/追加/编辑文件", decision: "已按只读策略拦截")
                policyRow("终端命令", detail: "执行任意终端命令", decision: "已按只读策略拦截")
                policyRow("未知/新增类型", detail: "CLI 升级出现的未识别操作", decision: "未知操作已按保守策略拦截")
                policyRow("无法解析的请求", detail: "缺少分类字段的权限请求", decision: "权限请求无法识别，已拒绝")
            }
            Section("说明") {
                Text("所有被拒绝的操作都会在对话流中留下标注，重启后仍可回看。CLI 升级新增的操作类型不会被默认批准。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 480, minHeight: 420)
    }

    private func policyRow(_ name: String, detail: String, decision: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(decision)
                .font(.callout)
                .foregroundStyle(decision == "自动批准" ? .green : .orange)
        }
    }
}

#Preview {
    SettingsView()
}
