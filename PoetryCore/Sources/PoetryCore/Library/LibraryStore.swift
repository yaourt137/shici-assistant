import Foundation

public enum LibraryError: Error, Equatable, CustomStringConvertible {
    case emptyText
    case invalidTag(String)
    case notFound(String)

    public var description: String {
        switch self {
        case .emptyText: "文本中没有汉字"
        case .invalidTag(let raw): "标签无效：「\(raw)」"
        case .notFound(let what): "未找到：\(what)"
        }
    }
}

/// 用户库：作品、收藏、标签、智能收藏夹与设置。
public final class LibraryStore {
    private let database: SQLiteDatabase

    public init(url: URL) throws {
        database = try SQLiteDatabase(path: url.path)
        try migrate()
    }

    private func migrate() throws {
        try database.execute("""
        CREATE TABLE IF NOT EXISTS phrases (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL,
            kind TEXT NOT NULL,
            provenance TEXT NOT NULL,
            status TEXT NOT NULL,
            note TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS tags (path TEXT PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS phrase_tags (
            phrase_id TEXT NOT NULL REFERENCES phrases(id) ON DELETE CASCADE,
            path TEXT NOT NULL REFERENCES tags(path) ON DELETE CASCADE ON UPDATE CASCADE,
            added_by TEXT NOT NULL,
            PRIMARY KEY (phrase_id, path)
        );
        CREATE INDEX IF NOT EXISTS phrase_tags_path ON phrase_tags(path);
        CREATE TABLE IF NOT EXISTS poems (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            body TEXT NOT NULL,
            form TEXT NOT NULL,
            book TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS smart_collections (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            query TEXT NOT NULL,
            position INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS custom_readings (
            character TEXT NOT NULL,
            group_id INTEGER NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY (character, group_id)
        );
        """)
        // 读音指定为后加的列，旧库需补上。
        let poemColumns = try database.query("PRAGMA table_info(poems)") { $0.text(1) }
        if !poemColumns.contains("reading_choices") {
            try database.execute("ALTER TABLE poems ADD COLUMN reading_choices TEXT NOT NULL DEFAULT '[]'")
        }
    }

    // MARK: - 收藏

    public func phrases() throws -> [Phrase] {
        var tagsByPhrase: [String: [TagAssignment]] = [:]
        let tagRows = try database.query("SELECT phrase_id, path, added_by FROM phrase_tags ORDER BY path") { row in
            (row.text(0), TagAssignment(path: row.text(1), addedBy: TagActor(rawValue: row.text(2)) ?? .user))
        }
        for (id, assignment) in tagRows { tagsByPhrase[id, default: []].append(assignment) }
        let decoder = JSONDecoder()
        return try database.query("""
            SELECT id, text, kind, provenance, status, note, created_at, updated_at FROM phrases ORDER BY created_at DESC
            """) { row in
            let id = row.text(0)
            guard let uuid = UUID(uuidString: id) else { throw LibraryError.notFound("收藏 id \(id) 格式错误") }
            return Phrase(
                id: uuid,
                text: row.text(1),
                kind: PhraseKind(rawValue: row.text(2)) ?? .line,
                provenance: try decoder.decode(Provenance.self, from: Data(row.text(3).utf8)),
                tags: tagsByPhrase[id] ?? [],
                status: ReviewStatus(rawValue: row.text(4)) ?? .accepted,
                note: row.optionalText(5),
                createdAt: Date(timeIntervalSince1970: row.double(6)),
                updatedAt: Date(timeIntervalSince1970: row.double(7))
            )
        }
    }

    public func phrase(id: UUID) throws -> Phrase? {
        try phrases().first { $0.id == id }
    }

