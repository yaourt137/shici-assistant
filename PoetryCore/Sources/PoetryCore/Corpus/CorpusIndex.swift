import Foundation

public struct PackInfo: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let version: String?
    public let era: String?
    public let license: String?
    public let source: String?
    public let isEnabled: Bool
    public let workCount: Int
    public let lineCount: Int
    public let importedAt: Date
    /// 导入时使用的索引格式；低于 `CorpusIndex.indexFormat` 时需要重新导入。
    public let indexFormat: Int
    /// 重复作品保留哪一份：数值小的优先。
    public let priority: Int
    /// 与优先的语料包重复、因而隐藏的作品数。
    public let duplicateCount: Int

    public var needsReindex: Bool { indexFormat < CorpusIndex.indexFormat }
}

public struct ImportProgress: Sendable {
    public let phase: String
    public let fraction: Double
}

public struct ImportReport: Sendable {
    public let packID: String
    public let name: String
    public let workCount: Int
    public let lineCount: Int
    public let gramCount: Int
    public let skippedRecords: Int
    public let errors: [String]
    /// 与优先的语料包重复、因而隐藏的作品数。
    public let duplicateCount: Int
}

/// 语料中的一句（以简体归一显示）。
public struct CorpusLine: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let text: String
    public let workID: Int64
    public let lineIndex: Int
    public let title: String?
    public let author: String?
    public let dynasty: String?
    public let packName: String

    public var sourceSummary: String {
        SourceInfo(author: author, title: title, dynasty: dynasty).summary
    }
}

public struct CorpusWork: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let title: String?
    public let author: String?
    public let dynasty: String?
    public let preface: String?
    public let body: String
    public let packName: String
}

public struct CorpusCandidate: Sendable, Hashable {
    public let text: String
    public let frequency: Int
}

