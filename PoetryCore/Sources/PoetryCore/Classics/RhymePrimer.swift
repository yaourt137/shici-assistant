import Foundation

/// 内置的对韵蒙书。两书都按平水韵三十个平声韵分节，上下两卷各十五节。
public enum PrimerWork: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// 车万育《声律启蒙》。
    case shengLvQiMeng = "shenglvqimeng"
    /// 李渔《笠翁对韵》。
    case liwengDuiyun = "liwengduiyun"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .shengLvQiMeng: "声律启蒙"
        case .liwengDuiyun: "笠翁对韵"
        }
    }

    public var author: String {
        switch self {
        case .shengLvQiMeng: "车万育"
        case .liwengDuiyun: "李渔"
        }
    }

    /// 内置资源名（`Resources/<名>.wiki`）。
    var resourceName: String { rawValue }
}

public enum RhymePrimerError: Error, Equatable, CustomStringConvertible {
    case missingResource(String)
    case unknownSection(String)
    case noSections

    public var description: String {
        switch self {
        case .missingResource(let name): "缺少内置资源：\(name).wiki"
        case .unknownSection(let title): "节名无法对应平水韵：\(title)"
        case .noSections: "文本中没有任何一节"
        }
    }
}

/// 对韵蒙书：《声律启蒙》《笠翁对韵》。
///
/// 文本取自维基文库的 wikitext（原书均为公有领域作品）。每节三段，每段若干行，行内以「，」「；」分句、「。」「？」「！」断句。
public struct RhymePrimer: Sendable {
    /// 原文的一行。
    public struct Line: Sendable, Hashable {
        /// 正文（含标点，原书字形）。
        public let text: String
        /// 维基文库以 `{{另|…|…}}` 标出的异文。
        public let variant: String?
        /// 韵脚在 `text` 中的位置（按 Character 计）。
        public let rhymeOffsets: [Int]

        public var rhymeCharacters: [Character] {
            let characters = Array(text)
            return rhymeOffsets.map { characters[$0] }
        }
    }

    public struct Section: Sendable, Hashable, Identifiable {
        /// 0...29：上卷十五节在前。
        public let index: Int
        /// 节名，例如「一、東」。
        public let title: String
        /// 对应的平水韵韵目序号。
        public let groupID: Int
        /// 各段，每段若干行。
        public let stanzas: [[Line]]

        public var id: Int { index }
    }

    /// 一组对仗，例如「雲」对「雨」、「三尺劍」对「六鈞弓」；长对保留分句间的「，」。
    public struct Couplet: Sendable, Hashable {
        public let left: String
        public let right: String
        public let sectionIndex: Int
    }

    /// 查询某词所得的对仗：`counterpart` 是另一边。
    public struct CoupletMatch: Sendable, Hashable {
        public let couplet: Couplet
        public let counterpart: String
    }

    /// 韵脚不在本节对应韵目的字（多为邻韵通押或文本讹误）。
    public struct RhymeMismatch: Sendable, Hashable {
        public let sectionIndex: Int
        public let character: Character
        /// 该字在平水韵中实际所属的韵目序号（未收录时为空）。
        public let actualGroupIDs: [Int]
    }

    public let work: PrimerWork
    public let sections: [Section]
    public let couplets: [Couplet]

    init(work: PrimerWork, sections: [Section]) throws {
        guard !sections.isEmpty else { throw RhymePrimerError.noSections }
        self.work = work
        self.sections = sections
        self.couplets = sections.flatMap { section in
            section.stanzas.flatMap { $0 }.flatMap { RhymePrimer.couplets(in: $0.text, sectionIndex: section.index) }
        }
    }

