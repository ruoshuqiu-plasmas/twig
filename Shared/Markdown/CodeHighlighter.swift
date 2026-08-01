import AppKit
import Foundation
import Highlightr

/// 代码块语法高亮（任务 M2-008，ADR-002）：Highlightr（highlight.js 内核）封装。
///
/// 设计约定（§6.5）：
/// - **超长块不做一次性昂贵高亮**：超过 ``charLimit`` 直接走无高亮等宽纯文本；
/// - 未知语言交给 highlight.js 自动检测，失败/任何异常一律回退纯文本，不崩溃、不丢内容；
/// - 结果按 `语言+原文` 缓存（NSCache），滚动重建视图不重复高亮；
/// - Highlightr 基于 JavaScriptCore，非线程安全——所有调用经串行队列收敛。
public final class CodeHighlighter: @unchecked Sendable {

    public static let shared = CodeHighlighter()

    /// 超过该字符数的代码块跳过高亮（§6.5 第 6 条「超长代码块默认不一次性做昂贵高亮」）。
    /// 阈值取 10_000：远高于常见回答代码块，高亮单次耗时实测后如需收紧记入工程笔记。
    public static let charLimit = 10_000

    /// Highlightr() 初始化需要加载 JS 资源，理论上可能失败；失败则整体退化为无高亮。
    private let highlightr: Highlightr?
    private let queue = DispatchQueue(label: "twig.codehighlighter")
    private let cache = NSCache<NSString, NSAttributedString>()

    public init() {
        highlightr = Highlightr()
        highlightr?.setTheme(to: "xcode")
        if let theme = highlightr?.theme {
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            theme.setCodeFont(font)
        }
    }

    /// 高亮代码块。返回等宽字体的 NSAttributedString；
    /// 超限/初始化失败/高亮失败时回退为无样式等宽纯文本。
    public func highlighted(_ code: String, language: String?) -> NSAttributedString {
        guard code.count <= Self.charLimit else { return Self.plain(code) }
        let key = NSString(string: "\(language ?? "")\u{1}\(code)")
        if let cached = cache.object(forKey: key) { return cached }
        return queue.sync {
            if let cached = cache.object(forKey: key) { return cached }
            let result: NSAttributedString
            if let attributed = highlightr?.highlight(code, as: language) {
                result = attributed
            } else {
                result = Self.plain(code)
            }
            cache.setObject(result, forKey: key)
            return result
        }
    }

    /// 无高亮路径：等宽纯文本（超长块与失败回退共用）。
    public static func plain(_ code: String) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        ])
    }
}
