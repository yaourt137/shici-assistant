import Foundation

public enum ShengLvQiMengError: Error, Equatable, CustomStringConvertible {
    case missingResource
    case unknownSection(String)
    case noSections

    public var description: String {
        switch self {
        case .missingResource: "缺少内置资源：shenglvqimeng.wiki"
        case .unknownSection(let title): "《声律启蒙》节名无法对应平水韵：\(title)"
        case .noSections: "《声律启蒙》文本中没有任何一节"
        }
    }
}

/// 《声律启蒙》（车万育）：上下两卷各十五节，依次对应平水韵上平、下平十五韵。
///
/// 文本取自维基文库「聲律啓蒙」的 wikitext（原书为公有领域作品）。每节三段，每段四行，行内以「，」「；」分句、「。」断句。
public struct ShengLvQiMeng: Sendable {
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

    /// 一组对仗，例如「雲」对「雨」、「三尺劍」对「六鈞弓」。
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

    public let sections: [Section]
    public let couplets: [Couplet]

    public static func loadBundled(groups: [PingshuiGroup]) throws -> ShengLvQiMeng {
        guard let url = Bundle.module.url(forResource: "shenglvqimeng", withExtension: "wiki", subdirectory: "Resources") else {
            throw ShengLvQiMengError.missingResource
        }
        return try ShengLvQiMeng(wikitext: String(contentsOf: url, encoding: .utf8), groups: groups)
    }

    /// - Parameter groups: 平水韵韵目，用于把「卷上 · 一、東」对应到上平一东。
    public init(wikitext: String, groups: [PingshuiGroup]) throws {
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
                guard let volume, let id = ShengLvQiMeng.groupID(forTitle: name, volume: volume, groups: groups) else {
                    throw ShengLvQiMengError.unknownSection(name)
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
                stanza.append(ShengLvQiMeng.parseLine(line))
            }
        }
        endSection()
        guard !sections.isEmpty else { throw ShengLvQiMengError.noSections }
        self.sections = sections
        self.couplets = sections.flatMap { section in
            section.stanzas.flatMap { $0 }.flatMap { ShengLvQiMeng.couplets(in: $0.text, sectionIndex: section.index) }
        }
    }

    /// 「一、東」→ 该卷第一韵。按序数对应，节名中的韵目字仅作核对。
    static func groupID(forTitle title: String, volume: PingshuiSection, groups: [PingshuiGroup]) -> Int? {
        let parts = title.split(separator: "、", maxSplits: 1)
        guard parts.count == 2, let number = PingshuiTitleParser.parseChineseNumeral(String(parts[0])),
              let group = groups.first(where: { $0.section == volume && $0.number == number }),
              parts[1].first == group.headCharacter else { return nil }
        return group.id
    }

    /// `{{另|主文|异文}}` 取主文；韵脚为每句（「。」前）末字，三分句的句子第二分句末字亦押韵（如「雲對雨，雪對風，晚照對晴空」）。
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
            switch character {
            case "，", "；":
                if index > 0 { clauseEnds.append(index - 1) }
            case "。":
                if index > 0 { clauseEnds.append(index - 1) }
                if clauseEnds.count == 3 { offsets.append(clauseEnds[1]) }
                if let last = clauseEnds.last { offsets.append(last) }
                clauseEnds = []
            default:
                break
            }
        }
        return Line(text: text, variant: variant, rhymeOffsets: offsets)
    }

    /// 一句中的对仗：「甲對乙」分句各成一对；其余等长的相邻分句两两成对。
    static func couplets(in text: String, sectionIndex: Int) -> [Couplet] {
        var result: [Couplet] = []
        for sentence in text.split(separator: "。") {
            var plain: [String] = []
            for clause in sentence.split(whereSeparator: { $0 == "，" || $0 == "；" }).map(String.init) {
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
            if converter.simplified(couplet.left) == target { return CoupletMatch(couplet: couplet, counterpart: couplet.right) }
            if converter.simplified(couplet.right) == target { return CoupletMatch(couplet: couplet, counterpart: couplet.left) }
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
