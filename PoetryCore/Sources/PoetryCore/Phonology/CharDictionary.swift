import Foundation

public enum CharDictionaryError: Error, CustomStringConvertible {
    case missingResource(String)
    case malformedPingshui(String)

    public var description: String {
        switch self {
        case .missingResource(let name): "缺少内置资源：\(name)"
        case .malformedPingshui(let detail): "平水韵数据格式错误：\(detail)"
        }
    }
}

/// 字音词典：整合平水韵字表、今音拼音和繁简映射，向三套韵书提供读音。
public final class CharDictionary: Sendable {
    public let groups: [PingshuiGroup]
    /// 每个韵目的字（繁体，与数据源一致）。
    public let groupCharacters: [[Character]]
    public let converter: ScriptConverter

    private let groupsByCharacter: [Character: [Int]]
    private let syllablesByCharacter: [Character: [PinyinSyllable]]
    /// 用户补充的平水韵韵目，以简体字为键。
    private let supplementGroups: [Character: [Int]]

    public static let shared: CharDictionary = {
        do {
            return try loadBundled()
        } catch {
            fatalError("内置字音数据加载失败：\(error)")
        }
    }()

    public static func loadBundled() throws -> CharDictionary {
        func text(_ name: String, _ ext: String) throws -> String {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Resources") else {
                throw CharDictionaryError.missingResource("\(name).\(ext)")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
        guard let pingshuiURL = Bundle.module.url(forResource: "pingshui", withExtension: "json", subdirectory: "Resources") else {
            throw CharDictionaryError.missingResource("pingshui.json")
        }
        return try CharDictionary(
            pingshuiJSON: try Data(contentsOf: pingshuiURL),
            pinyinText: try text("pinyin", "txt"),
            converter: ScriptConverter(
                traditionalToSimplified: try text("TSCharacters", "txt"),
                simplifiedToTraditional: try text("STCharacters", "txt")
            )
        )
    }

    public init(pingshuiJSON: Data, pinyinText: String, converter: ScriptConverter) throws {
        self.converter = converter
        let parsedGroups = try CharDictionary.parsePingshui(pingshuiJSON)
        var groups: [PingshuiGroup] = []
        var groupCharacters: [[Character]] = []
        var byCharacter: [Character: [Int]] = [:]
        for (index, entry) in parsedGroups.enumerated() {
            groups.append(PingshuiGroup(
                id: index,
                section: entry.parsed.section,
                number: entry.parsed.number,
                numeral: entry.parsed.numeral,
                headCharacter: entry.parsed.head,
                headSimplified: converter.simplified(entry.parsed.head)
            ))
            groupCharacters.append(entry.characters)
            for character in entry.characters where byCharacter[character]?.contains(index) != true {
                byCharacter[character, default: []].append(index)
            }
        }
        self.groups = groups
        self.groupCharacters = groupCharacters
        self.groupsByCharacter = byCharacter
        self.syllablesByCharacter = CharDictionary.parsePinyin(pinyinText)
        self.supplementGroups = [:]
    }

    private init(base: CharDictionary, supplementGroups: [Character: [Int]]) {
        groups = base.groups
        groupCharacters = base.groupCharacters
        converter = base.converter
        groupsByCharacter = base.groupsByCharacter
        syllablesByCharacter = base.syllablesByCharacter
        self.supplementGroups = supplementGroups
    }

    /// 加上用户补充读音后的词典（取代此前的补充，不累加）；韵目序号越界者忽略。
    public func supplemented(with readings: [CustomReading]) -> CharDictionary {
        var supplements: [Character: [Int]] = [:]
        for reading in readings where groups.indices.contains(reading.groupID) {
            let key = converter.simplified(reading.character)
            if supplements[key]?.contains(reading.groupID) != true {
                supplements[key, default: []].append(reading.groupID)
            }
        }
        return CharDictionary(base: self, supplementGroups: supplements)
    }

    private struct ParsedGroup {
        let parsed: PingshuiTitleParser.Parsed
        let characters: [Character]
    }

    private static func parsePingshui(_ data: Data) throws -> [ParsedGroup] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: [String: [String: [String]]]] else {
            throw CharDictionaryError.malformedPingshui("顶层结构应为 {平仄: {声部: {韵目: [字串]}}}")
        }
        var result: [ParsedGroup] = []
        for sections in root.values {
            for groups in sections.values {
                for (title, strings) in groups {
                    guard let parsed = PingshuiTitleParser.parse(title) else {
                        throw CharDictionaryError.malformedPingshui("无法解析韵目「\(title)」")
                    }
                    var seen = Set<Character>()
                    var characters = Array(strings.joined().filter { TextSegmenter.isHan($0) && seen.insert($0).inserted })
                    // 韵目代表字必属本韵；数据源偶有漏列（如「下平聲一先」缺「先」），补在最前。
                    if !seen.contains(parsed.head) { characters.insert(parsed.head, at: 0) }
                    result.append(ParsedGroup(parsed: parsed, characters: characters))
                }
            }
        }
        result.sort { ($0.parsed.section.rawValue, $0.parsed.number) < ($1.parsed.section.rawValue, $1.parsed.number) }
        guard result.count == 106 else {
            throw CharDictionaryError.malformedPingshui("应有 106 个韵目，实际 \(result.count) 个")
        }
        return result
    }

    /// 解析 pinyin-data 格式：`U+770B: kàn,kān  # 看`。
    static func parsePinyin(_ text: String) -> [Character: [PinyinSyllable]] {
        var result: [Character: [PinyinSyllable]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("U+") else { continue }
            let body = line.split(separator: "#", maxSplits: 1)[0]
            let parts = body.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let value = UInt32(parts[0].dropFirst(2), radix: 16),
                  let scalar = Unicode.Scalar(value) else { continue }
            let character = Character(scalar)
            let excluded = sandhiReadings[character] ?? []
            let syllables = parts[1].split(separator: ",")
                .filter { !excluded.contains($0.trimmingCharacters(in: .whitespaces)) }
                .compactMap { PinyinSyllable(String($0)) }
            if !syllables.isEmpty { result[character] = syllables }
        }
        return result
    }

    /// pinyin-data 把「一、不」的语流变调也列为读音；变调不是字音，通韵判平仄时剔除。
    private static let sandhiReadings: [Character: Set<String>] = ["一": ["yí", "yì"], "不": ["bú"]]

    // MARK: - 查询

    /// 平水韵韵目序号。简体字会先映射到可能的繁体字再查表（如「听」查「聽」），一般不取简体字形本身的读音
    /// （「听」本身是罕用字 yǐn）；但若某个繁体候选在韵书中缺收，数据源可能以简体字形收录它
    /// （如「幷」作「并」，收于庚韵），此时字本身也查。
    public func pingshuiGroupIDs(of character: Character) -> [Int] {
        var ids: [Int] = []
        func append(_ candidate: Character) {
            for id in groupsByCharacter[candidate] ?? [] where !ids.contains(id) {
                ids.append(id)
            }
        }
        let candidates = converter.traditionalCandidates(character)
        candidates.forEach(append)
        if ids.isEmpty || candidates.contains(where: { groupsByCharacter[$0] == nil }) { append(character) }
        if ids.isEmpty {
            let simplified = converter.simplified(character)
            if simplified != character {
                converter.traditionalCandidates(simplified).forEach(append)
                // 繁体字本身缺收，数据源可能以简体字形收录（如「幷」作「并」）。
                append(simplified)
            }
        }
        if ids.isEmpty {
            converter.traditionalVariants(converter.simplified(character)).forEach(append)
        }
        if !supplementGroups.isEmpty {
            for id in supplementGroups[converter.simplified(character)] ?? [] where !ids.contains(id) {
                ids.append(id)
            }
        }
        return ids
    }

    public func syllables(of character: Character) -> [PinyinSyllable] {
        if let syllables = syllablesByCharacter[character] { return syllables }
        return syllablesByCharacter[converter.simplified(character)] ?? []
    }

    public func readings(of character: Character, in book: RhymeBook) -> [Reading] {
        var result: [Reading] = []
        func append(_ reading: Reading) {
            if !result.contains(reading) { result.append(reading) }
        }
        switch book {
        case .pingshui:
            for id in pingshuiGroupIDs(of: character) {
                append(Reading(tone: groups[id].tone, rhyme: RhymeKey(book: .pingshui, id: id)))
            }
        case .cilin:
            let finals = syllables(of: character).map(\.final)
            for id in pingshuiGroupIDs(of: character) {
                let group = groups[id]
                guard let section = CilinMapping.section(forGroupHead: group.headCharacter, finals: finals) else { continue }
                append(Reading(tone: group.tone, rhyme: RhymeKey(book: .cilin, id: section)))
            }
        case .tongyun:
            for syllable in syllables(of: character) {
                guard let tone = TongYun.tone(forPinyinTone: syllable.tone),
                      let id = TongYun.rhymeID(forFinal: syllable.final) else { continue }
                append(Reading(tone: tone, rhyme: RhymeKey(book: .tongyun, id: id)))
            }
        }
        return result
    }

    /// 平水韵读法对应的词林正韵读法（词林正韵由平水韵韵目归部）；不是平水韵读法或无法归部时为 nil。
    func cilinReading(of character: Character, fromPingshui reading: Reading) -> Reading? {
        guard reading.rhyme.book == .pingshui, groups.indices.contains(reading.rhyme.id) else { return nil }
        let finals = syllables(of: character).map(\.final)
        guard let section = CilinMapping.section(forGroupHead: groups[reading.rhyme.id].headCharacter, finals: finals) else { return nil }
        return Reading(tone: reading.tone, rhyme: RhymeKey(book: .cilin, id: section))
    }

    public func tones(of character: Character, in book: RhymeBook) -> Set<Tone> {
        Set(readings(of: character, in: book).map(\.tone))
    }

    /// 逐字平仄串：单读为平或仄，多音为「中」，未收录为「？」；非汉字忽略。
    public func tonePattern(of text: String, in book: RhymeBook) -> String {
        String(TextSegmenter.hanOnly(text).map { character -> Character in
            let tones = tones(of: character, in: book)
            guard tones.count == 1, let tone = tones.first else { return tones.isEmpty ? "？" : "中" }
            return Character(tone.rawValue)
        })
    }

    /// 给定声调下的韵部。
    public func rhymeKeys(of character: Character, in book: RhymeBook, tone: Tone) -> Set<RhymeKey> {
        Set(readings(of: character, in: book).filter { $0.tone == tone }.map(\.rhyme))
    }

    public func displayName(of key: RhymeKey) -> String {
        switch key.book {
        case .pingshui:
            guard groups.indices.contains(key.id) else { return "未知韵" }
            return groups[key.id].displayName
        case .cilin:
            return CilinMapping.name(of: key.id)
        case .tongyun:
            return TongYun.name(of: key.id)
        }
    }

    /// 某韵书全部韵部，按顺序。
    public func allKeys(in book: RhymeBook) -> [RhymeKey] {
        switch book {
        case .pingshui: groups.map { RhymeKey(book: .pingshui, id: $0.id) }
        case .cilin: (1...CilinMapping.sectionCount).map { RhymeKey(book: .cilin, id: $0) }
        case .tongyun: (1...TongYun.names.count).map { RhymeKey(book: .tongyun, id: $0) }
        }
    }

    /// 某韵部下的字（简体显示，去重），可限定声调。通韵以平水韵收录的常用字为范围，按今音归部。
    public func characters(in key: RhymeKey, tone: Tone? = nil) -> [Character] {
        var seen = Set<Character>()
        var result: [Character] = []
        func consider(_ character: Character) {
            let simplified = converter.simplified(character)
            guard !seen.contains(simplified) else { return }
            let matches = readings(of: simplified, in: key.book).contains { reading in
                reading.rhyme == key && (tone == nil || reading.tone == tone)
            }
            if matches {
                seen.insert(simplified)
                result.append(simplified)
            }
        }
        switch key.book {
        case .pingshui:
            guard groupCharacters.indices.contains(key.id) else { return [] }
            groupCharacters[key.id].forEach(consider)
        case .cilin:
            for group in groups where CilinMapping.possibleSections(forGroupHead: group.headCharacter).contains(key.id) {
                groupCharacters[group.id].forEach(consider)
            }
        case .tongyun:
            groupCharacters.joined().forEach(consider)
        }
        supplementGroups.keys.sorted().forEach(consider)
        return result
    }
}
