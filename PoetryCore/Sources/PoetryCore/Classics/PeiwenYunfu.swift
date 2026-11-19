import Foundation

/// 《佩文韵府》条目的类别，对应原书每个韵字下的各段。
public enum YunfuEntryKind: Int, Sendable, Hashable, CaseIterable, Identifiable {
    /// 韵字本身的反切与释义。
    case gloss = 0
    /// 韵藻：以该字结尾的词语及出处。
    case yunzao
    /// 增：原书在《韵府群玉》《五车韵瑞》之外增补的韵藻。
    case zeng
    /// 对语：以该字结尾的对偶词。
    case duiyu
    /// 摘句：以该字结尾的诗句。
    case zhaiju

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .gloss: "字头"
        case .yunzao: "韵藻"
        case .zeng: "增"
        case .duiyu: "对语"
        case .zhaiju: "摘句"
        }
    }
}

/// 《佩文韵府》的一条。
public struct YunfuEntry: Sendable, Hashable {
    /// 所在平水韵韵目（`CharDictionary.groups` 的序号）。
    public let groupID: Int
    /// 韵字（原书字形）。
    public let head: String
    public let kind: YunfuEntryKind
    /// 词条：韵藻为词语，对语为以韵字结尾的一边，摘句为诗句，字头为韵字本身。
    public let phrase: String
    /// 对语的另一边；其余类别为 nil。
    public let counterpart: String?
    /// 注文，「丨」已按词条还原。
    public let note: String
    /// 注文原文（保留「丨」），用于核对还原结果。
    public let rawNote: String
    /// 卷次，例如「卷一之一」。
    public let juan: String

    public init(groupID: Int, head: String, kind: YunfuEntryKind, phrase: String, counterpart: String? = nil,
                note: String = "", rawNote: String = "", juan: String) {
        self.groupID = groupID
        self.head = head
        self.kind = kind
        self.phrase = phrase
        self.counterpart = counterpart
        self.note = note
        self.rawNote = rawNote
        self.juan = juan
    }
}

/// 注文中「丨」代指词条中的字。
public enum YunfuNote {
    /// 还原「丨」：连续的「丨」与词条等长时代指整个词条；否则从上次停下的位置起依次代指词条中的字，
    /// 到词条末尾再从头开始。例如词条「首陽東」的注「丨丨之丨」还原为「首陽之東」。
    /// 这是按原书体例推断的规则，个别注文可能还原有误，因此另存原文。
    public static func expand(_ note: String, phrase: String) -> String {
        let characters = Array(phrase)
        guard !characters.isEmpty, note.contains("丨") else { return note }
        var result = ""
        var run = 0
        var pointer = 0
        func flush() {
            guard run > 0 else { return }
            if run == characters.count {
                result += phrase
                pointer = 0
            } else {
                for step in 0..<run { result.append(characters[(pointer + step) % characters.count]) }
                pointer = (pointer + run) % characters.count
            }
            run = 0
        }
        for character in note {
            if character == "丨" {
                run += 1
            } else {
                flush()
                result.append(character)
            }
        }
        flush()
        return result
    }
}

/// 《佩文韵府》漢リポ文本（KR3k0059）的解析。
///
/// 原书每韵之下列韵字，韵字后依次为「韵藻」「增」「对语」「摘句」各段。文本按原书版面分行，
/// 一个词条可能被拆在两行，因此按以下规则判断：
/// - 上一行以「)」结束的行称为新起行；新起行开头的「单字(」是韵字。
/// - 「韵藻」「对语」「摘句」只在新起行开头或紧接注文之后算作段名；
///   「增」（或异体「増」）另须其后的词条不少于两字，以免把「增冰」这类词条误作段名。
/// - 词条后的连续注文（含跨行的注文）合为一条。
public enum PeiwenParser {
    public struct Result: Sendable {
        public let entries: [YunfuEntry]
        /// 无法归入任何韵目或韵字的片段数。
        public let skipped: Int
    }

    private enum Token: Equatable {
        case text(String)
        case note(String)
        case gap
    }

