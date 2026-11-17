import Foundation

/// 替换候选。
public struct Candidate: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        case collection(UUID)
        case corpus
    }

    public let text: String
    public let source: Source
    public let frequency: Int
    public let tags: [String]

    public var id: String {
        switch source {
        case .collection(let id): "collection:\(id.uuidString)"
        case .corpus: "corpus:\(text)"
        }
    }
}

public struct CandidateOptions: Sendable {
    public var includeCollection: Bool
    public var includeCorpus: Bool
    /// 只作用于收藏候选。
    public var filter: PhraseFilter
    public var limit: Int
    /// 排除当前原文。
    public var excluding: String?

    public init(includeCollection: Bool = true, includeCorpus: Bool = true, filter: PhraseFilter = .all,
                limit: Int = 60, excluding: String? = nil) {
        self.includeCollection = includeCollection
        self.includeCorpus = includeCorpus
        self.filter = filter
        self.limit = limit
        self.excluding = excluding
    }
}

/// 新增收藏的输入。
public struct PhraseDraft: Sendable {
    public var text: String
    public var kind: PhraseKind?
    public var provenance: Provenance
    public var tags: [String]
    public var note: String?

    public init(text: String, kind: PhraseKind? = nil, provenance: Provenance = .original, tags: [String] = [], note: String? = nil) {
        self.text = text
        self.kind = kind
        self.provenance = provenance
        self.tags = tags
        self.note = note
    }
}

public struct AddPhraseResult: Sendable {
    public let phrase: Phrase
    /// 语料反查命中的出处（自撰时用于提示「与前人句相同」）。
    public let corpusMatch: SourceInfo?
}

public enum CustomReadingError: Error, Equatable, CustomStringConvertible {
    case notSingleCharacter(String)
    case invalidGroup(Int)
    case alreadyListed(character: Character, group: String)

    public var description: String {
        switch self {
        case .notSingleCharacter(let text): "请只输入一个汉字（收到「\(text)」）"
        case .invalidGroup(let id): "平水韵韵目序号无效：\(id)"
        case .alreadyListed(let character, let group): "「\(character)」已收于\(group)"
        }
    }
}

/// App 与 MCP 共用的业务入口。
public final class PoetryService {
    public let paths: AppPaths
    /// 内置词典加上用户补充读音；补充读音变动后更新。
    public private(set) var dictionary: CharDictionary
    public private(set) var analyzer: PoemAnalyzer
    private let baseDictionary: CharDictionary
    public let library: LibraryStore
    public let corpus: CorpusIndex

    public init(paths: AppPaths, dictionary: CharDictionary = .shared, tunes: CiTuneLibrary = .bundled) throws {
        try paths.createDirectories()
        self.paths = paths
        self.baseDictionary = dictionary
        self.dictionary = dictionary
        self.analyzer = PoemAnalyzer(dictionary: dictionary, tunes: tunes)
        self.library = try LibraryStore(url: paths.library)
        // 语料索引按内置读音建立，不随补充读音变化。
        self.corpus = try CorpusIndex(url: paths.corpus, dictionary: dictionary)
        try reloadCustomReadings()
    }

    // MARK: - 自定义读音

    /// 从用户库重新读入补充读音，更新词典与分析器。
    public func reloadCustomReadings() throws {
        dictionary = baseDictionary.supplemented(with: try library.customReadings())
        analyzer = PoemAnalyzer(dictionary: dictionary, tunes: analyzer.tunes)
    }

    /// 为一个字补充平水韵读音。`text` 首尾空白忽略，须恰为一个汉字；已收录的读音不重复添加。
    @discardableResult
    public func addCustomReading(_ text: String, groupID: Int) throws -> CustomReading {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let character = trimmed.first, TextSegmenter.isHan(character) else {
            throw CustomReadingError.notSingleCharacter(text)
        }
        guard dictionary.groups.indices.contains(groupID) else { throw CustomReadingError.invalidGroup(groupID) }
        guard !dictionary.pingshuiGroupIDs(of: character).contains(groupID) else {
            throw CustomReadingError.alreadyListed(character: character, group: dictionary.groups[groupID].displayName)
        }
        let reading = CustomReading(character: character, groupID: groupID)
        try library.save(reading)
        try reloadCustomReadings()
        return reading
    }

    public func removeCustomReading(_ reading: CustomReading) throws {
        try library.deleteCustomReading(reading)
        try reloadCustomReadings()
    }

    public func analyze(_ text: String, form: FormSelection, book: RhymeBook, choices: [ReadingChoice] = []) -> PoemAnalysis {
        analyzer.analyze(text, form: form, book: book, choices: choices)
    }

    // MARK: - 候选

    public func collectionCandidates(for constraint: SlotConstraint, filter: PhraseFilter = .all, excluding: String? = nil) throws -> [Candidate] {
        let excluded = excluding.map { dictionary.converter.simplified(TextSegmenter.hanOnly($0)) }
        return try library.phrases()
            .filter { $0.status == .accepted && filter.matches($0) && constraint.accepts($0.hanText, dictionary: dictionary) }
            .filter { dictionary.converter.simplified($0.hanText) != excluded }
            .map { Candidate(text: $0.hanText, source: .collection($0.id), frequency: 0, tags: $0.tagPaths) }
    }

