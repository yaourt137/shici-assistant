import Foundation

public enum PhraseKind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case character = "字"
    case word = "词"
    case line = "句"
    case couplet = "联"

    public var id: String { rawValue }

    /// 依文本推断：两句以上为联，一字为字，二至四字为词，其余为句。
    public static func infer(from text: String) -> PhraseKind? {
        let segments = TextSegmenter.segments(of: text)
        let count = segments.reduce(0) { $0 + $1.count }
        guard count > 0 else { return nil }
        if segments.count >= 2 { return .couplet }
        if count == 1 { return .character }
        if count <= 4 { return .word }
        return .line
    }
}

public enum ProvenanceKind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case original = "自撰"
    case excerpt = "摘录"
    case agent = "agent"

    public var id: String { rawValue }
}

public struct SourceInfo: Sendable, Hashable, Codable {
    public var author: String?
    public var title: String?
    public var dynasty: String?
    public var url: String?
    /// 是否经语料反查确认。
    public var isVerified: Bool

    public init(author: String? = nil, title: String? = nil, dynasty: String? = nil, url: String? = nil, isVerified: Bool = false) {
        self.author = author
        self.title = title
        self.dynasty = dynasty
        self.url = url
        self.isVerified = isVerified
    }

    public var isEmpty: Bool {
        [author, title, dynasty, url].allSatisfy { ($0 ?? "").isEmpty }
    }

    public var summary: String {
        var parts: [String] = []
        if let dynasty, !dynasty.isEmpty { parts.append("〔\(dynasty)〕") }
        if let author, !author.isEmpty { parts.append(author) }
        if let title, !title.isEmpty { parts.append("《\(title)》") }
        return parts.joined()
    }
}

/// 收藏关联的语料作品：以全文哈希定位（重新导入或换了语料包，只要有同一首就能找到），附显示用的出处与诗句。
public struct CorpusWorkLink: Sendable, Hashable, Codable {
    public var textHash: Int64
    /// 出处说明，例如「〔唐〕王维《山居秋暝》」。
    public var summary: String
    /// 相关的诗句（原书字形），可空。
    public var excerpt: String?

    public init(textHash: Int64, summary: String, excerpt: String? = nil) {
        self.textHash = textHash
        self.summary = summary
        self.excerpt = excerpt
    }
}

public struct Provenance: Sendable, Hashable, Codable {
    public var kind: ProvenanceKind
    /// 正式出处（摘录时填写，或经语料反查确认）。
    public var source: SourceInfo?
    /// 自撰时关联的草稿。
    public var draftID: UUID?
    /// agent 写入时的客户端名称与说明。
    public var agentClient: String?
    public var agentNote: String?
    /// agent 声称的出处，未经核实。
    public var claimedSource: SourceInfo?
    /// 到原诗的链接（可多首）；旧数据没有此项。
    public var corpusLinks: [CorpusWorkLink]?

    public init(kind: ProvenanceKind, source: SourceInfo? = nil, draftID: UUID? = nil,
                agentClient: String? = nil, agentNote: String? = nil, claimedSource: SourceInfo? = nil,
                corpusLinks: [CorpusWorkLink]? = nil) {
        self.kind = kind
        self.source = source
        self.draftID = draftID
        self.agentClient = agentClient
        self.agentNote = agentNote
        self.claimedSource = claimedSource
        self.corpusLinks = corpusLinks
    }

    public static let original = Provenance(kind: .original)
}

public enum ReviewStatus: String, Sendable, Hashable, Codable {
    case inbox
    case accepted

    public var displayName: String { self == .inbox ? "收件箱" : "已入库" }
}

public enum TagActor: String, Sendable, Hashable, Codable {
    case system
    case user
    case agent
}

public struct TagAssignment: Sendable, Hashable, Codable {
    public let path: String
    public let addedBy: TagActor

    public init(path: String, addedBy: TagActor) {
        self.path = path
        self.addedBy = addedBy
    }
}

public struct Phrase: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var text: String
    public var kind: PhraseKind
    public var provenance: Provenance
    public var tags: [TagAssignment]
    public var status: ReviewStatus
    public var note: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), text: String, kind: PhraseKind, provenance: Provenance, tags: [TagAssignment] = [],
                status: ReviewStatus = .accepted, note: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.kind = kind
        self.provenance = provenance
        self.tags = tags
        self.status = status
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 只含汉字的文本，用于格律匹配。
    public var hanText: String { TextSegmenter.hanOnly(text) }
    public var tagPaths: [String] { tags.map(\.path) }
}

public struct Poem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    /// 修改正文时，因删改或移位而失效的读音指定随之作废。
    public var body: String {
        didSet { readingChoices = ReadingChoice.retained(readingChoices, from: oldValue, to: body) }
    }
    public var form: FormSelection
    public var book: RhymeBook
    /// 用户为多音字指定的读音。
    public var readingChoices: [ReadingChoice]
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String = "", body: String = "", form: FormSelection = .automatic,
                book: RhymeBook = .pingshui, readingChoices: [ReadingChoice] = [],
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.body = body
        self.form = form
        self.book = book
        self.readingChoices = readingChoices
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let firstLine = TextSegmenter.segments(of: body).first.map { String($0.map(\.character)) }
        return firstLine ?? "无题"
    }
}

/// 用户补充的平水韵读音（数据源漏收的又读）。词林正韵随之换算；中华通韵依今音，不受影响。
public struct CustomReading: Sendable, Hashable, Identifiable {
    public let character: Character
    /// 平水韵韵目序号（0...105，即 `PingshuiGroup.id`）。
    public let groupID: Int
    public let createdAt: Date

    public init(character: Character, groupID: Int, createdAt: Date = Date()) {
        self.character = character
        self.groupID = groupID
        self.createdAt = createdAt
    }

    public var id: String { "\(character)|\(groupID)" }
}

public struct SmartCollection: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public var query: String

    public init(id: UUID = UUID(), name: String, query: String) {
        self.id = id
        self.name = name
        self.query = query
    }
}