    /// 解析一个卷文件。目录卷与序、提要等非正文卷返回空结果。
    /// - Parameter groups: 平水韵韵目，用于把「上平聲一東韻」等韵目标题对应到韵目序号。
    public static func parse(_ text: String, groups: [PingshuiGroup]) -> Result {
        guard let juan = KanripoText.property("JUAN", in: text), juan.hasPrefix("卷"),
              !juan.hasSuffix("目録"), !juan.hasSuffix("目錄") else {
            return Result(entries: [], skipped: 0)
        }
        var state = State(juan: juan)
        var lineIsFresh = true
        var openNote: String?
        for line in KanripoText.bodyLines(text) {
            let trimmed = KanripoText.trimmingSpaces(line)
            guard !trimmed.isEmpty else { continue }
            if openNote == nil {
                if trimmed.hasPrefix("欽定四庫全書") || trimmed.hasPrefix("御定佩文韻府") {
                    lineIsFresh = true
                    continue
                }
                if let groupID = groupID(fromHeader: trimmed, groups: groups) {
                    state.flush()
                    state.groupID = groupID
                    state.head = nil
                    state.section = nil
                    lineIsFresh = true
                    continue
                }
            }
            let (tokens, stillOpen) = tokenize(trimmed, continuing: openNote)
            openNote = stillOpen
            state.process(tokens, lineIsFresh: lineIsFresh)
            lineIsFresh = stillOpen == nil && tokens.last.map { if case .note = $0 { true } else { false } } == true
        }
        if let openNote { state.receive(note: openNote) }
        state.flush()
        return Result(entries: state.entries, skipped: state.skipped)
    }

    /// 韵目标题，例如「上平聲　一東韻一」「去聲　二十三〓韻三」；按声部与序数对应，不依赖韵目字（可能为缺字）。
    static func groupID(fromHeader line: String, groups: [PingshuiGroup]) -> Int? {
        guard !line.contains("(") else { return nil }
        let compact = String(line.filter { !KanripoText.isSpace($0) })
        guard let section = PingshuiSection.allCases.first(where: { compact.hasPrefix($0.sourcePrefix) }) else { return nil }
        var rest = Substring(compact.dropFirst(section.sourcePrefix.count))
        let numerals: Set<Character> = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        while let last = rest.last, numerals.contains(last) { rest.removeLast() }
        guard rest.hasSuffix("韻") else { return nil }
        rest.removeLast()
        guard rest.count >= 2 else { return nil }
        rest.removeLast()
        guard let number = PingshuiTitleParser.parseChineseNumeral(String(rest)) else { return nil }
        return groups.first { $0.section == section && $0.number == number }?.id
    }

