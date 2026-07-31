import SwiftUI
import Features

/// 应用入口（M1-007 骨架占位）。
/// 真实界面自任务 M1-012（主对话 UI）起填充。
@main
struct BranchConversationApp: App {
    var body: some Scene {
        WindowGroup {
            MainChatPlaceholderView()
        }
    }
}
