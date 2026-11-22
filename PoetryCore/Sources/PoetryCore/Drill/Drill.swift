import Foundation

/// 对仗训练的两种模式。
public enum DrillMode: String, Sendable, Hashable, CaseIterable, Identifiable, Codable {
    /// 对词：四字以内。
    case word
    /// 对句：五字以上，含长对。
    case line

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .word: "对词"
        case .line: "对句"
        }
    }

    /// 按字数（只计汉字）归类：四字以内为词，五字以上为句。
    public init(length: Int) {
        self = length <= 4 ? .word : .line
    }
}

/// 题库来源。
public enum DrillSourceKind: String, Sendable, Hashable, CaseIterable, Identifiable {
    case shengLv
    case liweng
    case yunfu
    case corpus

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .shengLv: "声律启蒙"
        case .liweng: "笠翁对韵"
        case .yunfu: "佩文对语"
        case .corpus: "律诗"
        }
    }
}

/// 题库中一组对仗的出处。
public enum DrillItemSource: Sendable, Hashable {
    /// 对韵蒙书第几节。
    case primer(PrimerWork, sectionIndex: Int)
    /// 佩文韵府对语，记韵字与韵目。
    case yunfu(head: String, groupID: Int)
    /// 语料中的一联，`lineIndex` 为出句在作品中的序号。
    case corpus(workID: Int64, lineIndex: Int)

    public var kind: DrillSourceKind {
        switch self {
        case .primer(.shengLvQiMeng, _): .shengLv
        case .primer(.liwengDuiyun, _): .liweng
        case .yunfu: .yunfu
        case .corpus: .corpus
        }
    }

    /// 出自语料时为作品 id（可查看全文），否则为 nil。
    public var corpusWorkID: Int64? {
        if case .corpus(let workID, _) = self { return workID }
        return nil
    }

    /// 出自佩文韵府对语时为韵字（可查看韵府），否则为 nil。
    public var yunfuHead: String? {
        if case .yunfu(let head, _) = self { return head }
        return nil
    }
}

/// 题库中的一组对仗（两边字数相同）。
public struct DrillItem: Sendable, Hashable {
    public let left: String
    public let right: String
    public let source: DrillItemSource

    public init(left: String, right: String, source: DrillItemSource) {
        self.left = left
        self.right = right
        self.source = source
    }
}

/// 抽出的一道题：`prompt` 为出，`reference` 为原书（原诗）的另一边。
public struct DrillQuestion: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let mode: DrillMode
    public let prompt: String
    public let reference: String
    public let source: DrillItemSource
    /// 题目标识：模式与出题汉字的简体，不分来源。
    public let key: String
}

/// 按字数筛选。
public enum DrillLength: Sendable, Hashable {
    case any
    case exactly(Int)
    /// 八字以上的长对。
    case long

    func accepts(_ length: Int) -> Bool {
        switch self {
        case .any: true
        case .exactly(let value): length == value
        case .long: length >= 8
        }
    }
}

/// 按练习记录筛选。
public enum DrillHistoryFilter: String, Sendable, Hashable, CaseIterable, Identifiable {
    case all
    case unanswered
    case answered

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .all: "全部"
        case .unanswered: "只出新题"
        case .answered: "只出答过的"
        }
    }
}

public struct DrillOptions: Sendable, Hashable {
    public var mode: DrillMode
    public var sources: Set<DrillSourceKind>
    public var length: DrillLength
    public var history: DrillHistoryFilter

    public init(mode: DrillMode, sources: Set<DrillSourceKind> = Set(DrillSourceKind.allCases),
                length: DrillLength = .any, history: DrillHistoryFilter = .all) {
        self.mode = mode
        self.sources = sources
        self.length = length
        self.history = history
    }
}

/// 一题的另一边（原书或原诗）。
public struct DrillReference: Sendable, Hashable {
    public let counterpart: String
    public let source: DrillItemSource
}

/// 题库：各组对仗预先算好两边的题目标识，供随机抽题与查参考答案。
public struct DrillPool: Sendable {
    struct Entry: Sendable {
        let item: DrillItem
        let mode: DrillMode
        let length: Int
        let leftKey: String
        let rightKey: String
    }

    let entries: [Entry]
    private let converter: ScriptConverter

