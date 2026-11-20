import Foundation

/// 可下载的典籍。文本来自漢リポ（Kanseki Repository）的四库全书本，许可为 CC BY-SA 4.0。
public enum ClassicWork: String, Sendable, Hashable, CaseIterable, Identifiable {
    case peiwenYunfu = "peiwen-yunfu"
    case yiwenLeiju = "yiwen-leiju"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .peiwenYunfu: "佩文韵府"
        case .yiwenLeiju: "艺文类聚"
        }
    }

    /// GitHub 上的仓库名。
    public var repository: String {
        switch self {
        case .peiwenYunfu: "kanripo/KR3k0059"
        case .yiwenLeiju: "kanripo/KR3k0003"
        }
    }

    /// 文本文件名前缀，例如 `KR3k0059_002.txt`。
    var filePrefix: String { String(repository.split(separator: "/").last ?? "") + "_" }

    public var archiveURL: URL? { URL(string: "https://codeload.github.com/\(repository)/zip/refs/heads/master") }
    public var sourceURL: String { "https://github.com/\(repository)" }
    public static let license = "CC BY-SA 4.0（漢リポ Kanseki Repository，四库全书文渊阁本）"

    public var summary: String {
        switch self {
        case .peiwenYunfu: "按平水韵排列的韵藻、对语、摘句，约 48 万条（下载约 35MB）"
        case .yiwenLeiju: "唐代类书，按部、子目收录典故与诗赋，约 1.1 万条（下载约 2MB）"
        }
    }
}

public struct ClassicInfo: Sendable, Hashable, Identifiable {
    public let work: ClassicWork
    public let entryCount: Int
    public let importedAt: Date
    public let format: Int

    public var id: String { work.rawValue }
    public var needsReindex: Bool { format < ClassicsIndex.format }
}

public enum ClassicsError: Error, Equatable, CustomStringConvertible {
    case noTextFiles(String)
    case noEntries(String)

    public var description: String {
        switch self {
        case .noTextFiles(let path): "目录中没有典籍文本：\(path)"
        case .noEntries(let name): "未能从《\(name)》文本中解析出任何条目"
        }
    }
}

/// 《艺文类聚》的子目。
public struct LeijuTopic: Sendable, Hashable, Identifiable {
    public let juan: Int
    public let part: String
    public let topic: String
    public let entryCount: Int

    public var id: String { "\(juan)|\(part)|\(topic)" }
}

