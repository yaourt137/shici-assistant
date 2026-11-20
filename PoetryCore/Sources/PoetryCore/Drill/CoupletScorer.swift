import Foundation

/// 一对字或一对双字词（无序，按字典序存放），用于对仗统计。
public struct PairKey: Sendable, Hashable {
    public let first: String
    public let second: String

    public init(_ lhs: String, _ rhs: String) {
        if lhs <= rhs {
            first = lhs
            second = rhs
        } else {
            first = rhs
            second = lhs
        }
    }
}

/// 数目、颜色、方位、干支：同类相对即为工对。
public enum WordCategory: String, Sendable, Hashable, CaseIterable {
    case number = "数目"
    case color = "颜色"
    case direction = "方位"
    case stemBranch = "干支"

    private var characters: Set<Character> {
        switch self {
        case .number: Set("一二三四五六七八九十百千万亿两双半孤独几")
        case .color: Set("红黄青白黑紫绿碧翠朱丹素玄苍赤金银粉乌皓缟黛蓝")
        case .direction: Set("东西南北上下左右前后中内外里边")
        case .stemBranch: Set("甲乙丙丁戊己庚辛壬癸子丑寅卯辰巳午未申酉戌亥")
        }
    }

    /// `character` 须为简体。
    public static func of(_ character: Character) -> WordCategory? {
        allCases.first { $0.characters.contains(character) }
    }
}

public enum CoupletScoreError: Error, Equatable, CustomStringConvertible {
    case emptyPrompt
    case emptyAnswer

    public var description: String {
        switch self {
        case .emptyPrompt: "出题中没有汉字"
        case .emptyAnswer: "对句中没有汉字"
        }
    }
}

/// 对仗评分结果。
public struct CoupletScore: Sendable, Hashable {
    public enum Level: Int, Sendable, Hashable, Comparable, CaseIterable, Identifiable {
        case fail = 0
        case loose
        case fair
        case strict

        public var id: Int { rawValue }