    /// 两边汉字数不同、为空或繁简归一后相同的组合不入题库。
    public init(items: [DrillItem], converter: ScriptConverter) {
        self.converter = converter
        entries = items.compactMap { item in
            let left = converter.simplified(TextSegmenter.hanOnly(item.left))
            let right = converter.simplified(TextSegmenter.hanOnly(item.right))
            guard !left.isEmpty, left.count == right.count, left != right else { return nil }
            let mode = DrillMode(length: left.count)
            return Entry(item: item, mode: mode, length: left.count,
                         leftKey: DrillPool.key(mode: mode, normalized: left), rightKey: DrillPool.key(mode: mode, normalized: right))
        }
    }

    public var count: Int { entries.count }

    /// 某来源的组数；给出 `mode` 时只计该模式。
    public func count(of kind: DrillSourceKind, mode: DrillMode? = nil) -> Int {
        entries.filter { $0.item.source.kind == kind && (mode == nil || $0.mode == mode) }.count
    }

    private static func key(mode: DrillMode, normalized: String) -> String {
        "\(mode.rawValue)|\(normalized)"
    }

    /// 题目标识：模式由字数决定，出题只取汉字并转为简体。没有汉字时为 nil。
    public static func key(for prompt: String, converter: ScriptConverter) -> String? {
        let normalized = converter.simplified(TextSegmenter.hanOnly(prompt))
        guard !normalized.isEmpty else { return nil }
        return key(mode: DrillMode(length: normalized.count), normalized: normalized)
    }

    /// 随机抽一题：对词两边都可作出题，对句只以出句出题；按选项与练习记录筛选后等概率抽取。没有符合条件的题时为 nil。
    public func draw(_ options: DrillOptions, answeredKeys: Set<String>,
                     using generator: inout some RandomNumberGenerator) -> DrillQuestion? {
        func eligible(_ key: String) -> Bool {
            switch options.history {
            case .all: true
            case .unanswered: !answeredKeys.contains(key)
            case .answered: answeredKeys.contains(key)
            }
        }
        var candidates: [(entry: Entry, leftIsPrompt: Bool)] = []
        for entry in entries where entry.mode == options.mode && options.sources.contains(entry.item.source.kind)
            && options.length.accepts(entry.length) {
            if eligible(entry.leftKey) { candidates.append((entry, true)) }
            if entry.mode == .word, eligible(entry.rightKey) { candidates.append((entry, false)) }
        }
        guard let chosen = candidates.randomElement(using: &generator) else { return nil }
        let item = chosen.entry.item
        return DrillQuestion(id: UUID(), mode: chosen.entry.mode,
                             prompt: chosen.leftIsPrompt ? item.left : item.right,
                             reference: chosen.leftIsPrompt ? item.right : item.left,
                             source: item.source,
                             key: chosen.leftIsPrompt ? chosen.entry.leftKey : chosen.entry.rightKey)
    }

    /// 题库中与 `prompt` 相对的各边（繁简不拘），同一对文字只取第一个出处。
    public func references(for prompt: String) -> [DrillReference] {
        guard let key = DrillPool.key(for: prompt, converter: converter) else { return [] }
        var seen = Set<String>()
        var result: [DrillReference] = []
        for entry in entries {
            let counterpart: String
            if entry.leftKey == key {
                counterpart = entry.item.right
            } else if entry.rightKey == key {
                counterpart = entry.item.left
            } else {
                continue
            }
            if seen.insert(converter.simplified(TextSegmenter.hanOnly(counterpart))).inserted {
                result.append(DrillReference(counterpart: counterpart, source: entry.item.source))
            }
        }
        return result
    }
}

/// 一次作答的记录。
public struct DrillAttempt: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let mode: DrillMode
    public let questionKey: String
    public let prompt: String
    public let answer: String
    public let level: CoupletScore.Level
    /// 题目出处的说明，例如「声律启蒙·一、東」「杜甫《登高》」。
    public let source: String
    public let createdAt: Date

    public init(id: UUID = UUID(), mode: DrillMode, questionKey: String, prompt: String, answer: String,
                level: CoupletScore.Level, source: String, createdAt: Date = Date()) {
        self.id = id
        self.mode = mode
        self.questionKey = questionKey
        self.prompt = prompt
        self.answer = answer
        self.level = level
        self.source = source
        self.createdAt = createdAt
    }
}