    public static func loadBundled(_ work: PrimerWork, groups: [PingshuiGroup]) throws -> RhymePrimer {
        guard let url = Bundle.module.url(forResource: work.resourceName, withExtension: "wiki", subdirectory: "Resources") else {
            throw RhymePrimerError.missingResource(work.resourceName)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        switch work {
        case .shengLvQiMeng: return try shengLvQiMeng(wikitext: text, groups: groups)
        case .liwengDuiyun: return try liwengDuiyun(wikitext: text, groups: groups)
        }
    }

    /// 《声律启蒙》：一个页面，`== 卷上 ==` 分卷、`=== 一、東 ===` 分节，空行分段。
    /// - Parameter groups: 平水韵韵目，用于把「卷上 · 一、東」对应到上平一东。
    public static func shengLvQiMeng(wikitext: String, groups: [PingshuiGroup]) throws -> RhymePrimer {
        var sections: [Section] = []
        var volume: PingshuiSection?
        var title: String?
        var groupID: Int?
        var stanzas: [[Line]] = []
        var stanza: [Line] = []

        func endStanza() {
            if !stanza.isEmpty { stanzas.append(stanza) }
            stanza = []
        }
        func endSection() {
            endStanza()
            if let title, let groupID, !stanzas.isEmpty {
                sections.append(Section(index: sections.count, title: title, groupID: groupID, stanzas: stanzas))
            }
            stanzas = []
        }

        for raw in wikitext.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("===") {
                endSection()
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
                guard let volume, let id = RhymePrimer.groupID(forTitle: name, volume: volume, groups: groups) else {
                    throw RhymePrimerError.unknownSection(name)
                }
                title = name
                groupID = id
            } else if line.hasPrefix("==") {
                endSection()
                title = nil
                groupID = nil
                if line.contains("卷上") { volume = .shangPing } else if line.contains("卷下") { volume = .xiaPing } else { volume = nil }
            } else if title == nil || line.hasPrefix("<") || line.hasPrefix("{{PD") || line.hasPrefix("[[") {
                continue
            } else if line.isEmpty {
                endStanza()
            } else {
                stanza.append(RhymePrimer.parseLine(line))
            }
        }
        endSection()
        return try RhymePrimer(work: .shengLvQiMeng, sections: sections)
    }

