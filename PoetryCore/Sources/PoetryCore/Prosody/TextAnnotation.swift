import Foundation

/// 原文中的一个字符及其标注（用于查看语料全文时逐字标平仄、句末标韵部）。
public struct AnnotatedCharacter: Sendable, Hashable {
    public let character: Character
    /// 非汉字（标点、空白、字母）不标注。
    public let isHan: Bool
    public let tones: Set<Tone>
    /// 分句末字（其后为非汉字或行尾）在所选韵书中的韵部；非句末字为 nil，未收录为空数组。
    public let rhymeLabels: [String]?
}

public enum TextAnnotator {
    /// 按换行分行，逐字标注；空行保留为空数组。
    public static func annotate(_ text: String, book: RhymeBook, dictionary: CharDictionary) -> [[AnnotatedCharacter]] {
        text.components(separatedBy: .newlines).map { line in
            let characters = Array(line)
            return characters.indices.map { index in
                let character = characters[index]
                guard TextSegmenter.isHan(character) else {
                    return AnnotatedCharacter(character: character, isHan: false, tones: [], rhymeLabels: nil)
                }
                let isClauseEnd = index + 1 == characters.count || !TextSegmenter.isHan(characters[index + 1])
                let readings = dictionary.readings(of: character, in: book)
                return AnnotatedCharacter(character: character, isHan: true, tones: Set(readings.map(\.tone)),
                                          rhymeLabels: isClauseEnd ? readings.map(dictionary.label(of:)) : nil)
            }
        }
    }
}

extension Set where Element == Tone {
    /// 「平」「仄」，多音字为「平仄」，未收录为「？」。
    public var label: String {
        switch count {
        case 0: "？"
        case 1: first?.rawValue ?? "？"
        default: "平仄"
        }
    }
}