    /// 插入或更新收藏（含标签）。
    public func save(_ phrase: Phrase) throws {
        guard !phrase.hanText.isEmpty else { throw LibraryError.emptyText }
        let provenance = String(decoding: try JSONEncoder().encode(phrase.provenance), as: UTF8.self)
        try database.transaction {
            try database.run("""
                INSERT INTO phrases (id, text, kind, provenance, status, note, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET text = excluded.text, kind = excluded.kind, provenance = excluded.provenance,
                    status = excluded.status, note = excluded.note, updated_at = excluded.updated_at
                """, [.text(phrase.id.uuidString), .text(phrase.text), .text(phrase.kind.rawValue), .text(provenance),
                      .text(phrase.status.rawValue), .optional(phrase.note),
                      .real(phrase.createdAt.timeIntervalSince1970), .real(phrase.updatedAt.timeIntervalSince1970)])
            try database.run("DELETE FROM phrase_tags WHERE phrase_id = ?", [.text(phrase.id.uuidString)])
            for assignment in phrase.tags {
                guard let path = TagPath.normalize(assignment.path) else { throw LibraryError.invalidTag(assignment.path) }
                try insertTag(path)
                try database.run("INSERT OR IGNORE INTO phrase_tags (phrase_id, path, added_by) VALUES (?, ?, ?)",
                                 [.text(phrase.id.uuidString), .text(path), .text(assignment.addedBy.rawValue)])
            }
        }
    }

    public func deletePhrase(id: UUID) throws {
        try database.run("DELETE FROM phrases WHERE id = ?", [.text(id.uuidString)])
    }

    public func setStatus(_ status: ReviewStatus, for ids: [UUID]) throws {
        try database.transaction {
            for id in ids {
                try database.run("UPDATE phrases SET status = ?, updated_at = ? WHERE id = ?",
                                 [.text(status.rawValue), .real(Date().timeIntervalSince1970), .text(id.uuidString)])
            }
        }
    }

    // MARK: - 标签

    private func insertTag(_ path: String) throws {
        for ancestor in TagPath.lineage(of: path) {
            try database.run("INSERT OR IGNORE INTO tags (path) VALUES (?)", [.text(ancestor)])
        }
    }

    /// 全部标签路径（含上级），按路径排序。
    public func tags() throws -> [String] {
        try database.query("SELECT path FROM tags ORDER BY path") { $0.text(0) }
    }

    /// 各标签直接挂载的收藏数。
    public func tagUsage() throws -> [String: Int] {
        let rows = try database.query("SELECT path, COUNT(*) FROM phrase_tags GROUP BY path") { ($0.text(0), $0.int(1)) }
        return Dictionary(rows, uniquingKeysWith: +)
    }

    public func createTag(_ raw: String) throws -> String {
        guard let path = TagPath.normalize(raw) else { throw LibraryError.invalidTag(raw) }
        try insertTag(path)
        return path
    }

    /// 重命名（或移动）标签，连同其下级一起改名；目标已存在时合并。
    public func renameTag(_ old: String, to raw: String) throws {
        guard let new = TagPath.normalize(raw) else { throw LibraryError.invalidTag(raw) }
        guard new != old else { return }
        guard !new.hasPrefix(old + "/") else { throw LibraryError.invalidTag("不能移动到自身下级：\(raw)") }
        try database.transaction {
            let affected = try database.query("SELECT path FROM tags WHERE path = ? OR path LIKE ? ESCAPE '\\'",
                                               [.text(old), .text(likePrefix(old))]) { $0.text(0) }
            guard !affected.isEmpty else { throw LibraryError.notFound("标签「\(old)」") }
            for path in affected {
                guard let target = TagPath.renamed(path, from: old, to: new) else { continue }
                try insertTag(target)
                try database.run("""
                    INSERT OR IGNORE INTO phrase_tags (phrase_id, path, added_by)
                    SELECT phrase_id, ?, added_by FROM phrase_tags WHERE path = ?
                    """, [.text(target), .text(path)])
                try database.run("DELETE FROM tags WHERE path = ?", [.text(path)])
            }
        }
    }

    /// 删除标签及其下级（收藏本身保留）。
    public func deleteTag(_ path: String) throws {
        try database.run("DELETE FROM tags WHERE path = ? OR path LIKE ? ESCAPE '\\'", [.text(path), .text(likePrefix(path))])
    }

    private func likePrefix(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "/%"
    }

    // MARK: - 作品

    public func poems() throws -> [Poem] {
        let decoder = JSONDecoder()
        return try database.query("""
            SELECT id, title, body, form, book, created_at, updated_at, reading_choices FROM poems ORDER BY updated_at DESC
            """) { row in
            guard let id = UUID(uuidString: row.text(0)) else { throw LibraryError.notFound("作品 id 格式错误") }
            return Poem(id: id, title: row.text(1), body: row.text(2),
                        form: FormSelection(storageValue: row.text(3)) ?? .automatic,
                        book: RhymeBook(rawValue: row.text(4)) ?? .pingshui,
                        readingChoices: try decoder.decode([ReadingChoice].self, from: Data(row.text(7).utf8)),
                        createdAt: Date(timeIntervalSince1970: row.double(5)),
                        updatedAt: Date(timeIntervalSince1970: row.double(6)))
        }
    }

