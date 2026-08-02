import Foundation

/// 锚点坐标换算（DEC-07 / ADR-003，任务 M3-006）。
///
/// 两种约定的桥接：
/// - ``SelectionSnapshot``（UI 选区）：start/length 是相对锚点消息**渲染后纯文本**
///   的 **UTF-16** 偏移（NSTextView 原生约定）；
/// - branches 表 anchor_start/anchor_length：**Character** 偏移（``AnchorResolver`` 解析约定）。
///
/// 创建支线落库前必须经本助手换算一次；emoji（代理对）与组合字符（如 e+◌́、国旗）
/// 在两种约定下长度不同，直接搬运会错位。
public enum AnchorCoordinates {

    /// UTF-16 区间 → Character 偏移。区间越界、长度为 0 时返回 nil（调用方保守落
    /// nil 坐标，回跳时按引文搜索兜底）；落在代理对/组合序列中间时由 Foundation
    /// 对齐到最近 Character 边界（扩展覆盖整个 Character）。
    public static func characterRange(
        utf16Start: Int,
        utf16Length: Int,
        in plainText: String
    ) -> (start: Int, length: Int)? {
        guard utf16Start >= 0, utf16Length > 0,
              let range = Range(NSRange(location: utf16Start, length: utf16Length), in: plainText)
        else { return nil }
        let start = plainText.distance(from: plainText.startIndex, to: range.lowerBound)
        let length = plainText.distance(from: range.lowerBound, to: range.upperBound)
        return (start, length)
    }
}
