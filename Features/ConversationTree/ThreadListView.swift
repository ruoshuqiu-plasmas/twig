import SwiftUI
import AppKit
import Core
import Shared

/// 主线程列表视图（M4-007，DEC-10）：左栏顶部区块——
/// 列表（最近活动降序）/点击切换/「+」新建（标题可空 + project_root 文件夹选取）/
/// 双击就地重命名。删除/归档/移动/合并不在第一阶段。
public struct ThreadListView: View {

    @Bindable var viewModel: ThreadListViewModel

    @State private var isCreating = false
    @State private var draftTitle = ""
    @State private var draftProjectRoot = ""

    public init(viewModel: ThreadListViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            if let error = viewModel.errorBanner {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.threads, id: \.id) { thread in
                        row(thread)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 160)
        }
        .task { viewModel.start() }
        .onDisappear { viewModel.stop() }
        .sheet(isPresented: $isCreating) { creationSheet }
    }

    private var header: some View {
        HStack {
            Text("对话")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                draftTitle = ""
                draftProjectRoot = FileManager.default.currentDirectoryPath
                isCreating = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .help("新建对话")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func row(_ thread: ConversationThread) -> some View {
        HStack(spacing: 6) {
            if viewModel.renamingThreadID == thread.id {
                TextField("标题", text: $viewModel.renameDraft, onCommit: viewModel.commitRename)
                    .textFieldStyle(.roundedBorder)
            } else {
                Text(thread.title)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Text(thread.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(thread.id == viewModel.activeThreadID
                      ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { viewModel.beginRename(threadID: thread.id) }
        .onTapGesture { viewModel.switchTo(threadID: thread.id) }
        .contextMenu {
            Button("重命名") { viewModel.beginRename(threadID: thread.id) }
        }
    }

    private var creationSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建对话")
                .font(.headline)
            TextField("标题（可空，首条问题自动生成）", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("项目根目录", text: $draftProjectRoot)
                    .textFieldStyle(.roundedBorder)
                Button("选取…") { pickFolder() }
            }
            HStack {
                Spacer()
                Button("取消") { isCreating = false }
                Button("创建") {
                    isCreating = false
                    viewModel.createThread(
                        title: draftTitle.isEmpty ? nil : draftTitle,
                        projectRoot: draftProjectRoot
                    )
                }
                .disabled(draftProjectRoot.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    /// project_root 文件夹选取（NSOpenPanel；第一阶段只读，不触碰所选目录）。
    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draftProjectRoot = url.path
        }
    }
}
