import Foundation

/// 正文中的一个汉字及其在原文（按 Character 计）中的位置。
public struct TextChar: Sendable, Hashable {
    public let character: Character
    public let offset: Int

    public init(character: Character, offset: Int) {
        self.character = character
        self.offset = offset
    }
}

/// 把正文切分为句：任何非汉字字符（标点、空白、换行、字母）都视为分隔。
public enum TextSegmenter {
    public static func isHan(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first else { return false }
        return scalar.properties.isIdeographic
    }

    /// - Parameter placeholders: 视同汉字、占一个字位的缺字符号（如语料中的「□」），不作分隔。
    public static func segments(of text: String, placeholders: Set<Character> = []) -> [[TextChar]] {
        var result: [[TextChar]] = []
        var current: [TextChar] = []
        for (offset, character) in text.enumerated() {
            if isHan(character) || placeholders.contains(character) {
                current.append(TextChar(character: character, offset: offset))
            } else if !current.isEmpty {
                result.append(current)
                current = []
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// 只保留汉字的字符串。
    public static func hanOnly(_ text: String) -> String {
        String(text.filter(isHan))
    }

    /// 按模板句长对齐：句读一致则直接使用；总字数一致则按句长重新切分；否则原样返回并标记未对齐。
    public static func fit(_ segments: [[TextChar]], lengths: [Int]) -> (lines: [[TextChar]], aligned: Bool) {
        if segments.map(\.count) == lengths { return (segments, true) }
        let flat = segments.flatMap { $0 }
        guard flat.count == lengths.reduce(0, +) else { return (segments, false) }
        var lines: [[TextChar]] = []
        var start = 0
        for length in lengths {
            lines.append(Array(flat[start..<(start + length)]))
            start += length
        }
        return (lines, true)
    }
}
