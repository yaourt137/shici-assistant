import Foundation

/// 韵脚要求：候选的末字须在某韵部、某声调下有读音。
public struct RhymeRequirement: Sendable, Hashable {
    public let key: RhymeKey
    public let tone: Tone

    public init(key: RhymeKey, tone: Tone) {
        self.key = key
        self.tone = tone
    }
}

/// 一个可替换位置的格律约束。
public struct SlotConstraint: Sendable, Hashable {
    public let slots: [ToneSlot]
    public let rhyme: RhymeRequirement?
    /// 判断平仄所用的韵书。
    public let book: RhymeBook

    public init(slots: [ToneSlot], rhyme: RhymeRequirement?, book: RhymeBook) {
        self.slots = slots
        self.rhyme = rhyme
        self.book = book
    }

    public var length: Int { slots.count }
    public var patternText: String { String(slots.map(\.rawValue)) }

    /// 候选文本（只计汉字）是否满足约束。未收录字只能落在「中」位。
    public func accepts(_ text: String, dictionary: CharDictionary) -> Bool {
        let characters = Array(TextSegmenter.hanOnly(text))
        guard characters.count == slots.count else { return false }
        for (slot, character) in zip(slots, characters) where !slot.accepts(dictionary.tones(of: character, in: book)) {
            return false
        }
        guard let rhyme, let last = characters.last else { return true }
        return dictionary.rhymeKeys(of: last, in: rhyme.key.book, tone: rhyme.tone).contains(rhyme.key)
    }

    /// 用于 SQL 预筛选的位掩码：要求为平的位置与要求为仄的位置。
    public var requiredMasks: ToneMasks {
        var ping: Int64 = 0
        var ze: Int64 = 0
        for (index, slot) in slots.enumerated() where index < ToneMasks.maxLength {
            switch slot {
            case .ping: ping |= 1 << index
            case .ze: ze |= 1 << index
            case .any: break
            }
        }
        return ToneMasks(ping: ping, ze: ze)
    }
}

/// 每个位置「可读平」「可读仄」的位掩码，供语料索引快速筛选。
public struct ToneMasks: Sendable, Hashable {
    public static let maxLength = 62

    public let ping: Int64
    public let ze: Int64

    public init(ping: Int64, ze: Int64) {
        self.ping = ping
        self.ze = ze
    }

    public static func of(_ characters: [Character], book: RhymeBook, dictionary: CharDictionary) -> ToneMasks {
        var ping: Int64 = 0
        var ze: Int64 = 0
        for (index, character) in characters.enumerated() where index < maxLength {
            let tones = dictionary.tones(of: character, in: book)
            if tones.contains(.ping) { ping |= 1 << index }
            if tones.contains(.ze) { ze |= 1 << index }
        }
        return ToneMasks(ping: ping, ze: ze)
    }

    /// 候选掩码是否覆盖要求掩码。
    public func satisfies(_ required: ToneMasks) -> Bool {
        (ping & required.ping) == required.ping && (ze & required.ze) == required.ze
    }
}

extension PoemAnalysis {
    /// 选中某句第 `range` 个字时生成的替换约束。
    /// 有模板时取模板要求；无模板时保持原字平仄（多音字视为可平可仄）。
    public func constraint(line lineIndex: Int, range: ClosedRange<Int>) -> SlotConstraint? {
        guard lines.indices.contains(lineIndex) else { return nil }
        let line = lines[lineIndex]
        guard range.lowerBound >= 0, range.upperBound < line.characters.count else { return nil }
        let selected = line.characters[range]
        let slots: [ToneSlot] = selected.map { character in
            if let expected = character.expected { return expected }
            if character.tones.count == 1, let tone = character.tones.first { return ToneSlot(tone) }
            return .any
        }
        var rhyme: RhymeRequirement?
        if range.upperBound == line.characters.count - 1,
           let group = line.characters[range.upperBound].rhymeGroup,
           let key = rhymeKeys[group],
           let tone = line.characters[range.upperBound].expected?.tone {
            rhyme = RhymeRequirement(key: key, tone: tone)
        }
        return SlotConstraint(slots: slots, rhyme: rhyme, book: book)
    }
}

/// 把正文中若干位置（按 Character 计）的字替换为候选文本中的汉字。
public enum TextReplacement {
    /// 位置数与候选汉字数不等、或位置越界时返回 nil；标点与其他位置保持不变。
    public static func replace(in text: String, offsets: [Int], with replacement: String) -> String? {
        let characters = Array(TextSegmenter.hanOnly(replacement))
        guard !offsets.isEmpty, characters.count == offsets.count else { return nil }
        var body = Array(text)
        for (offset, character) in zip(offsets, characters) {
            guard body.indices.contains(offset) else { return nil }
            body[offset] = character
        }
        return String(body)
    }
}
