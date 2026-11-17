import Foundation

/// 平水韵的五个声部。
public enum PingshuiSection: Int, Sendable, Hashable, CaseIterable {
    case shangPing = 0
    case xiaPing
    case shang
    case qu
    case ru

    public var tone: Tone { (self == .shangPing || self == .xiaPing) ? .ping : .ze }

    public var displayName: String {
        switch self {
        case .shangPing: "上平"
        case .xiaPing: "下平"
        case .shang: "上声"
        case .qu: "去声"
        case .ru: "入声"
        }
    }

    /// 数据中使用的繁体前缀。
    var sourcePrefix: String {
        switch self {
        case .shangPing: "上平聲"
        case .xiaPing: "下平聲"
        case .shang: "上聲"
        case .qu: "去聲"
        case .ru: "入聲"
        }
    }
}

/// 平水韵的一个韵目，例如「上平·一东」。
public struct PingshuiGroup: Sendable, Hashable, Identifiable {
    public let id: Int
    public let section: PingshuiSection
    public let number: Int
    public let numeral: String
    /// 韵目代表字（繁体，与数据源一致）。
    public let headCharacter: Character
    /// 韵目代表字（简体，用于显示）。
    public let headSimplified: Character

    public var tone: Tone { section.tone }
    public var displayName: String { "\(section.displayName)·\(numeral)\(headSimplified)" }
}

/// 平水韵韵目标题解析，例如「上平聲十三元」→ (上平, 13, "十三", 元)。
enum PingshuiTitleParser {
    struct Parsed: Equatable {
        let section: PingshuiSection
        let number: Int
        let numeral: String
        let head: Character
    }

    static func parse(_ title: String) -> Parsed? {
        guard let section = PingshuiSection.allCases.first(where: { title.hasPrefix($0.sourcePrefix) }) else {
            return nil
        }
        let rest = title.dropFirst(section.sourcePrefix.count)
        guard rest.count >= 2, let head = rest.last else { return nil }
        let numeral = String(rest.dropLast())
        guard let number = parseChineseNumeral(numeral) else { return nil }
        return Parsed(section: section, number: number, numeral: numeral, head: head)
    }

    private static let digits: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5,
                                                   "六": 6, "七": 7, "八": 8, "九": 9]

    /// 解析 1...99 的中文数字。
    static func parseChineseNumeral(_ text: String) -> Int? {
        let characters = Array(text)
        switch characters.count {
        case 1:
            if characters[0] == "十" { return 10 }
            return digits[characters[0]]
        case 2:
            if characters[0] == "十" { return digits[characters[1]].map { 10 + $0 } }
            if characters[1] == "十" { return digits[characters[0]].map { $0 * 10 } }
            return nil
        case 3:
            guard characters[1] == "十", let tens = digits[characters[0]], let ones = digits[characters[2]] else {
                return nil
            }
            return tens * 10 + ones
        default:
            return nil
        }
    }
}

/// 词林正韵十九部与平水韵韵目的对应关系。
///
/// 词林正韵大体由平水韵归并而来（入声独立为五部），但「佳、卦、灰、贿、队、泰、元、阮、愿」
/// 等韵目分属两部。这里按今音韵母近似划分：这是启发式规则，个别字可能与《词林正韵》原书不符。
public enum CilinMapping {
    public static let sectionCount = 19

    private static let fixed: [Character: Int] = [
        // 平声
        "東": 1, "冬": 1, "江": 2, "支": 3, "微": 3, "魚": 4, "虞": 4, "齊": 3,
        "真": 6, "文": 6, "寒": 7, "刪": 7, "先": 7, "蕭": 8, "肴": 8, "豪": 8,
        "歌": 9, "麻": 10, "陽": 2, "庚": 11, "青": 11, "蒸": 11, "尤": 12, "侵": 13,
        "覃": 14, "鹽": 14, "咸": 14,
        // 上声
        "董": 1, "腫": 1, "講": 2, "紙": 3, "尾": 3, "語": 4, "麌": 4, "薺": 3, "蟹": 5,
        "軫": 6, "吻": 6, "旱": 7, "潸": 7, "銑": 7, "篠": 8, "巧": 8, "皓": 8, "哿": 9,
        "馬": 10, "養": 2, "梗": 11, "迥": 11, "有": 12, "寢": 13, "感": 14, "琰": 14, "豏": 14,
        // 去声
        "送": 1, "宋": 1, "絳": 2, "寘": 3, "未": 3, "御": 4, "遇": 4, "霽": 3,
        "震": 6, "問": 6, "翰": 7, "諫": 7, "霰": 7, "嘯": 8, "效": 8, "號": 8, "箇": 9,
        "禡": 10, "漾": 2, "敬": 11, "徑": 11, "宥": 12, "沁": 13, "勘": 14, "豔": 14, "陷": 14,
        // 入声
        "屋": 15, "沃": 15, "覺": 16, "藥": 16, "質": 17, "陌": 17, "錫": 17, "職": 17, "緝": 17,
        "物": 18, "月": 18, "曷": 18, "黠": 18, "屑": 18, "葉": 18, "合": 19, "洽": 19,
    ]

    private struct Split {
        let finals: Set<String>
        let matched: Int
        let otherwise: Int
    }

    private static let aFinals: Set<String> = ["a", "ia", "ua"]
    private static let aiFinals: Set<String> = ["ai", "uai"]
    private static let anFinals: Set<String> = ["an", "ian", "uan", "üan"]

    private static let splits: [Character: Split] = [
        "佳": Split(finals: aFinals, matched: 10, otherwise: 5),
        "卦": Split(finals: aFinals, matched: 10, otherwise: 5),
        "灰": Split(finals: aiFinals, matched: 5, otherwise: 3),
        "賄": Split(finals: aiFinals, matched: 5, otherwise: 3),
        "隊": Split(finals: aiFinals, matched: 5, otherwise: 3),
        "泰": Split(finals: aiFinals, matched: 5, otherwise: 3),
        "元": Split(finals: anFinals, matched: 7, otherwise: 6),
        "阮": Split(finals: anFinals, matched: 7, otherwise: 6),
        "願": Split(finals: anFinals, matched: 7, otherwise: 6),
    ]

    /// 某平水韵韵目中的字归入词林正韵的哪一部。`finals` 为该字的今音韵母（用于拆分韵目）。
    public static func section(forGroupHead head: Character, finals: [String]) -> Int? {
        if let section = fixed[head] { return section }
        guard let split = splits[head] else { return nil }
        return finals.contains(where: split.finals.contains) ? split.matched : split.otherwise
    }

    /// 某平水韵韵目可能对应的词林部（拆分韵目返回两部）。
    public static func possibleSections(forGroupHead head: Character) -> [Int] {
        if let section = fixed[head] { return [section] }
        guard let split = splits[head] else { return [] }
        return [split.matched, split.otherwise]
    }

    private static let numerals = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十",
                                   "十一", "十二", "十三", "十四", "十五", "十六", "十七", "十八", "十九"]

    public static func name(of section: Int) -> String {
        guard (1...sectionCount).contains(section) else { return "未知部" }
        return "第\(numerals[section - 1])部"
    }
}