        public var displayName: String {
            switch self {
            case .fail: "失"
            case .loose: "宽"
            case .fair: "可"
            case .strict: "工"
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum ToneRelation: Sendable, Hashable {
        case opposed
        case same
        /// 至少一边韵书未收。
        case unknown
    }

    /// 同位两字在律诗对仗联中相对的程度。
    public enum Affinity: Int, Sendable, Hashable, Comparable {
        case unseen = 0
        case seen
        case common

        public var displayName: String {
            switch self {
            case .unseen: "未见"
            case .seen: "见过"
            case .common: "常对"
            }
        }

        public static func < (lhs: Affinity, rhs: Affinity) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// 同一位置的两字。
    public struct Position: Sendable, Hashable {
        public let promptCharacter: Character
        public let answerCharacter: Character
        public let promptTones: Set<Tone>
        public let answerTones: Set<Tone>
        public let tone: ToneRelation
        /// 要求平仄相对的位置（词的偶数位与末字、律句由律对判定、长对的各分句末字）。
        public let isKeyPosition: Bool
        public let affinity: Affinity
        /// 两字在律诗对仗联同位出现的次数。
        public let pairCount: Int
        /// 同类相对（数目、颜色、方位、干支、叠字）。
        public let category: String?
    }

    public let mode: DrillMode
    public let level: Level
    public let positions: [Position]
    /// 定档的理由，按重要性排列。
    public let reasons: [String]
    /// 五七言对句的律对判定；对词与长对为 nil。
    public let meter: CoupletRelation?
    /// 与典籍或原诗一致时的出处说明。
    public let knownSource: String?
}

/// 对仗评分：先查硬性条件（字数、重字、末字平仄），再看要位平仄与同位字的对仗度。
///
/// 对仗度依据语料中律诗中间各联逐字对齐的统计；词性与句法结构无法判断，结果只作参考。
public enum CoupletScorer {
    /// 对仗度的次数门槛，随对仗联总数按比例换算（语料越多，偶然同位的次数也越多）。
    public struct Thresholds: Sendable, Equatable {
        /// 同位两字相对达到此次数即为「常对」。
        public let common: Int
        /// 同位双字词相对达到此次数，两字都算「常对」。
        public let commonWordPair: Int
        /// 达到此次数才算「见过」。
        public let seen: Int

        public init(common: Int, commonWordPair: Int, seen: Int) {
            self.common = common
            self.commonWordPair = commonWordPair
            self.seen = seen
        }

        /// 约 6.4 万联（唐诗）时校准的门槛，也是语料较少时的下限。
        public static let baseline = Thresholds(common: 3, commonWordPair: 2, seen: 1)

        /// 按对仗联总数换算：每约 2.1 万联常对加一次、每约 3.2 万联双字词常对加一次、每 25 万联见过加一次，不低于基准。
        public static func scaled(coupletCount: Int) -> Thresholds {
            let count = max(coupletCount, 0)
            return Thresholds(common: max(baseline.common, count / 21_000),
                              commonWordPair: max(baseline.commonWordPair, count / 32_000),
                              seen: max(baseline.seen, count / 250_000))
        }
    }

    /// 评分所需的统计键：各位置的字对，与各相邻两字的词对（简体）。字数不同时为空。
    public static func lookupKeys(prompt: String, answer: String, converter: ScriptConverter) -> [PairKey] {
        let left = Array(converter.simplified(TextSegmenter.hanOnly(prompt)))
        let right = Array(converter.simplified(TextSegmenter.hanOnly(answer)))
        guard !left.isEmpty, left.count == right.count else { return [] }
        var keys = left.indices.map { PairKey(String(left[$0]), String(right[$0])) }
        for index in left.indices.dropLast() {
            keys.append(PairKey(String(left[index...index + 1]), String(right[index...index + 1])))
        }
        return keys
    }

    /// - Parameters:
    ///   - pairCounts: `lookupKeys` 各键在律诗对仗联中的次数（缺省为 0）。
    ///   - knownSource: 对句与典籍或原诗一致时的出处。
    ///   - thresholds: 对仗度的次数门槛，见 `Thresholds.scaled(coupletCount:)`。
    public static func score(prompt: String, answer: String, dictionary: CharDictionary,
                             pairCounts: [PairKey: Int], knownSource: String? = nil,
                             thresholds: Thresholds = .baseline) throws -> CoupletScore {
        let promptText = TextSegmenter.hanOnly(prompt)
        let answerText = TextSegmenter.hanOnly(answer)
        guard !promptText.isEmpty else { throw CoupletScoreError.emptyPrompt }
        guard !answerText.isEmpty else { throw CoupletScoreError.emptyAnswer }
        let mode = DrillMode(length: promptText.count)
        guard promptText.count == answerText.count else {
            return CoupletScore(mode: mode, level: .fail, positions: [],
                                reasons: ["字数不同：出 \(promptText.count) 字，对 \(answerText.count) 字"], meter: nil, knownSource: nil)
        }

        let converter = dictionary.converter
        let left = Array(promptText)
        let right = Array(answerText)
        let simpleLeft = left.map(converter.simplified)
        let simpleRight = right.map(converter.simplified)
        let count = left.count
        let leftTones = left.map { dictionary.tones(of: $0, in: .pingshui) }
        let rightTones = right.map { dictionary.tones(of: $0, in: .pingshui) }

        var failures: [String] = []
        var notes: [String] = []

        let shared = simpleLeft.filter { Set(simpleRight).contains($0) }
        if !shared.isEmpty {
            let unique = shared.reduce(into: [Character]()) { if !$0.contains($1) { $0.append($1) } }
            failures.append("出对重字：" + unique.map { "「\($0)」" }.joined(separator: "、"))
        }

        // 叠字须对叠字。
        var reduplicated = Set<Int>()
        for index in 1..<max(count, 1) {
            let leftDouble = simpleLeft[index] == simpleLeft[index - 1]
            let rightDouble = simpleRight[index] == simpleRight[index - 1]
            if leftDouble, rightDouble {
                reduplicated.formUnion([index - 1, index])
            } else if leftDouble != rightDouble {
                notes.append("第 \(index)、\(index + 1) 字叠字不相对")
            }
        }

        var boosted = Set<Int>()
        for index in 0..<(count - 1) {
            let key = PairKey(String(simpleLeft[index...index + 1]), String(simpleRight[index...index + 1]))
            if (pairCounts[key] ?? 0) >= thresholds.commonWordPair { boosted.formUnion([index, index + 1]) }
        }

        let keyPositions = CoupletScorer.keyPositions(prompt: prompt, length: count)
        let analyzedMeter: CoupletRelation? = (count == 5 || count == 7) && mode == .line
            ? MeterAnalyzer.analyze([leftTones, rightTones]).couplets.first?.relation : nil

        let positions = (0..<count).map { index -> CoupletScore.Position in
            let tone: CoupletScore.ToneRelation
            if leftTones[index].isEmpty || rightTones[index].isEmpty {
                tone = .unknown
            } else if leftTones[index].contains(where: { rightTones[index].contains($0.opposite) }) {
                tone = .opposed
            } else {
                tone = .same
            }
            let pairCount = pairCounts[PairKey(String(simpleLeft[index]), String(simpleRight[index]))] ?? 0
            var category: String?
            if reduplicated.contains(index) {
                category = "叠字"
            } else if let kind = WordCategory.of(simpleLeft[index]), kind == WordCategory.of(simpleRight[index]) {
                category = kind.rawValue
            }
            let affinity: CoupletScore.Affinity
            if category != nil || pairCount >= thresholds.common || boosted.contains(index) {
                affinity = .common
            } else {
                affinity = pairCount >= thresholds.seen ? .seen : .unseen
            }
            return CoupletScore.Position(promptCharacter: left[index], answerCharacter: right[index],
                                         promptTones: leftTones[index], answerTones: rightTones[index], tone: tone,
                                         isKeyPosition: keyPositions.contains(index), affinity: affinity,
                                         pairCount: pairCount, category: category)
        }

        if let last = positions.last, last.tone == .same {
            failures.append("末字平仄不相对：「\(last.promptCharacter)」「\(last.answerCharacter)」同为\(toneName(last.promptTones))")
        }

        // 末字已另作硬性检查，这里只列其余要位。
        let toneMisses = positions.indices.dropLast().filter { positions[$0].isKeyPosition && positions[$0].tone == .same }
        let lastToneFails = positions.last?.tone == .same
        // 律对判定只看第二字；末字平仄不相对时不算律对（末字已另报原因，不再重复说明）。
        let meter = analyzedMeter == .opposed && lastToneFails ? .notOpposed : analyzedMeter
        let toneIsStrict: Bool
        if let meter {
            toneIsStrict = meter == .opposed
            if meter != .opposed, !lastToneFails {
                let answerStatus = MeterAnalyzer.analyze([rightTones]).lines.first
                notes.append(answerStatus?.meter == nil ? "不成律对：对句不是律句" : "不成律对：两句平仄不相对")
            }
        } else {
            toneIsStrict = toneMisses.isEmpty && !lastToneFails
            if !toneMisses.isEmpty {
                notes.append("要位平仄不相对：第 " + toneMisses.map { String($0 + 1) }.joined(separator: "、") + " 字")
            }
        }
        if positions.contains(where: { $0.tone == .unknown }) {
            notes.append("有字韵书未收，平仄未判")
        }
        let unseen = positions.indices.filter { positions[$0].affinity == .unseen }
        if !unseen.isEmpty {
            notes.append("律诗对仗中未见：" + unseen.map { "「\(simpleLeft[$0])—\(simpleRight[$0])」" }.joined(separator: "、"))
        }

        let level: CoupletScore.Level
        var reasons = failures
        if !failures.isEmpty {
            level = .fail
            reasons += notes
        } else if let knownSource {
            level = toneIsStrict ? .strict : .fair
            reasons = ["见于\(knownSource)"] + notes
        } else {
            let seenOrBetter = positions.filter { $0.affinity >= .seen }.count
            let commonCount = positions.filter { $0.affinity == .common }.count
            // 对词须字字常对；对句字多、统计稀疏（末字多为韵脚，尤其分散），容许一字不是常对。
            let isClose = mode == .word ? commonCount == count : commonCount >= count - 1
            let reduplicationMismatch = notes.contains { $0.contains("叠字不相对") }
            if toneIsStrict, isClose, !reduplicationMismatch {
                level = .strict
                reasons = [mode == .word ? "要位平仄相对，各字皆为常对或同类相对" : "成律对，至多一字不是常对"] + notes
            } else if seenOrBetter * 2 >= count, meter == nil || meter == .opposed {
                level = .fair
                reasons = notes.isEmpty ? ["平仄相对，多数字在律诗对仗中见过"] : notes
            } else {
                level = .loose
                reasons = notes.isEmpty ? ["对仗度不足"] : notes
            }
        }
        return CoupletScore(mode: mode, level: level, positions: positions, reasons: reasons, meter: meter,
                            knownSource: knownSource)
    }

    /// 要求平仄相对的位置（从 0 计）：长对为各分句末字；其余为偶数位（第二、四……字）与末字。
    static func keyPositions(prompt: String, length: Int) -> Set<Int> {
        guard length > 0 else { return [] }
        if length >= 8 {
            let clauses = prompt.split(whereSeparator: { $0 == "，" || $0 == "；" || $0 == "," })
                .map { TextSegmenter.hanOnly(String($0)).count }
                .filter { $0 > 0 }
            if clauses.count > 1, clauses.reduce(0, +) == length {
                var ends = Set<Int>()
                var offset = 0
                for clause in clauses {
                    offset += clause
                    ends.insert(offset - 1)
                }
                return ends
            }
        }
        var result = Set(stride(from: 1, to: length, by: 2))
        result.insert(length - 1)
        return result
    }

    private static func toneName(_ tones: Set<Tone>) -> String {
        tones.count == 1 ? (tones.first == .ping ? "平声" : "仄声") : "平仄两读"
    }
}
