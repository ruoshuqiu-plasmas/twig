import CryptoKit
import Foundation

/// 锚点回跳解析结果（DEC-07 / ADR-003；供 M3-010 树→原文回跳消费）。
public enum AnchorResolution: Equatable, Sendable {
    /// 精确定位：start/length 为锚点消息渲染后纯文本中的 Character 偏移；
    /// ambiguous = true 表示 quote 多处出现、按规则取了第一个。
    case exact(start: Int, length: Int, ambiguous: Bool)
    /// 降级：坐标与引文均失效，仅高亮整条锚点消息。
    case degradedToMessage(messageID: String)
}

/// 锚点回跳解析器（纯函数，DEC-07 / ADR-003，任务 M3-002）。
///
/// 坐标约定：start/length 相对锚点消息**渲染后纯文本**（Markdown 块渲染产物的
/// NSAttributedString.string，渲染确定性保证可复现），为 Swift Character 偏移——
/// 不是原始 markdown 源，也不是 UTF-16 偏移；创建与解析必须使用同一约定，
/// 消费端（如 NSTextView）如需 UTF-16 偏移须自行换算。
///
/// 解析规则（输入为 branch 锚点字段 + 该消息当前渲染后纯文本）：
/// 1. start/length 非空、在范围内、且切片 == quote → `.exact`；
/// 2. 否则若 contextHash 与纯文本指纹匹配：在纯文本中搜索 quote，
///    唯一命中 → `.exact`；多处命中取第一个 → `.exact(ambiguous: true)`；
/// 3. 其余一律 → `.degradedToMessage`（hash 不匹配、quote 找不到或 quote 为空）。
public enum AnchorResolver {

    /// 上下文指纹：渲染后纯文本的 SHA256 前 16 位 hex（CryptoKit）。
    /// 创建支线时与坐标一同入库；回跳时重算比对，检测锚点消息原文是否变化。
    public static func contextHash(of plainText: String) -> String {
        let digest = SHA256.hash(data: Data(plainText.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// 按 ADR-003 规则解析锚点。quote 为 branches.anchor_quote（schema 非空约束）。
    public static func resolve(
        plainText: String,
        messageID: String?,
        quote: String,
        start: Int?,
        length: Int?,
        contextHash: String?
    ) -> AnchorResolution {
        func degraded() -> AnchorResolution {
            .degradedToMessage(messageID: messageID ?? "")
        }
        guard !quote.isEmpty else { return degraded() }

        // 规则 1：坐标直接命中。
        if let start, let length, start >= 0, length > 0,
           let from = plainText.index(plainText.startIndex, offsetBy: start, limitedBy: plainText.endIndex),
           let to = plainText.index(from, offsetBy: length, limitedBy: plainText.endIndex),
           String(plainText[from..<to]) == quote {
            return .exact(start: start, length: length, ambiguous: false)
        }

        // 规则 2：原文未变化（hash 匹配）时按 quote 搜索；多处出现取第一个并标注 ambiguous。
        if let contextHash, contextHash == Self.contextHash(of: plainText) {
            var hits: [Int] = []
            var searchStart = plainText.startIndex
            while let range = plainText.range(of: quote, range: searchStart..<plainText.endIndex) {
                hits.append(plainText.distance(from: plainText.startIndex, to: range.lowerBound))
                searchStart = range.upperBound
            }
            if let first = hits.first {
                return .exact(start: first, length: quote.count, ambiguous: hits.count > 1)
            }
        }

        // 规则 3：降级到消息整体高亮。
        return degraded()
    }
}
