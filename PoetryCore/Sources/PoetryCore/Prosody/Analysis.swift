import Foundation

public enum Severity: Int, Sendable, Hashable, Comparable, Codable {
    case hint = 0
    case warning = 1
    case error = 2

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    public var displayName: String {
        switch self {
        case .hint: "提示"
        case .warning: "警告"
        case .error: "错误"
        }
    }
}

public enum IssueKind: String, Sendable, Hashable, Codable {
    case toneMismatch = "平仄不合"
    case guPing = "孤平"
    case guPingRescued = "孤平拗救"
    case sanPingWei = "三平尾"
    case sanZeWei = "三仄尾"
    case aoUnrescued = "拗而未救"
    case aoRescued = "拗救"
    case xiaoAo = "小拗"
    case teAo = "特拗"
    case shiNian = "失粘"
    case shiDui = "失对"
    case chuYun = "出韵"
    case neighborRhyme = "首句借邻韵"
    case repeatedRhyme = "重韵"
    case repeatedCharacter = "重字"
    case polyphonic = "多音字"
    case unknownCharacter = "未收录字"
    case lineCount = "句数不符"
    case lineLength = "字数不符"
    case unrecognizedForm = "未识别体裁"
}

/// 字在分析结果中的坐标（第几句、第几字，从 0 起）。
public struct CharPosition: Sendable, Hashable, Codable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct Issue: Sendable, Hashable, Identifiable {
    public let severity: Severity
    public let kind: IssueKind
    public let message: String
    public let positions: [CharPosition]

    public var id: String { "\(kind.rawValue)|\(message)" }

    public init(_ severity: Severity, _ kind: IssueKind, _ message: String, positions: [CharPosition] = []) {
        self.severity = severity
        self.kind = kind
        self.message = message
        self.positions = positions
    }
}

public enum SlotStatus: String, Sendable, Hashable {
    /// 合律。
    case ok
    /// 多音字，按可通处理。
    case ambiguous
    /// 可平可仄的位置，虽与正格不同但不算错。
    case flexible
    /// 属拗救或特定格式，可用。
    case rescued
    /// 不合律。
    case mismatch
    /// 韵书未收录此字。
    case unknown
    /// 无模板（未识别体裁）。
    case unconstrained
}

public struct AnalyzedChar: Sendable, Hashable {
    public let character: Character
    public let offset: Int
    public let tones: Set<Tone>
    /// 模板要求；nil 表示没有模板。
    public let expected: ToneSlot?
    public internal(set) var status: SlotStatus
    /// 韵脚所属的押韵组（近体诗只有 "A"；词可能换韵）。
    public internal(set) var rhymeGroup: String?
    /// 用户指定的读音（仅在当前韵书中有效时）；nil 表示按韵书全部读音自动判断。
    public internal(set) var chosenReading: Reading? = nil
}

public struct AnalyzedLine: Sendable, Hashable {
    public internal(set) var characters: [AnalyzedChar]
    /// 模板在此句中的句型描述，例如「仄仄平平仄」。
    public let patternText: String?
    /// 词谱中的分段（上片为 0）。
    public let stanza: Int

    public var text: String { String(characters.map(\.character)) }
}

public struct PoemAnalysis: Sendable {
    public let book: RhymeBook
    public let formName: String
    public let variantName: String?
    public internal(set) var lines: [AnalyzedLine]
    public internal(set) var issues: [Issue]
    /// 各押韵组选定的韵部。
    public internal(set) var rhymeKeys: [String: RhymeKey]
    /// 用于判断押韵组韵部的韵书（词用平水韵时按词林正韵部判断）。
    public let rhymeBookForKeys: RhymeBook

    public static func empty(book: RhymeBook) -> PoemAnalysis {
        PoemAnalysis(book: book, formName: "空", variantName: nil, lines: [], issues: [], rhymeKeys: [:], rhymeBookForKeys: book)
    }

    public var errorCount: Int { issues.filter { $0.severity == .error }.count }
    public var warningCount: Int { issues.filter { $0.severity == .warning }.count }

    var score: Int {
        issues.reduce(0) { total, issue in
            switch issue.severity {
            case .error: total + 10
            case .warning: total + 3
            case .hint: total + (issue.kind == .polyphonic || issue.kind == .unknownCharacter ? 0 : 1)
            }
        }
    }

    public func character(at position: CharPosition) -> AnalyzedChar? {
        guard lines.indices.contains(position.line),
              lines[position.line].characters.indices.contains(position.column) else { return nil }
        return lines[position.line].characters[position.column]
    }
}