    /// 把一行切为正文、注文与空白。`continuing` 为上一行未闭合的注文；返回本行末仍未闭合的注文。
    private static func tokenize(_ line: String, continuing: String?) -> ([Token], String?) {
        var tokens: [Token] = []
        var text = ""
        var note = continuing
        var depth = continuing == nil ? 0 : 1
        func flushText() {
            if !text.isEmpty { tokens.append(.text(text)) }
            text = ""
        }
        for character in line {
            if depth > 0 {
                if character == "(" {
                    depth += 1
                    note?.append(character)
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        tokens.append(.note(note ?? ""))
                        note = nil
                    } else {
                        note?.append(character)
                    }
                } else {
                    note?.append(character)
                }
            } else if character == "(" {
                flushText()
                depth = 1
                note = ""
            } else if KanripoText.isSpace(character) {
                flushText()
                if tokens.last != .gap { tokens.append(.gap) }
            } else {
                text.append(character)
            }
        }
        flushText()
        return (tokens, depth > 0 ? note : nil)
    }

    private struct Pending {
        var kind: YunfuEntryKind
        var phrase: String
        var notes: [String]
    }

    private struct State {
        let juan: String
        var groupID: Int?
        var head: String?
        var section: YunfuEntryKind?
        var phraseBuffer = ""
        var pending: Pending?
        var entries: [YunfuEntry] = []
        var skipped = 0

        init(juan: String) {
            self.juan = juan
        }

        mutating func process(_ tokens: [Token], lineIsFresh: Bool) {
            var previous: Token?
            for (index, token) in tokens.enumerated() {
                let next = index + 1 < tokens.count ? tokens[index + 1] : nil
                switch token {
                case .gap:
                    break
                case .note(let note):
                    receive(note: note)
                case .text(var text):
                    let atLineStart = previous == nil
                    let afterNote = { if case .note = previous { true } else { false } }()
                    let nextIsNote = { if case .note = next { true } else { false } }()
                    // 韵字：新起行开头的单字；或字头注后隔空白另起的单字（一行排两个韵字时）。
                    if text.count == 1, nextIsNote,
                       (atLineStart && lineIsFresh) || (previous == .gap && section == .gloss) {
                        flush()
                        head = text
                        section = .gloss
                        pending = Pending(kind: .gloss, phrase: text, notes: [])
                        break
                    }
                    if (atLineStart && lineIsFresh) || afterNote || previous == .gap {
                        text = consumeMarkers(text, next: next)
                    }
                    guard !text.isEmpty else { break }
                    switch section {
                    case .duiyu, .zhaiju, nil:
                        skipped += 1
                    case .gloss, .yunzao, .zeng:
                        // 字头注后未见段名就出现词条：按韵藻处理。
                        if section == .gloss { switchSection(.yunzao) }
                        if pending?.notes.isEmpty == false { flush() }
                        phraseBuffer += text
                    }
                }
                previous = token
            }
        }

        /// 去掉开头的段名并切换段落，返回剩下的正文。
        private mutating func consumeMarkers(_ text: String, next: Token?) -> String {
            var rest = Substring(text)
            while true {
                if rest.hasPrefix("韻藻") {
                    switchSection(.yunzao)
                    rest = rest.dropFirst(2)
                } else if rest.hasPrefix("對語") {
                    switchSection(.duiyu)
                    rest = rest.dropFirst(2)
                } else if rest.hasPrefix("摘句") || rest.hasPrefix("\(KanripoText.missingCharacter)句") {
                    switchSection(.zhaiju)
                    rest = rest.dropFirst(2)
                } else if rest.hasPrefix("增") || rest.hasPrefix("増"), section == .gloss || section == .yunzao,
                          rest.count == 1 || rest.count >= 3 {
                    switchSection(.zeng)
                    rest = rest.dropFirst()
                } else {
                    return String(rest)
                }
            }
        }

        private mutating func switchSection(_ kind: YunfuEntryKind) {
            flush()
            section = kind
        }

        mutating func receive(note: String) {
            switch section {
            case .duiyu:
                let halves = note.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                guard halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty else {
                    skipped += 1
                    return
                }
                append(kind: .duiyu, phrase: halves[1], counterpart: halves[0], notes: [])
            case .zhaiju:
                for column in note.split(separator: "/").map(String.init) {
                    for line in PeiwenParser.splitQuotations(column, head: head ?? "") {
                        append(kind: .zhaiju, phrase: line, counterpart: nil, notes: [])
                    }
                }
            case .gloss:
                pending?.notes.append(note)
            case .yunzao, .zeng:
                if !phraseBuffer.isEmpty {
                    if let current = pending { finish(current) }
                    pending = Pending(kind: section ?? .yunzao, phrase: phraseBuffer, notes: [note])
                    phraseBuffer = ""
                } else if pending != nil {
                    pending?.notes.append(note)
                } else {
                    skipped += 1
                }
            case nil:
                skipped += 1
            }
        }

        mutating func flush() {
            if let current = pending { finish(current) }
            pending = nil
            // 词条后没有注文（原书偶有只列词语、不注出处的）。
            if !phraseBuffer.isEmpty, let section, section == .yunzao || section == .zeng {
                append(kind: section, phrase: phraseBuffer, counterpart: nil, notes: [])
            }
            phraseBuffer = ""
        }

        private mutating func finish(_ current: Pending) {
            append(kind: current.kind, phrase: current.phrase, counterpart: nil, notes: current.notes)
        }

        private mutating func append(kind: YunfuEntryKind, phrase: String, counterpart: String?, notes: [String]) {
            guard let groupID, let head else {
                skipped += 1
                return
            }
            let raw = notes.map(KanripoText.joinColumns).joined()
            entries.append(YunfuEntry(groupID: groupID, head: head, kind: kind, phrase: phrase, counterpart: counterpart,
                                      note: YunfuNote.expand(raw, phrase: phrase), rawNote: raw, juan: juan))
        }
    }

    /// 摘句的一行小字可能连写几句（如「内庭秋燕玉池東半溪春水帶愁東」）：每句以韵字结尾、句长相同时拆开。
    static func splitQuotations(_ column: String, head: String) -> [String] {
        let characters = Array(column)
        guard let headCharacter = head.first, head.count == 1, !characters.isEmpty else {
            return characters.isEmpty ? [] : [column]
        }
        for length in [7, 5, 4, 6, 3] where characters.count > length && characters.count % length == 0 {
            let chunks = stride(from: 0, to: characters.count, by: length).map { Array(characters[$0..<($0 + length)]) }
            if chunks.allSatisfy({ $0.last == headCharacter }) { return chunks.map { String($0) } }
        }
        return [column]
    }
}