/// 语料索引：作品、句、n-gram 片段（替换候选）与 FTS5 双字索引（用例与相关诗句）；
/// 另有对仗联统计（`parallel_*` 表，见 ParallelCouplets.swift），按需由已启用的语料包重建；
/// 以及跨语料包的重复作品（`work_pairs`、`works.duplicate_of`，见 CorpusDuplicates.swift），查询时只用每组中优先的一份。
public actor CorpusIndex {
    let database: SQLiteDatabase
    let dictionary: CharDictionary

    /// 只给出现次数达到阈值的片段建候选索引，用于过滤一次性的噪音片段（大语料包）。
    static let largePackWorkCount = 5_000
    static let gramLengths = 2...4
    /// 索引格式版本。2：切句前逐段去掉括号内的校注；3：改为整篇剥离，处理跨段的校注；
    /// 4：字典补回「先」的平声、「并」的庚韵后，按新读音重建平仄索引。
    public static let indexFormat = 4

    public init(url: URL, dictionary: CharDictionary = .shared) throws {
        self.database = try SQLiteDatabase(path: url.path)
        self.dictionary = dictionary
        try database.execute("""
        CREATE TABLE IF NOT EXISTS packs (
            id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT, era TEXT, script TEXT, license TEXT, source TEXT,
            enabled INTEGER NOT NULL DEFAULT 1, work_count INTEGER NOT NULL, line_count INTEGER NOT NULL, imported_at REAL NOT NULL,
            index_format INTEGER NOT NULL DEFAULT 1, priority INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS works (
            id INTEGER PRIMARY KEY, pack_id TEXT NOT NULL, ext_id TEXT, title TEXT, author TEXT, dynasty TEXT,
            form TEXT, tune TEXT, preface TEXT, body TEXT NOT NULL, text_hash INTEGER, duplicate_of INTEGER
        );
        CREATE INDEX IF NOT EXISTS works_pack ON works(pack_id);
        CREATE TABLE IF NOT EXISTS lines (
            id INTEGER PRIMARY KEY, pack_id TEXT NOT NULL, work_id INTEGER NOT NULL, idx INTEGER NOT NULL,
            norm TEXT NOT NULL, len INTEGER NOT NULL,
            gu_ping INTEGER NOT NULL, gu_ze INTEGER NOT NULL, jin_ping INTEGER NOT NULL, jin_ze INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS lines_norm ON lines(norm);
        CREATE INDEX IF NOT EXISTS lines_len ON lines(len);
        CREATE INDEX IF NOT EXISTS lines_work ON lines(work_id, idx);
        CREATE TABLE IF NOT EXISTS grams (
            pack_id TEXT NOT NULL, text TEXT NOT NULL, len INTEGER NOT NULL, freq INTEGER NOT NULL, aligned INTEGER NOT NULL,
            gu_ping INTEGER NOT NULL, gu_ze INTEGER NOT NULL, jin_ping INTEGER NOT NULL, jin_ze INTEGER NOT NULL,
            PRIMARY KEY (len, pack_id, text)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS char_freq (
            pack_id TEXT NOT NULL, ch TEXT NOT NULL, freq INTEGER NOT NULL, PRIMARY KEY (pack_id, ch)
        ) WITHOUT ROWID;
        CREATE VIRTUAL TABLE IF NOT EXISTS line_fts USING fts5(tokens, content='', contentless_delete=1);
        CREATE TABLE IF NOT EXISTS parallel_lines (
            id INTEGER PRIMARY KEY, work_id INTEGER NOT NULL, idx INTEGER NOT NULL, left TEXT NOT NULL, right TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS parallel_pairs (
            a TEXT NOT NULL, b TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY (a, b)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS parallel_pairs_b ON parallel_pairs(b);
        CREATE TABLE IF NOT EXISTS parallel_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS work_pairs (
            a INTEGER NOT NULL, b INTEGER NOT NULL, a_pack TEXT NOT NULL, b_pack TEXT NOT NULL, PRIMARY KEY (a, b)
        ) WITHOUT ROWID;
        CREATE INDEX IF NOT EXISTS work_pairs_a_pack ON work_pairs(a_pack);
        CREATE INDEX IF NOT EXISTS work_pairs_b_pack ON work_pairs(b_pack);
        CREATE TABLE IF NOT EXISTS dup_grams (
            len INTEGER NOT NULL, text TEXT NOT NULL, freq INTEGER NOT NULL, aligned INTEGER NOT NULL, PRIMARY KEY (len, text)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS dup_chars (ch TEXT PRIMARY KEY, freq INTEGER NOT NULL) WITHOUT ROWID;
        """)
        // 旧版数据库没有 index_format 列：补上，已有语料包按格式 1 处理（需重新导入）。
        let packColumns = try database.query("PRAGMA table_info(packs)") { $0.text(1) }
        if !packColumns.contains("index_format") {
            try database.execute("ALTER TABLE packs ADD COLUMN index_format INTEGER NOT NULL DEFAULT 1")
        }
        // 去重所需的列：旧库补上；已有作品的全文哈希在下次导入时补算。
        if !packColumns.contains("priority") {
            try database.execute("ALTER TABLE packs ADD COLUMN priority INTEGER NOT NULL DEFAULT 0")
        }
        let workColumns = try database.query("PRAGMA table_info(works)") { $0.text(1) }
        if !workColumns.contains("text_hash") {
            try database.execute("ALTER TABLE works ADD COLUMN text_hash INTEGER")
        }
        if !workColumns.contains("duplicate_of") {
            try database.execute("ALTER TABLE works ADD COLUMN duplicate_of INTEGER")
        }
        try database.execute("""
            CREATE INDEX IF NOT EXISTS works_text_hash ON works(text_hash);
            CREATE INDEX IF NOT EXISTS works_duplicate ON works(duplicate_of) WHERE duplicate_of IS NOT NULL;
            """)
    }

    // MARK: - 语料包管理

    public func packs() throws -> [PackInfo] {
        try database.query("""
            SELECT p.id, p.name, p.version, p.era, p.license, p.source, p.enabled, p.work_count, p.line_count, p.imported_at,
                p.index_format, p.priority, COALESCE(d.n, 0)
            FROM packs p LEFT JOIN (
                SELECT pack_id, COUNT(*) AS n FROM works WHERE duplicate_of IS NOT NULL GROUP BY pack_id
            ) d ON d.pack_id = p.id
            ORDER BY p.imported_at
            """) { row in
            PackInfo(id: row.text(0), name: row.text(1), version: row.optionalText(2), era: row.optionalText(3),
                     license: row.optionalText(4), source: row.optionalText(5), isEnabled: row.int(6) == 1,
                     workCount: row.int(7), lineCount: row.int(8), importedAt: Date(timeIntervalSince1970: row.double(9)),
                     indexFormat: row.int(10), priority: row.int(11), duplicateCount: row.int(12))
        }
    }

    /// 启用或停用语料包；重复作品随之重新取舍。
    public func setEnabled(_ enabled: Bool, packID: String) throws {
        try database.run("UPDATE packs SET enabled = ? WHERE id = ?", [.int(enabled ? 1 : 0), .text(packID)])
        try resolveDuplicates()
    }

    public func deletePack(id: String) throws {
        try database.transaction { try removePackData(id) }
        try resolveDuplicates()
    }

    private func removePackData(_ id: String) throws {
        try database.run("DELETE FROM line_fts WHERE rowid IN (SELECT id FROM lines WHERE pack_id = ?)", [.text(id)])
        for table in ["lines", "works", "grams", "char_freq"] {
            try database.run("DELETE FROM \(table) WHERE pack_id = ?", [.text(id)])
        }
        try database.run("DELETE FROM work_pairs WHERE a_pack = ? OR b_pack = ?", [.text(id), .text(id)])
        try database.run("DELETE FROM packs WHERE id = ?", [.text(id)])
    }

    // MARK: - 导入

    private struct ToneBits {
        var cache: [Character: UInt8] = [:]
        let dictionary: CharDictionary

        mutating func bits(_ character: Character) -> UInt8 {
            if let cached = cache[character] { return cached }
            var value: UInt8 = 0
            let ancient = dictionary.tones(of: character, in: .pingshui)
            let modern = dictionary.tones(of: character, in: .tongyun)
            if ancient.contains(.ping) { value |= 1 }
            if ancient.contains(.ze) { value |= 2 }
            if modern.contains(.ping) { value |= 4 }
            if modern.contains(.ze) { value |= 8 }
            cache[character] = value
            return value
        }

        mutating func masks(_ text: String) -> (Int64, Int64, Int64, Int64) {
            var masks: (Int64, Int64, Int64, Int64) = (0, 0, 0, 0)
            for (index, character) in text.enumerated() where index < ToneMasks.maxLength {
                let value = bits(character)
                let bit: Int64 = 1 << index
                if value & 1 != 0 { masks.0 |= bit }
                if value & 2 != 0 { masks.1 |= bit }
                if value & 4 != 0 { masks.2 |= bit }
                if value & 8 != 0 { masks.3 |= bit }
            }
            return masks
        }
    }

    /// 片段是否落在诗句的节奏位置上（五言「二二一 / 二一二」、七言「二二二一 / 二二一二」等）。
    /// 节奏位上的片段更可能是完整的词，候选按此优先；未列出的句长一律视为对齐。
    static func isRhythmAligned(start: Int, length: Int, lineLength: Int) -> Bool {
        let starts: [Int: [Int: Set<Int>]] = [
            2: [2: [0]],
            3: [2: [0, 1], 3: [0]],
            4: [2: [0, 2], 4: [0]],
            5: [2: [0, 2, 3], 3: [2], 4: []],
            6: [2: [0, 2, 4], 3: [0, 3], 4: [0, 2]],
            7: [2: [0, 2, 4, 5], 3: [4], 4: [0]],
        ]
        guard let byLength = starts[lineLength] else { return true }
        return byLength[length]?.contains(start) ?? false
    }

    private static let annotationOpeners: Set<Character> = ["（", "(", "〔", "[", "［", "【"]
    private static let annotationClosers: Set<Character> = ["）", ")", "〕", "]", "］", "】"]

    /// 去掉括号内的校注（如「（一作…）」「(京本作…)」），支持嵌套与全角、半角混用。
    /// 括号内容直接删除、不留分隔，以兼顾「白日（一作…）依山尽」这类夹在句中的注；
    /// 未闭合的左括号及其后内容原样保留，避免误删正文；多余的右括号保留（切句时视为分隔）。
    static func stripAnnotations(_ text: String) -> String {
        var result = ""
        var unclosed = ""
        var depth = 0
        for character in text {
            if annotationOpeners.contains(character) {
                depth += 1
                unclosed.append(character)
            } else if depth > 0, annotationClosers.contains(character) {
                depth -= 1
                unclosed.append(character)
                if depth == 0 { unclosed = "" }
            } else if depth > 0 {
                unclosed.append(character)
            } else {
                result.append(character)
            }
        }
        return result + unclosed
    }

    /// 缺字符号：切句时占一个字位，不作替换候选与对仗统计。
    static let missingCharacter: Character = "□"

    /// 某长度的片段计数（总次数与落在节奏位上的次数）；含缺字的片段不计。
    static func countGrams(_ norms: [String], length: Int) -> [String: (total: Int, aligned: Int)] {
        var counts: [String: (total: Int, aligned: Int)] = [:]
        for norm in norms where norm.count >= length {
            let characters = Array(norm)
            for start in 0...(characters.count - length) {
                let gram = characters[start..<(start + length)]
                guard !gram.contains(missingCharacter) else { continue }
                let text = String(gram)
                let aligned = CorpusIndex.isRhythmAligned(start: start, length: length, lineLength: characters.count)
                counts[text, default: (0, 0)].total += 1
                if aligned { counts[text]?.aligned += 1 }
            }
        }
        return counts
    }

    /// 字频；缺字符号不计。
    static func countCharacters(_ norms: [String]) -> [Character: Int] {
        var counts: [Character: Int] = [:]
        for norm in norms {
            for character in norm where character != missingCharacter { counts[character, default: 0] += 1 }
        }
        return counts
    }

    static func ftsTokens(_ norm: String) -> String {
        let characters = Array(norm)
        guard characters.count > 1 else { return norm }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }.joined(separator: " ")
    }

    @discardableResult
    public func importPack(at directory: URL, progress: @Sendable (ImportProgress) -> Void = { _ in }) throws -> ImportReport {
        progress(ImportProgress(phase: "读取清单", fraction: 0))
        let manifest = try PackManifest.load(from: directory)
        progress(ImportProgress(phase: "解析作品", fraction: 0.05))
        let parsed = try PackReader.read(manifest, in: directory)
        let records = parsed.records
        let converter = dictionary.converter
        var toneBits = ToneBits(dictionary: dictionary)
        var norms: [String] = []
        var gramCount = 0

        try database.transaction {
            try removePackData(manifest.id)
            let insertWork = try database.prepare("""
                INSERT INTO works (pack_id, ext_id, title, author, dynasty, form, tune, preface, body, text_hash)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let insertLine = try database.prepare("""
                INSERT INTO lines (pack_id, work_id, idx, norm, len, gu_ping, gu_ze, jin_ping, jin_ze) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            let insertFTS = try database.prepare("INSERT INTO line_fts (rowid, tokens) VALUES (?, ?)")
            let packID = SQLValue.text(manifest.id)

            for (recordIndex, record) in records.enumerated() {
                if recordIndex % 2_000 == 0 {
                    progress(ImportProgress(phase: "写入作品", fraction: 0.1 + 0.5 * Double(recordIndex) / Double(records.count)))
                }
                let body = record.lines.joined(separator: "\n")
                // 校注可能跨段（左括号与右括号不在同一段），因此对整篇剥离后再切句。
                let workNorms = TextSegmenter.segments(of: CorpusIndex.stripAnnotations(body),
                                                       placeholders: [CorpusIndex.missingCharacter])
                    .map { converter.simplified(String($0.map(\.character))) }
                try insertWork.run([packID, .optional(record.externalID), .optional(record.title.map(converter.simplified)),
                                    .optional(record.author.map(converter.simplified)), .optional(record.dynasty),
                                    .optional(record.form), .optional(record.tune.map(converter.simplified)),
                                    .optional(record.preface), .text(body), .integer(CorpusIndex.textHash(workNorms))])
                let workID = database.lastInsertRowID
                for (lineIndex, norm) in workNorms.enumerated() {
                    let masks = toneBits.masks(norm)
                    try insertLine.run([packID, .integer(workID), .int(lineIndex), .text(norm), .int(norm.count),
                                        .integer(masks.0), .integer(masks.1), .integer(masks.2), .integer(masks.3)])
                    try insertFTS.run([.integer(database.lastInsertRowID), .text(CorpusIndex.ftsTokens(norm))])
                    norms.append(norm)
                }
            }

            let threshold = records.count >= CorpusIndex.largePackWorkCount ? 2 : 1
            let insertGram = try database.prepare("""
                INSERT INTO grams (pack_id, text, len, freq, aligned, gu_ping, gu_ze, jin_ping, jin_ze) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
            for length in CorpusIndex.gramLengths {
                progress(ImportProgress(phase: "统计\(length)字片段", fraction: 0.6 + 0.08 * Double(length - 1)))
                for (text, count) in CorpusIndex.countGrams(norms, length: length) where count.total >= threshold {
                    let masks = toneBits.masks(text)
                    try insertGram.run([packID, .text(text), .int(length), .int(count.total), .int(count.aligned),
                                        .integer(masks.0), .integer(masks.1), .integer(masks.2), .integer(masks.3)])
                    gramCount += 1
                }
            }

            progress(ImportProgress(phase: "统计字频", fraction: 0.84))
            let insertCharacter = try database.prepare("INSERT INTO char_freq (pack_id, ch, freq) VALUES (?, ?, ?)")
            for (character, count) in CorpusIndex.countCharacters(norms) {
                try insertCharacter.run([packID, .text(String(character)), .int(count)])
            }

            try database.run("""
                INSERT INTO packs (id, name, version, era, script, license, source, enabled, work_count, line_count, imported_at,
                    index_format, priority)
                VALUES (?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?)
                """, [packID, .text(manifest.name), .optional(manifest.version), .optional(manifest.era), .optional(manifest.script),
                      .optional(manifest.license), .optional(manifest.source), .int(records.count), .int(norms.count),
                      .real(Date().timeIntervalSince1970), .int(CorpusIndex.indexFormat), .int(manifest.priority ?? 0)])

            progress(ImportProgress(phase: "查找重复作品", fraction: 0.88))
            try detectDuplicates(packID: manifest.id)
        }
        progress(ImportProgress(phase: "取舍重复作品", fraction: 0.95))
        try resolveDuplicates()
        let duplicates = try database.query("SELECT COUNT(*) FROM works WHERE pack_id = ? AND duplicate_of IS NOT NULL",
                                            [.text(manifest.id)]) { $0.int(0) }.first ?? 0
        progress(ImportProgress(phase: "完成", fraction: 1))
        return ImportReport(packID: manifest.id, name: manifest.name, workCount: records.count, lineCount: norms.count,
                            gramCount: gramCount, skippedRecords: parsed.skipped, errors: parsed.errors, duplicateCount: duplicates)
    }

    // MARK: - 查询

    private static let enabledPacks = "SELECT id FROM packs WHERE enabled = 1"
    /// 句不属于被隐藏的重复作品（用于不连接 works 的查询）。
    static let notDuplicateLine = "work_id NOT IN (SELECT id FROM works WHERE duplicate_of IS NOT NULL)"

    /// 满足格律约束的语料片段（2-4 字取 n-gram，5 字以上取整句，1 字取字频）。
    public func candidates(for constraint: SlotConstraint, limit: Int = 60) throws -> [CorpusCandidate] {
        let length = constraint.length
        guard length > 0, length <= ToneMasks.maxLength else { return [] }
        let required = constraint.requiredMasks
        let (pingColumn, zeColumn) = constraint.book.usesModernTones ? ("jin_ping", "jin_ze") : ("gu_ping", "gu_ze")
        // 押韵等条件在 Swift 中二次过滤，SQL 先多取一些。
        let fetchLimit = constraint.rhyme == nil ? limit * 3 : limit * 40
        let rows: [CorpusCandidate]
        let toneParameters: [SQLValue] = [.int(length), .integer(required.ping), .integer(required.ping),
                                          .integer(required.ze), .integer(required.ze)]
        // 次数都减去重复作品（`dup_*` 表）中的部分。
        if length == 1 {
            rows = try database.query("""
                SELECT c.ch, SUM(c.freq) - COALESCE((SELECT d.freq FROM dup_chars d WHERE d.ch = c.ch), 0) AS f
                FROM char_freq c WHERE c.pack_id IN (\(CorpusIndex.enabledPacks))
                GROUP BY c.ch HAVING f > 0 ORDER BY f DESC LIMIT 6000
                """) { CorpusCandidate(text: $0.text(0), frequency: $0.int(1)) }
        } else if CorpusIndex.gramLengths.contains(length) {
            // 片段按节奏位出现次数优先，其次总次数。
            rows = try database.query("""
                SELECT g.text, SUM(g.freq) - COALESCE(d.freq, 0) AS f, SUM(g.aligned) - COALESCE(d.aligned, 0) AS a
                FROM grams g LEFT JOIN dup_grams d ON d.len = g.len AND d.text = g.text
                WHERE g.len = ? AND (g.\(pingColumn) & ?) = ? AND (g.\(zeColumn) & ?) = ? AND g.pack_id IN (\(CorpusIndex.enabledPacks))
                GROUP BY g.text HAVING f > 0 ORDER BY a DESC, f DESC LIMIT ?
                """, toneParameters + [.int(fetchLimit)]) { CorpusCandidate(text: $0.text(0), frequency: $0.int(1)) }
        } else {
            // 整句按出现次数；含缺字的句子不作候选。
            rows = try database.query("""
                SELECT norm, COUNT(*) AS f FROM lines
                WHERE len = ? AND (\(pingColumn) & ?) = ? AND (\(zeColumn) & ?) = ? AND pack_id IN (\(CorpusIndex.enabledPacks))
                    AND instr(norm, '\(CorpusIndex.missingCharacter)') = 0 AND \(CorpusIndex.notDuplicateLine)
                GROUP BY norm ORDER BY f DESC LIMIT ?
                """, toneParameters + [.int(fetchLimit)]) { CorpusCandidate(text: $0.text(0), frequency: $0.int(1)) }
        }
        return Array(rows.lazy.filter { constraint.accepts($0.text, dictionary: self.dictionary) }.prefix(limit))
    }

    private static let lineColumns = """
        l.id, l.norm, l.work_id, l.idx, w.title, w.author, w.dynasty, p.name
        FROM lines l JOIN works w ON w.id = l.work_id JOIN packs p ON p.id = l.pack_id
        """

    private func mapLine(_ row: SQLRow) -> CorpusLine {
        CorpusLine(id: row.int64(0), text: row.text(1), workID: row.int64(2), lineIndex: row.int(3),
                   title: row.optionalText(4), author: row.optionalText(5), dynasty: row.optionalText(6), packName: row.text(7))
    }

    private static func quoted(_ token: String) -> String {
        "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 包含该词句的语料句（前人用例）。同一作品只取最先出现的一句。
    public func usages(of phrase: String, limit: Int = 50) throws -> [CorpusLine] {
        let norm = dictionary.converter.simplified(TextSegmenter.hanOnly(phrase))
        guard !norm.isEmpty else { return [] }
        // 句 id 按导入顺序递增，MIN(id) 即作品中最先出现的一句。
        let firstPerWork: String
        let parameter: SQLValue
        if norm.count == 1 {
            firstPerWork = "SELECT MIN(id) FROM lines WHERE instr(norm, ?) > 0 GROUP BY work_id"
            parameter = .text(norm)
        } else {
            firstPerWork = """
                SELECT MIN(m.id) FROM lines m JOIN line_fts f ON f.rowid = m.id WHERE line_fts MATCH ? GROUP BY m.work_id
                """
            parameter = .text(CorpusIndex.quoted(CorpusIndex.ftsTokens(norm)))
        }
        return try database.query("""
            SELECT \(CorpusIndex.lineColumns) WHERE l.id IN (\(firstPerWork)) AND p.enabled = 1 AND w.duplicate_of IS NULL
            ORDER BY l.id LIMIT ?
            """, [parameter, .int(limit)], mapLine)
    }

    /// 相关诗句（不用 AI）：先用 FTS5/BM25 按双字召回，再按双字与单字的余弦相似度重排，
    /// 过滤过短的片段，排除完全相同的句子。
    public func related(to text: String, limit: Int = 40) throws -> [CorpusLine] {
        let norm = dictionary.converter.simplified(TextSegmenter.hanOnly(text))
        guard norm.count >= 2 else { return try usages(of: norm, limit: limit) }
        let tokens = Array(Set(CorpusIndex.ftsTokens(norm).split(separator: " ").map(String.init))).sorted()
        let expression = tokens.map(CorpusIndex.quoted).joined(separator: " OR ")
        let minimumLength = max(3, norm.count - 2)
        let recalled = try database.query("""
            SELECT \(CorpusIndex.lineColumns) JOIN line_fts f ON f.rowid = l.id
            WHERE line_fts MATCH ? AND p.enabled = 1 AND w.duplicate_of IS NULL AND l.norm <> ? AND l.len >= ?
            ORDER BY bm25(line_fts) LIMIT 300
            """, [.text(expression), .text(norm), .int(minimumLength)], mapLine)
        let scored = recalled.enumerated().map { index, line in
            (line: line, score: CorpusIndex.similarity(norm, line.text), rank: index)
        }
        return scored.sorted { ($0.score, -$0.rank) > ($1.score, -$1.rank) }.prefix(limit).map(\.line)
    }

    /// 双字余弦相似度为主、单字为辅，再乘以句长接近程度（避免短片段占优）。
    static func similarity(_ lhs: String, _ rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let lengthRatio = Double(min(lhs.count, rhs.count)) / Double(max(lhs.count, rhs.count))
        return lexicalSimilarity(lhs, rhs) * lengthRatio.squareRoot()
    }

    static func lexicalSimilarity(_ lhs: String, _ rhs: String) -> Double {
        func cosine(_ a: [String], _ b: [String]) -> Double {
            let left = Set(a), right = Set(b)
            guard !left.isEmpty, !right.isEmpty else { return 0 }
            return Double(left.intersection(right).count) / (Double(left.count) * Double(right.count)).squareRoot()
        }
        func bigrams(_ text: String) -> [String] {
            let characters = Array(text)
            guard characters.count > 1 else { return [] }
            return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
        }
        return cosine(bigrams(lhs), bigrams(rhs)) + 0.3 * cosine(lhs.map(String.init), rhs.map(String.init))
    }

    /// 语料反查出处：整句（四字以上）或连续多句完全一致时返回出处。
    public func findSource(of text: String) throws -> SourceInfo? {
        let segments = TextSegmenter.segments(of: text).map { dictionary.converter.simplified(String($0.map(\.character))) }
        guard let first = segments.first, segments.count > 1 || first.count >= 4 else { return nil }
        let starts = try database.query("""
            SELECT l.work_id, l.idx, w.title, w.author, w.dynasty FROM lines l JOIN works w ON w.id = l.work_id
            JOIN packs p ON p.id = l.pack_id WHERE l.norm = ? AND p.enabled = 1 AND w.duplicate_of IS NULL LIMIT 50
            """, [.text(first)]) { row in
            (row.int64(0), row.int(1), SourceInfo(author: row.optionalText(3), title: row.optionalText(2),
                                                  dynasty: row.optionalText(4), isVerified: true))
        }
        for (workID, index, source) in starts {
            if segments.count == 1 { return source }
            let following = try database.query("SELECT norm FROM lines WHERE work_id = ? AND idx > ? AND idx <= ? ORDER BY idx",
                                               [.integer(workID), .int(index), .int(index + segments.count - 1)]) { $0.text(0) }
            if following == Array(segments.dropFirst()) { return source }
        }
        return nil
    }

    public func work(id: Int64) throws -> CorpusWork? {
        try database.query("""
            SELECT w.id, w.title, w.author, w.dynasty, w.preface, w.body, p.name FROM works w JOIN packs p ON p.id = w.pack_id WHERE w.id = ?
            """, [.integer(id)]) { row in
            CorpusWork(id: row.int64(0), title: row.optionalText(1), author: row.optionalText(2), dynasty: row.optionalText(3),
                       preface: row.optionalText(4), body: dictionary.converter.simplified(row.text(5)), packName: row.text(6))
        }.first
    }

    /// 作品正文的原书字形（`work(id:)` 给出的是简体）。
    public func originalBody(id: Int64) throws -> String? {
        try database.query("SELECT body FROM works WHERE id = ?", [.integer(id)]) { $0.text(0) }.first
    }

    /// 作品各句的原书字形，序号与 `lines.idx` 一致（校注已剥离）；作品不存在时为 nil。
    public func originalLines(id: Int64) throws -> [String]? {
        try originalBody(id: id).map { body in
            TextSegmenter.segments(of: CorpusIndex.stripAnnotations(body), placeholders: [CorpusIndex.missingCharacter])
                .map { String($0.map(\.character)) }
        }
    }

    /// 作品的全文哈希；作品不存在时为 nil。旧版导入的语料尚未补算时先补算全部作品。
    public func textHash(ofWork id: Int64) throws -> Int64? {
        let rows = try database.query("SELECT text_hash FROM works WHERE id = ?", [.integer(id)]) { $0.isNull(0) ? nil : $0.int64(0) }
        guard let stored = rows.first else { return nil }
        if let stored { return stored }
        try database.transaction { try backfillTextHashes() }
        return try database.query("SELECT text_hash FROM works WHERE id = ?", [.integer(id)]) { $0.isNull(0) ? nil : $0.int64(0) }.first ?? nil
    }

    /// 按全文哈希找已启用语料包中的一首：非重复的优先，其次按语料包优先级与导入先后。
    public func workID(textHash: Int64) throws -> Int64? {
        try database.query("""
            SELECT w.id FROM works w JOIN packs p ON p.id = w.pack_id WHERE w.text_hash = ? AND p.enabled = 1
            ORDER BY w.duplicate_of IS NOT NULL, p.priority, p.imported_at, w.id LIMIT 1
            """, [.integer(textHash)]) { $0.int64(0) }.first
    }

    /// 字频（已启用语料包合计），用于韵书浏览排序。
    public func characterFrequencies() throws -> [Character: Int] {
        let rows = try database.query("""
            SELECT c.ch, SUM(c.freq) - COALESCE((SELECT d.freq FROM dup_chars d WHERE d.ch = c.ch), 0)
            FROM char_freq c WHERE c.pack_id IN (\(CorpusIndex.enabledPacks)) GROUP BY c.ch
            """) { ($0.text(0), $0.int(1)) }
        var result: [Character: Int] = [:]
        for (text, count) in rows where count > 0 {
            if let character = text.first, text.count == 1 { result[character] = count }
        }
        return result
    }
}