    /// 《笠翁对韵》：三十个子页面按目录顺序相接，每页以 `{{header … | section = 東 …}}` 开头；
    /// 正文行以「:」起首（可有全角空格缩进），只有「:」的行或空行分段。前十五页为上平，后十五页为下平。
    public static func liwengDuiyun(wikitext: String, groups: [PingshuiGroup]) throws -> RhymePrimer {
        let level = groups.filter { $0.tone == .ping }.sorted { ($0.section.rawValue, $0.number) < ($1.section.rawValue, $1.number) }
        var sections: [Section] = []
        var name: String?
        var stanzas: [[Line]] = []
        var stanza: [Line] = []

        func endStanza() {
            if !stanza.isEmpty { stanzas.append(stanza) }
            stanza = []
        }
        func endSection() throws {
            endStanza()
            defer { stanzas = [] }
            guard let name else { return }
            let index = sections.count
            guard index < level.count, level[index].headCharacter == name.first, name.count == 1 else {
                throw RhymePrimerError.unknownSection(name)
            }
            guard !stanzas.isEmpty else { return }
            let group = level[index]
            let title = "\(group.numeral)、\(name)"
            sections.append(Section(index: index, title: title, groupID: group.id, stanzas: stanzas))
        }

        for raw in wikitext.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("{{header") {
                try endSection()
                name = nil
            } else if line.hasPrefix("|"), line.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("section") {
                let value = line.firstIndex(of: "=").map { line[line.index(after: $0)...].trimmingCharacters(in: .whitespaces) }
                name = value?.isEmpty == false ? value : nil
            } else if line.hasPrefix(":") {
                let body = line.drop { $0 == ":" || KanripoText.isSpace($0) }
                if body.isEmpty { endStanza() } else { stanza.append(RhymePrimer.parseLine(String(body))) }
            } else if line.isEmpty {
                endStanza()
            }
        }
        try endSection()
        return try RhymePrimer(work: .liwengDuiyun, sections: sections)
    }

    /// 「一、東」→ 该卷第一韵。按序数对应，节名中的韵目字仅作核对。
    static func groupID(forTitle title: String, volume: PingshuiSection, groups: [PingshuiGroup]) -> Int? {
        let parts = title.split(separator: "、", maxSplits: 1)
        guard parts.count == 2, let number = PingshuiTitleParser.parseChineseNumeral(String(parts[0])),
              let group = groups.first(where: { $0.section == volume && $0.number == number }),
              parts[1].first == group.headCharacter else { return nil }
        return group.id
    }

    /// 断句的标点。
    static let sentenceEnds: Set<Character> = ["。", "？", "！"]

    /// `{{另|主文|异文}}` 取主文；韵脚为每句（「。」前）末字，三分句的句子第二分句末字亦押韵（如「雲對雨，雪對風，晚照對晴空」）。
    /// 以「？」「！」断句的只取行末一句：这类句子见于长对，前半句末字不押韵。
    static func parseLine(_ line: String) -> Line {
        var text = line
        var variant: String?
        if text.hasPrefix("{{另|"), text.hasSuffix("}}") {
            let inner = text.dropFirst(4).dropLast(2).split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            text = String(inner[0])
            variant = inner.count > 1 ? String(inner[1]) : nil
        }
        let characters = Array(text)
        var offsets: [Int] = []
        var clauseEnds: [Int] = []
        for (index, character) in characters.enumerated() {
            if character == "，" || character == "；" {
                if index > 0 { clauseEnds.append(index - 1) }
            } else if sentenceEnds.contains(character) {
                if index > 0 { clauseEnds.append(index - 1) }
                let isLineEnd = characters[(index + 1)...].allSatisfy { !TextSegmenter.isHan($0) }
                if character == "。" || isLineEnd {
                    if clauseEnds.count == 3 { offsets.append(clauseEnds[1]) }
                    if let last = clauseEnds.last { offsets.append(last) }
                }
                clauseEnds = []
            }
        }
        return Line(text: text, variant: variant, rhymeOffsets: offsets)
    }

    /// 一行中的对仗：「甲對乙」分句各成一对；其余等长的相邻分句两两成对；
    /// 以「；」分为两半、两半分句字数逐一相同的长对（如「十月塞邊，颯颯寒霜驚戍旅；三冬江上，漫漫朔雪冷漁翁」）整体成一对。
    /// 以「？」等断开的两句，若结构同样相同且不含「對」，也作长对（如「色艷北堂，草號忘憂憂甚事？香濃南國，花名含笑笑何人？」）。
    static func couplets(in text: String, sectionIndex: Int) -> [Couplet] {
        var result: [Couplet] = []
        let sentences = text.split(whereSeparator: { sentenceEnds.contains($0) })
        if sentences.count == 2, !sentences.contains(where: { $0.contains("對") || $0.contains("；") }) {
            let left = sentences[0].split(separator: "，").map(\.count)
            if left.count > 1, left == sentences[1].split(separator: "，").map(\.count) {
                result.append(Couplet(left: String(sentences[0]), right: String(sentences[1]), sectionIndex: sectionIndex))
            }
        }
        for sentence in sentences {
            let isClause: (Character) -> Bool = { $0 == "，" || $0 == "；" }
            var plain: [String] = []
            for clause in sentence.split(whereSeparator: isClause).map(String.init) {
                let sides = clause.components(separatedBy: "對")
                if sides.count == 2, !sides[0].isEmpty, sides[0].count == sides[1].count {
                    result.append(Couplet(left: sides[0], right: sides[1], sectionIndex: sectionIndex))
                } else {
                    plain.append(clause)
                }
            }
            var index = 0
            while index + 1 < plain.count {
                if plain[index].count == plain[index + 1].count {
                    result.append(Couplet(left: plain[index], right: plain[index + 1], sectionIndex: sectionIndex))
                    index += 2
                } else {
                    index += 1
                }
            }
            let halves = sentence.split(separator: "；")
            if halves.count == 2 {
                let left = halves[0].split(separator: "，").map(\.count)
                let right = halves[1].split(separator: "，").map(\.count)
                if left.count > 1, left == right {
                    result.append(Couplet(left: String(halves[0]), right: String(halves[1]), sectionIndex: sectionIndex))
                }
            }
        }
        return result
    }

    public func section(forGroup groupID: Int) -> Section? {
        sections.first { $0.groupID == groupID }
    }

    /// 与 `text` 相对的另一边（繁简不拘，只比较汉字）。
    public func couplets(matching text: String, converter: ScriptConverter) -> [CoupletMatch] {
        let target = converter.simplified(TextSegmenter.hanOnly(text))
        guard !target.isEmpty else { return [] }
        return couplets.compactMap { couplet in
            if converter.simplified(TextSegmenter.hanOnly(couplet.left)) == target {
                return CoupletMatch(couplet: couplet, counterpart: couplet.right)
            }
            if converter.simplified(TextSegmenter.hanOnly(couplet.right)) == target {
                return CoupletMatch(couplet: couplet, counterpart: couplet.left)
            }
            return nil
        }
    }

    /// 某节用作韵脚的字（简体）。
    public func rhymeCharacters(of section: Section, converter: ScriptConverter) -> Set<Character> {
        Set(section.stanzas.flatMap { $0 }.flatMap(\.rhymeCharacters).map(converter.simplified))
    }

    /// 韵脚不属本节韵目的字，按出现顺序、同节去重。
    public func rhymeMismatches(dictionary: CharDictionary) -> [RhymeMismatch] {
        var result: [RhymeMismatch] = []
        for section in sections {
            var seen = Set<Character>()
            for character in section.stanzas.flatMap({ $0 }).flatMap(\.rhymeCharacters) where !seen.contains(character) {
                seen.insert(character)
                let groups = dictionary.pingshuiGroupIDs(of: character)
                if !groups.contains(section.groupID) {
                    result.append(RhymeMismatch(sectionIndex: section.index, character: character, actualGroupIDs: groups))
                }
            }
        }
        return result
    }
}