/// 典籍索引（`classics.sqlite`），与语料索引分开存放。
///
/// 佩文韵府的注文只存原文，读出时再还原「丨」，以免同一注文存两份；
/// 简体归一的词条只为对语保存（按词查对时用），其余类别按韵字查询。
public actor ClassicsIndex {
    /// 索引格式版本；解析规则变化时递增，旧索引会在下次启动时重建。
    public static let format = 1

    private let database: SQLiteDatabase
    private let converter: ScriptConverter

    public init(url: URL, converter: ScriptConverter = CharDictionary.shared.converter) throws {
        self.database = try SQLiteDatabase(path: url.path)
        self.converter = converter
        try database.execute("""
        CREATE TABLE IF NOT EXISTS classics (
            id TEXT PRIMARY KEY, entry_count INTEGER NOT NULL, imported_at REAL NOT NULL, format INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS yunfu (
            id INTEGER PRIMARY KEY, group_id INTEGER NOT NULL, head TEXT NOT NULL, head_norm TEXT NOT NULL, kind INTEGER NOT NULL,
            phrase TEXT NOT NULL, len INTEGER NOT NULL, counterpart TEXT, phrase_norm TEXT, counterpart_norm TEXT,
            raw_note TEXT NOT NULL, juan TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS yunfu_head ON yunfu(head_norm, kind, len);
        CREATE INDEX IF NOT EXISTS yunfu_duiyu_phrase ON yunfu(phrase_norm) WHERE kind = \(YunfuEntryKind.duiyu.rawValue);
        CREATE INDEX IF NOT EXISTS yunfu_duiyu_counterpart ON yunfu(counterpart_norm) WHERE kind = \(YunfuEntryKind.duiyu.rawValue);
        CREATE TABLE IF NOT EXISTS leiju (
            id INTEGER PRIMARY KEY, juan INTEGER NOT NULL, part TEXT NOT NULL, topic TEXT NOT NULL, genre TEXT,
            text TEXT NOT NULL, norm TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS leiju_topic ON leiju(juan, part, topic);
        """)
    }

    // MARK: - 管理

    public func installed() throws -> [ClassicInfo] {
        try database.query("SELECT id, entry_count, imported_at, format FROM classics") { row in
            ClassicWork(rawValue: row.text(0)).map {
                ClassicInfo(work: $0, entryCount: row.int(1), importedAt: Date(timeIntervalSince1970: row.double(2)), format: row.int(3))
            }
        }.compactMap { $0 }.sorted { $0.work.rawValue < $1.work.rawValue }
    }

    public func delete(_ work: ClassicWork) throws {
        try database.transaction {
            try database.run("DELETE FROM \(ClassicsIndex.table(of: work))")
            try database.run("DELETE FROM classics WHERE id = ?", [.text(work.rawValue)])
        }
    }

    private static func table(of work: ClassicWork) -> String {
        switch work {
        case .peiwenYunfu: "yunfu"
        case .yiwenLeiju: "leiju"
        }
    }

    /// 目录中该典籍的文本文件，按卷序排列。
    static func textFiles(of work: ClassicWork, in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let files = contents.filter { $0.pathExtension == "txt" && $0.lastPathComponent.hasPrefix(work.filePrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { throw ClassicsError.noTextFiles(directory.path) }
        return files
    }

    /// 解析目录中的全部卷文件并重建该典籍的索引。返回条目数。
    @discardableResult
    public func importWork(_ work: ClassicWork, from directory: URL, groups: [PingshuiGroup],
                           progress: @Sendable (ImportProgress) -> Void = { _ in }) throws -> Int {
        let files = try ClassicsIndex.textFiles(of: work, in: directory)
        var count = 0
        try database.transaction {
            try database.run("DELETE FROM \(ClassicsIndex.table(of: work))")
            switch work {
            case .peiwenYunfu:
                let insert = try database.prepare("""
                    INSERT INTO yunfu (group_id, head, head_norm, kind, phrase, len, counterpart, phrase_norm, counterpart_norm, raw_note, juan)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                for (index, file) in files.enumerated() {
                    if index % 20 == 0 {
                        progress(ImportProgress(phase: "解析第 \(index + 1)/\(files.count) 卷", fraction: Double(index) / Double(files.count)))
                    }
                    for entry in PeiwenParser.parse(try String(contentsOf: file, encoding: .utf8), groups: groups).entries {
                        let isDuiyu = entry.kind == .duiyu
                        try insert.run([.int(entry.groupID), .text(entry.head), .text(converter.simplified(entry.head)),
                                        .int(entry.kind.rawValue), .text(entry.phrase), .int(TextSegmenter.hanOnly(entry.phrase).count),
                                        .optional(entry.counterpart),
                                        isDuiyu ? .text(converter.simplified(entry.phrase)) : .null,
                                        isDuiyu ? .optional(entry.counterpart.map(converter.simplified)) : .null,
                                        .text(entry.rawNote), .text(entry.juan)])
                        count += 1
                    }
                }
            case .yiwenLeiju:
                let insert = try database.prepare("INSERT INTO leiju (juan, part, topic, genre, text, norm) VALUES (?, ?, ?, ?, ?, ?)")
                for (index, file) in files.enumerated() {
                    progress(ImportProgress(phase: "解析第 \(index + 1)/\(files.count) 卷", fraction: Double(index) / Double(files.count)))
                    let juan = Int(file.deletingPathExtension().lastPathComponent.dropFirst(work.filePrefix.count)) ?? 0
                    for entry in LeijuParser.parse(try String(contentsOf: file, encoding: .utf8), juan: juan).entries {
                        try insert.run([.int(entry.juan), .text(entry.part), .text(entry.topic), .optional(entry.genre),
                                        .text(entry.text), .text(converter.simplified(entry.text))])
                        count += 1
                    }
                }
            }
            guard count > 0 else { throw ClassicsError.noEntries(work.name) }
            try database.run("INSERT OR REPLACE INTO classics (id, entry_count, imported_at, format) VALUES (?, ?, ?, ?)",
                             [.text(work.rawValue), .int(count), .real(Date().timeIntervalSince1970), .int(ClassicsIndex.format)])
        }
        progress(ImportProgress(phase: "完成", fraction: 1))
        return count
    }

    // MARK: - 佩文韵府

    private static let yunfuColumns = "group_id, head, kind, phrase, counterpart, raw_note, juan FROM yunfu"

    private func mapYunfu(_ row: SQLRow) -> YunfuEntry {
        let phrase = row.text(3)
        let rawNote = row.text(5)
        return YunfuEntry(groupID: row.int(0), head: row.text(1), kind: YunfuEntryKind(rawValue: row.int(2)) ?? .yunzao,
                          phrase: phrase, counterpart: row.optionalText(4), note: YunfuNote.expand(rawNote, phrase: phrase),
                          rawNote: rawNote, juan: row.text(6))
    }

    /// 某字作韵字的各条（繁简不拘），按原书顺序。
    public func yunfuEntries(head character: Character, kinds: Set<YunfuEntryKind> = Set(YunfuEntryKind.allCases),
                             limit: Int = 2_000) throws -> [YunfuEntry] {
        guard !kinds.isEmpty, limit > 0 else { return [] }
        let kindList = kinds.map { String($0.rawValue) }.sorted().joined(separator: ",")
        return try database.query("""
            SELECT \(ClassicsIndex.yunfuColumns) WHERE head_norm = ? AND kind IN (\(kindList)) ORDER BY id LIMIT ?
            """, [.text(String(converter.simplified(character))), .int(limit)], mapYunfu)
    }

    /// 以这些字为韵字、字数为 `length` 的韵藻（含「增」）与摘句，按原书顺序。
    public func yunzao(heads: [Character], length: Int, limit: Int = 5_000) throws -> [YunfuEntry] {
        let normalized = Array(Set(heads.map { String(converter.simplified($0)) })).sorted()
        guard !normalized.isEmpty, length > 0, limit > 0 else { return [] }
        let placeholders = Array(repeating: "?", count: normalized.count).joined(separator: ",")
        let kinds = [YunfuEntryKind.yunzao, .zeng, .zhaiju].map { String($0.rawValue) }.joined(separator: ",")
        return try database.query("""
            SELECT \(ClassicsIndex.yunfuColumns) WHERE head_norm IN (\(placeholders)) AND kind IN (\(kinds)) AND len = ?
            ORDER BY id LIMIT ?
            """, normalized.map(SQLValue.text) + [.int(length), .int(limit)], mapYunfu)
    }

    /// 对语中以 `text` 为一边的条目（繁简不拘）。
    public func duiyu(matching text: String, limit: Int = 200) throws -> [YunfuEntry] {
        let norm = converter.simplified(TextSegmenter.hanOnly(text))
        guard !norm.isEmpty else { return [] }
        // 分别走两个部分索引（条件须与建索引时的字面值一致）。
        let duiyu = YunfuEntryKind.duiyu.rawValue
        return try database.query("""
            SELECT \(ClassicsIndex.yunfuColumns) WHERE id IN (
                SELECT id FROM yunfu WHERE kind = \(duiyu) AND phrase_norm = ?
                UNION SELECT id FROM yunfu WHERE kind = \(duiyu) AND counterpart_norm = ?
            ) ORDER BY id LIMIT ?
            """, [.text(norm), .text(norm), .int(limit)], mapYunfu)
    }

    /// 全部对语（用作对仗训练题库），按原书顺序。
    public func allDuiyu() throws -> [YunfuEntry] {
        try database.query("SELECT \(ClassicsIndex.yunfuColumns) WHERE kind = ? AND counterpart IS NOT NULL ORDER BY id",
                           [.int(YunfuEntryKind.duiyu.rawValue)], mapYunfu)
    }

    // MARK: - 艺文类聚

    public func leijuTopics() throws -> [LeijuTopic] {
        try database.query("""
            SELECT juan, part, topic, COUNT(*), MIN(id) AS first FROM leiju GROUP BY juan, part, topic ORDER BY first
            """) { LeijuTopic(juan: $0.int(0), part: $0.text(1), topic: $0.text(2), entryCount: $0.int(3)) }
    }

    private func mapLeiju(_ row: SQLRow) -> LeijuEntry {
        LeijuEntry(juan: row.int(0), part: row.text(1), topic: row.text(2), genre: row.optionalText(3), text: row.text(4))
    }

    public func leijuEntries(in topic: LeijuTopic) throws -> [LeijuEntry] {
        try database.query("""
            SELECT juan, part, topic, genre, text FROM leiju WHERE juan = ? AND part = ? AND topic = ? ORDER BY id
            """, [.int(topic.juan), .text(topic.part), .text(topic.topic)], mapLeiju)
    }

    /// 全文检索（繁简不拘）。空白查询返回空。
    public func searchLeiju(_ query: String, limit: Int = 200) throws -> [LeijuEntry] {
        let norm = converter.simplified(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !norm.isEmpty, limit > 0 else { return [] }
        return try database.query("""
            SELECT juan, part, topic, genre, text FROM leiju WHERE instr(norm, ?) > 0 ORDER BY id LIMIT ?
            """, [.text(norm), .int(limit)], mapLeiju)
    }
}

public enum ClassicsDownloadError: Error, Equatable, CustomStringConvertible {
    case badURL
    case badStatus(Int)
    case extractionFailed(String)

    public var description: String {
        switch self {
        case .badURL: "典籍下载地址无效"
        case .badStatus(let status): "下载典籍失败（HTTP \(status)）"
        case .extractionFailed(let detail): "解压典籍失败：\(detail)"
        }
    }
}

public enum ClassicsDownloader {
    /// 下载 GitHub 仓库的 zip 并解压到 `directory/<id>/`，返回其中的文本目录。已解压过则直接返回。
    public static func download(_ work: ClassicWork, into directory: URL, session: URLSession = .shared) async throws -> URL {
        let destination = directory.appendingPathComponent(work.rawValue, isDirectory: true)
        if let existing = try? textDirectory(of: work, in: destination) { return existing }
        guard let url = work.archiveURL else { throw ClassicsDownloadError.badURL }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (temporary, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw ClassicsDownloadError.badStatus(status) }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try extract(zip: temporary, to: destination)
        return try textDirectory(of: work, in: destination)
    }

    /// 用系统自带的 ditto 解压。
    static func extract(zip: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, destination.path]
        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ClassicsDownloadError.extractionFailed(message.isEmpty ? "ditto 退出码 \(process.terminationStatus)" : message)
        }
    }

    /// 解压后的文本目录：zip 内通常有一层「仓库名-master」目录，也接受文本直接位于 `directory` 下。
    static func textDirectory(of work: ClassicWork, in directory: URL) throws -> URL {
        if (try? ClassicsIndex.textFiles(of: work, in: directory)) != nil { return directory }
        let children = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children.sorted(by: { $0.path < $1.path })
        where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if (try? ClassicsIndex.textFiles(of: work, in: child)) != nil { return child }
        }
        throw ClassicsError.noTextFiles(directory.path)
    }
}