    public func save(_ poem: Poem) throws {
        let choices = String(decoding: try JSONEncoder().encode(poem.readingChoices), as: UTF8.self)
        try database.run("""
            INSERT INTO poems (id, title, body, form, book, created_at, updated_at, reading_choices) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET title = excluded.title, body = excluded.body, form = excluded.form,
                book = excluded.book, updated_at = excluded.updated_at, reading_choices = excluded.reading_choices
            """, [.text(poem.id.uuidString), .text(poem.title), .text(poem.body), .text(poem.form.storageValue),
                  .text(poem.book.rawValue), .real(poem.createdAt.timeIntervalSince1970), .real(poem.updatedAt.timeIntervalSince1970),
                  .text(choices)])
    }

    public func deletePoem(id: UUID) throws {
        try database.run("DELETE FROM poems WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - 智能收藏夹

    public func smartCollections() throws -> [SmartCollection] {
        try database.query("SELECT id, name, query FROM smart_collections ORDER BY position, name") { row in
            guard let id = UUID(uuidString: row.text(0)) else { throw LibraryError.notFound("收藏夹 id 格式错误") }
            return SmartCollection(id: id, name: row.text(1), query: row.text(2))
        }
    }

    /// 保存前校验表达式，避免存入无法解析的条件。
    public func save(_ collection: SmartCollection) throws {
        _ = try PhraseFilterParser.parse(collection.query)
        try database.run("""
            INSERT INTO smart_collections (id, name, query) VALUES (?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, query = excluded.query
            """, [.text(collection.id.uuidString), .text(collection.name), .text(collection.query)])
    }

    public func deleteSmartCollection(id: UUID) throws {
        try database.run("DELETE FROM smart_collections WHERE id = ?", [.text(id.uuidString)])
    }

    // MARK: - 自定义读音

    public func customReadings() throws -> [CustomReading] {
        try database.query("SELECT character, group_id, created_at FROM custom_readings ORDER BY created_at, character") { row in
            let text = row.text(0)
            guard text.count == 1, let character = text.first else { throw LibraryError.notFound("自定义读音的字格式错误：「\(text)」") }
            return CustomReading(character: character, groupID: row.int(1), createdAt: Date(timeIntervalSince1970: row.double(2)))
        }
    }

    /// 已有同字同韵目者保持不变。
    public func save(_ reading: CustomReading) throws {
        try database.run("INSERT OR IGNORE INTO custom_readings (character, group_id, created_at) VALUES (?, ?, ?)",
                         [.text(String(reading.character)), .int(reading.groupID), .real(reading.createdAt.timeIntervalSince1970)])
    }

    public func deleteCustomReading(_ reading: CustomReading) throws {
        try database.run("DELETE FROM custom_readings WHERE character = ? AND group_id = ?",
                         [.text(String(reading.character)), .int(reading.groupID)])
    }

    // MARK: - 设置

    public func setting(_ key: String) throws -> String? {
        try database.query("SELECT value FROM settings WHERE key = ?", [.text(key)]) { $0.text(0) }.first
    }

    public func setSetting(_ key: String, _ value: String) throws {
        try database.run("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                         [.text(key), .text(value)])
    }

    public func bool(_ key: SettingKey) throws -> Bool {
        guard let value = try setting(key.rawValue) else { return key.defaultValue }
        return value == "1"
    }

    public func setBool(_ key: SettingKey, _ value: Bool) throws {
        try setSetting(key.rawValue, value ? "1" : "0")
    }
}

/// 布尔设置项（App 与 shici-mcp 共享）。
public enum SettingKey: String, Sendable, CaseIterable {
    /// agent 写入的收藏先进收件箱。
    case agentWritesToInbox = "agent.inbox"
    /// MCP 只读模式：禁止 agent 写入。
    case mcpReadOnly = "mcp.readonly"

    public var defaultValue: Bool {
        switch self {
        case .agentWritesToInbox: true
        case .mcpReadOnly: false
        }
    }
}