    /// 收藏在前、语料在后；语料中与收藏重复的文本只保留收藏。
    nonisolated(nonsending) public func candidates(for constraint: SlotConstraint, options: CandidateOptions = CandidateOptions()) async throws -> [Candidate] {
        var result: [Candidate] = []
        if options.includeCollection {
            result = try collectionCandidates(for: constraint, filter: options.filter, excluding: options.excluding)
        }
        guard options.includeCorpus else { return Array(result.prefix(options.limit)) }
        let excluded = options.excluding.map { dictionary.converter.simplified(TextSegmenter.hanOnly($0)) }
        let known = Set(result.map { dictionary.converter.simplified($0.text) })
        let corpusRows = try await corpus.candidates(for: constraint, limit: options.limit + known.count + 1)
        for row in corpusRows where !known.contains(row.text) && row.text != excluded {
            result.append(Candidate(text: row.text, source: .corpus, frequency: row.frequency, tags: []))
        }
        return Array(result.prefix(options.limit))
    }

    // MARK: - 收藏

    /// 新增收藏：推断类型、语料反查出处、按设置决定 agent 写入是否进收件箱。
    @discardableResult
    nonisolated(nonsending) public func addPhrase(_ draft: PhraseDraft, actor: TagActor = .user) async throws -> AddPhraseResult {
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let inferred = PhraseKind.infer(from: text) else { throw LibraryError.emptyText }
        var provenance = draft.provenance
        let match = try await corpus.findSource(of: text)
        if let match, provenance.kind != .original {
            var verified = match
            verified.url = provenance.source?.url ?? provenance.claimedSource?.url
            provenance.source = verified
        }
        if provenance.kind == .excerpt, match == nil, var source = provenance.source {
            source.isVerified = false
            provenance.source = source
        }
        let tagActor: TagActor = actor == .agent ? .agent : .user
        var tags: [TagAssignment] = []
        for raw in draft.tags {
            guard let path = TagPath.normalize(raw) else { throw LibraryError.invalidTag(raw) }
            if !tags.contains(where: { $0.path == path }) { tags.append(TagAssignment(path: path, addedBy: tagActor)) }
        }
        let agentGoesToInbox = try library.bool(.agentWritesToInbox)
        let status: ReviewStatus = (actor == .agent && agentGoesToInbox) ? .inbox : .accepted
        let note = draft.note?.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = Phrase(text: text, kind: draft.kind ?? inferred, provenance: provenance, tags: tags, status: status,
                            note: (note?.isEmpty ?? true) ? nil : note)
        try library.save(phrase)
        return AddPhraseResult(phrase: phrase, corpusMatch: match)
    }

    /// 给收藏追加标签（不移除已有标签）。
    public func addTags(_ rawTags: [String], to id: UUID, actor: TagActor) throws -> Phrase {
        guard var phrase = try library.phrase(id: id) else { throw LibraryError.notFound("收藏 \(id.uuidString)") }
        for raw in rawTags {
            guard let path = TagPath.normalize(raw) else { throw LibraryError.invalidTag(raw) }
            if !phrase.tags.contains(where: { $0.path == path }) { phrase.tags.append(TagAssignment(path: path, addedBy: actor)) }
        }
        phrase.updatedAt = Date()
        try library.save(phrase)
        return phrase
    }

    public func searchPhrases(_ query: String, includeInbox: Bool = false) throws -> [Phrase] {
        let filter = try PhraseFilterParser.parse(query)
        return try library.phrases().filter { (includeInbox || $0.status == .accepted) && filter.matches($0) }
    }

    // MARK: - 语料包

    /// 已放入 Packs 目录、但尚未导入（或版本变化、索引格式过旧）的语料包。
    nonisolated(nonsending) public func pendingPackDirectories() async throws -> [URL] {
        let packs = try await corpus.packs()
        let installed = Dictionary(uniqueKeysWithValues: packs.map { ($0.id, $0.version) })
        let outdated = Set(packs.filter(\.needsReindex).map(\.id))
        let contents = try FileManager.default.contentsOfDirectory(at: paths.packs, includingPropertiesForKeys: [.isDirectoryKey])
        var pending: [URL] = []
        for directory in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            let manifest = try PackManifest.load(from: directory)
            if installed[manifest.id] == nil || installed[manifest.id] != manifest.version || outdated.contains(manifest.id) {
                pending.append(directory)
            }
        }
        return pending
    }

    /// 把外部语料包复制进 Packs 目录并导入。
    nonisolated(nonsending) public func installPack(from source: URL, progress: @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportReport {
        let manifest = try PackManifest.load(from: source)
        let destination = paths.packs.appendingPathComponent(manifest.id, isDirectory: true)
        if source.standardizedFileURL != destination.standardizedFileURL {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
        }
        return try await corpus.importPack(at: destination, progress: progress)
    }

    /// 删除语料包：移除索引与 Packs 目录中的文件。
    nonisolated(nonsending) public func removePack(id: String) async throws {
        try await corpus.deletePack(id: id)
        let directory = paths.packs.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
