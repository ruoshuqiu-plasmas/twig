import SwiftUI

/// 主对话界面占位（M1-012 实现：状态机 + 流式渲染）。
public struct MainChatPlaceholderView: View {
    public init() {}

    public var body: some View {
        Text("分支对话面板 · 骨架（M1-007）")
            .frame(minWidth: 480, minHeight: 320)
    }
}
