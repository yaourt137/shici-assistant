import Foundation

/// 用户为正文某一位置的字指定的读音（声调 + 韵部）。只在指定时所用的韵书下生效。
public struct ReadingChoice: Sendable, Hashable, Codable {
    /// 字在正文中的位置（按 Character 计，与 `AnalyzedChar.offset` 一致）。
    public let offset: Int
    /// 指定时该位置的字，用于确认位置未被改动。
    public let character: String
    public let reading: Reading

    public init(offset: Int, character: Character, reading: Reading) {
        self.offset = offset
        self.character = String(character)
        self.reading = reading
    }

    public var book: RhymeBook { reading.rhyme.book }

    /// 正文改动后仍有效的指定：只保留完全位于改动处之前的；改动发生在字本身或其前方（字的位置可能移动）时作废。
    public static func retained(_ choices: [ReadingChoice], from oldText: String, to newText: String) -> [ReadingChoice] {
        guard !choices.isEmpty, oldText != newText else { return choices }
        let unchangedPrefix = zip(oldText, newText).prefix { $0 == $1 }.count
        return choices.filter { $0.offset < unchangedPrefix }
    }

    /// 设置或清除（`reading` 为 nil）某位置在该韵书下的指定；同一位置、同一韵书只保留一个。
    public static func updating(_ choices: [ReadingChoice], character: Character, at offset: Int,
                                book: RhymeBook, to reading: Reading?) -> [ReadingChoice] {
        var result = choices.filter { !($0.offset == offset && $0.book == book) }
        if let reading, reading.rhyme.book == book {
            result.append(ReadingChoice(offset: offset, character: character, reading: reading))
            result.sort { ($0.offset, $0.book.rawValue) < ($1.offset, $1.book.rawValue) }
        }
        return result
    }
}

/// 分析时取字的读音：有有效指定者只用指定读音，否则用韵书中的全部读音。
struct ReadingResolver: Sendable {
    let dictionary: CharDictionary
    let book: RhymeBook
    private let chosen: [Int: (character: Character, reading: Reading)]

    /// 只采用韵书一致、且该字在韵书中确有此读音的指定。
    init(dictionary: CharDictionary, book: RhymeBook, choices: [ReadingChoice]) {
        self.dictionary = dictionary
        self.book = book
        var chosen: [Int: (character: Character, reading: Reading)] = [:]
        for choice in choices where choice.book == book && choice.character.count == 1 {
            guard let character = choice.character.first,
                  dictionary.readings(of: character, in: book).contains(choice.reading) else { continue }
            chosen[choice.offset] = (character, choice.reading)
        }
        self.chosen = chosen
    }

    func chosenReading(of character: Character, at offset: Int) -> Reading? {
        guard let entry = chosen[offset], entry.character == character else { return nil }
        return entry.reading
    }

    func tones(of character: Character, at offset: Int) -> Set<Tone> {
        if let reading = chosenReading(of: character, at: offset) { return [reading.tone] }
        return dictionary.tones(of: character, in: book)
    }

    /// 给定声调下的韵部。指定读音的声调不符时为空（平仄不合另有提示）。
    func rhymeKeys(of character: Character, at offset: Int, in keyBook: RhymeBook, tone: Tone) -> Set<RhymeKey> {
        guard let reading = chosenReading(of: character, at: offset) else {
            return dictionary.rhymeKeys(of: character, in: keyBook, tone: tone)
        }
        guard reading.tone == tone else { return [] }
        if keyBook == book { return [reading.rhyme] }
        if let mapped = dictionary.cilinReading(of: character, fromPingshui: reading), keyBook == .cilin {
            return [mapped.rhyme]
        }
        return dictionary.rhymeKeys(of: character, in: keyBook, tone: tone)
    }
}
