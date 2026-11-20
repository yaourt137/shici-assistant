import Foundation

/// 同一作品在各语料包中的一个版本。
public struct CorpusWorkVersion: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let title: String?
    public let author: String?
    public let dynasty: String?
    public let packName: String
    /// 是否为查询所用的那一份。
    public let isPrimary: Bool
}

/// 跨语料包的重复作品。
///
/// 导入时把新语料包与其他语料包（不论是否启用）比对，记下重复的作品对（`work_pairs`）：
/// - 全文相同（简体归一后），不论作者；
/// - 作者相同，且四字以上的句子中至少七成相同（异文、异体字）。
/// 同一语料包内部的重复（原书「重出」）不处理。
///
/// 启用、停用、导入、删除语料包后重新取舍：每组重复作品中，只保留优先的语料包（`priority` 小的；相同则先导入的）里的那份，
/// 其余记为 `duplicate_of`，不参与检索、用例、候选次数与对仗统计；停用优先的语料包后，其余版本自动恢复。
extension CorpusIndex {
    /// 判定异文时，相同句数占两者中较多一方句数的最低比例。
    static let variantLineRatio = 0.7
    /// 判定异文时只比较这么长以上的句子（短句容易偶然相同）。
    static let variantMinimumLineLength = 4

    /// 全文（各句简体）的 64 位 FNV-1a 哈希。
    static func textHash(_ norms: [String]) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for norm in norms {
            for byte in norm.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return Int64(bitPattern: hash)
    }

    /// 旧版导入的作品没有全文哈希：由已存的句补算。
    func backfillTextHashes() throws {
        let rows = try database.query("""
            SELECT w.id, l.norm FROM works w LEFT JOIN lines l ON l.work_id = w.id
            WHERE w.text_hash IS NULL ORDER BY w.id, l.idx
            """) { (id: $0.int64(0), norm: $0.optionalText(1)) }
        guard !rows.isEmpty else { return }
        var hashes: [(Int64, Int64)] = []
        var current: Int64?
        var norms: [String] = []
        for row in rows {
            if row.id != current {
                if let current { hashes.append((current, CorpusIndex.textHash(norms))) }
                current = row.id
                norms = []
            }
            if let norm = row.norm { norms.append(norm) }
        }
        if let current { hashes.append((current, CorpusIndex.textHash(norms))) }
        let update = try database.prepare("UPDATE works SET text_hash = ? WHERE id = ?")
        for (id, hash) in hashes { try update.run([.integer(hash), .integer(id)]) }
    }

    /// 两作品是否算同一作品的不同版本：作者相同且相同的句子够多。
    static func isVariant(sharedLines: Int, lineCounts: (Int, Int), authors: (String?, String?)) -> Bool {
        guard let left = authors.0, let right = authors.1, !left.isEmpty, left == right else { return false }
        let larger = max(lineCounts.0, lineCounts.1)
        guard larger > 0 else { return false }
        return Double(sharedLines) >= variantLineRatio * Double(larger)
    }

    /// 把 `packID` 中的作品与其他语料包比对，记下重复的作品对。须在导入的事务内调用。
    func detectDuplicates(packID: String) throws {
        try backfillTextHashes()
        var pairs: [(a: Int64, b: Int64, bPack: String)] = []
        pairs += try database.query("""
            SELECT n.id, o.id, o.pack_id FROM works n JOIN works o ON o.text_hash = n.text_hash AND o.pack_id <> n.pack_id
            WHERE n.pack_id = ?
            """, [.text(packID)]) { (a: $0.int64(0), b: $0.int64(1), bPack: $0.text(2)) }

        // 至少两句相同的作品对，再按作者与比例筛选。
        let candidates = try database.query("""
            SELECT a.work_id, b.work_id, b.pack_id, COUNT(DISTINCT a.norm) FROM lines a JOIN lines b ON b.norm = a.norm
            WHERE a.pack_id = ? AND a.len >= ? AND b.pack_id <> ?
            GROUP BY a.work_id, b.work_id HAVING COUNT(DISTINCT a.norm) >= 2
            """, [.text(packID), .int(CorpusIndex.variantMinimumLineLength), .text(packID)]) {
            (a: $0.int64(0), b: $0.int64(1), bPack: $0.text(2), shared: $0.int(3))
        }
        if !candidates.isEmpty {
            try database.execute("CREATE TEMP TABLE IF NOT EXISTS dup_candidates (id INTEGER PRIMARY KEY); DELETE FROM dup_candidates;")
            let insert = try database.prepare("INSERT OR IGNORE INTO dup_candidates (id) VALUES (?)")
            for candidate in candidates {
                try insert.run([.integer(candidate.a)])
                try insert.run([.integer(candidate.b)])
            }
            var lineCounts: [Int64: Int] = [:]
            for row in try database.query("""
                SELECT work_id, COUNT(DISTINCT norm) FROM lines WHERE len >= ? AND work_id IN (SELECT id FROM dup_candidates)
                GROUP BY work_id
                """, [.int(CorpusIndex.variantMinimumLineLength)], { (id: $0.int64(0), count: $0.int(1)) }) {
                lineCounts[row.id] = row.count
            }
            var authors: [Int64: String] = [:]
            for row in try database.query("SELECT id, author FROM works WHERE id IN (SELECT id FROM dup_candidates)",
                                          [], { (id: $0.int64(0), author: $0.optionalText(1)) }) {
                if let author = row.author { authors[row.id] = author }
            }
            try database.execute("DELETE FROM dup_candidates")
            for candidate in candidates where CorpusIndex.isVariant(
                sharedLines: candidate.shared, lineCounts: (lineCounts[candidate.a] ?? 0, lineCounts[candidate.b] ?? 0),
                authors: (authors[candidate.a], authors[candidate.b])) {
                pairs.append((candidate.a, candidate.b, candidate.bPack))
            }
        }

        let insertPair = try database.prepare("INSERT OR IGNORE INTO work_pairs (a, b, a_pack, b_pack) VALUES (?, ?, ?, ?)")
        for pair in pairs {
            try insertPair.run([.integer(pair.a), .integer(pair.b), .text(packID), .text(pair.bPack)])
        }
    }

    /// 由已启用语料包之间的重复作品对，决定每组保留哪一份；并重算需从片段与字频中扣除的次数。
    func resolveDuplicates() throws {
        let ranks = try database.query("SELECT id, priority, imported_at FROM packs WHERE enabled = 1") {
            (id: $0.text(0), priority: $0.int(1), importedAt: $0.double(2))
        }
        var rankOf: [String: (Int, Double, String)] = [:]
        for rank in ranks { rankOf[rank.id] = (rank.priority, rank.importedAt, rank.id) }
        let pairs = try database.query("SELECT a, b, a_pack, b_pack FROM work_pairs") {
            (a: $0.int64(0), b: $0.int64(1), aPack: $0.text(2), bPack: $0.text(3))
        }.filter { rankOf[$0.aPack] != nil && rankOf[$0.bPack] != nil }

        let canonical = CorpusIndex.chooseCanonical(pairs: pairs.map { ($0.a, $0.aPack, $0.b, $0.bPack) }) { lhs, rhs in
            guard let left = rankOf[lhs], let right = rankOf[rhs] else { return lhs < rhs }
            return left < right
        }

        try database.transaction {
            try database.execute("UPDATE works SET duplicate_of = NULL WHERE duplicate_of IS NOT NULL")
            let update = try database.prepare("UPDATE works SET duplicate_of = ? WHERE id = ?")
            for (work, primary) in canonical { try update.run([.integer(primary), .integer(work)]) }

            try database.execute("DELETE FROM dup_grams; DELETE FROM dup_chars;")
            guard !canonical.isEmpty else { return }
            let norms = try database.query("""
                SELECT l.norm FROM lines l JOIN works w ON w.id = l.work_id WHERE w.duplicate_of IS NOT NULL
                """) { $0.text(0) }
            let insertGram = try database.prepare("INSERT INTO dup_grams (len, text, freq, aligned) VALUES (?, ?, ?, ?)")
            for length in CorpusIndex.gramLengths {
                for (text, count) in CorpusIndex.countGrams(norms, length: length) {
                    try insertGram.run([.int(length), .text(text), .int(count.total), .int(count.aligned)])
                }
            }
            let insertCharacter = try database.prepare("INSERT INTO dup_chars (ch, freq) VALUES (?, ?)")
            for (character, count) in CorpusIndex.countCharacters(norms) {
                try insertCharacter.run([.text(String(character)), .int(count)])
            }
        }
    }

    /// 由重复作品对决定隐藏哪些作品：按连通分组，组内最优先的语料包里的作品都保留（包内重出不处理），
    /// 其余作品指向与它直接成对的保留作品（没有则指向组内保留作品中 id 最小的）。返回 隐藏作品 → 保留作品。
    static func chooseCanonical(pairs: [(Int64, String, Int64, String)],
                                packPrecedes: (String, String) -> Bool) -> [Int64: Int64] {
        var parent: [Int64: Int64] = [:]
        var packOf: [Int64: String] = [:]
        var partners: [Int64: Set<Int64>] = [:]
        func find(_ work: Int64) -> Int64 {
            var root = work
            while let next = parent[root], next != root { root = next }
            var node = work
            while let next = parent[node], next != root {
                parent[node] = root
                node = next
            }
            return root
        }
        for (a, aPack, b, bPack) in pairs {
            packOf[a] = aPack
            packOf[b] = bPack
            partners[a, default: []].insert(b)
            partners[b, default: []].insert(a)
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            let (rootA, rootB) = (find(a), find(b))
            if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
        }
        var groups: [Int64: [Int64]] = [:]
        for work in parent.keys { groups[find(work), default: []].append(work) }

        var result: [Int64: Int64] = [:]
        for members in groups.values {
            let packs = Set(members.compactMap { packOf[$0] })
            guard let best = packs.min(by: packPrecedes) else { continue }
            let kept = members.filter { packOf[$0] == best }.sorted()
            guard let fallback = kept.first else { continue }
            for work in members where packOf[work] != best {
                result[work] = partners[work]?.filter { packOf[$0] == best }.min() ?? fallback
            }
        }
        return result
    }

    /// 同一作品的其他版本（不含自身）：保留的那份在前。
    public func versions(of workID: Int64) throws -> [CorpusWorkVersion] {
        guard let root = try database.query("SELECT COALESCE(duplicate_of, id) FROM works WHERE id = ?",
                                            [.integer(workID)], { $0.int64(0) }).first else { return [] }
        return try database.query("""
            SELECT w.id, w.title, w.author, w.dynasty, p.name, w.duplicate_of IS NULL FROM works w JOIN packs p ON p.id = w.pack_id
            WHERE (w.id = ? OR w.duplicate_of = ?) AND w.id <> ? ORDER BY w.duplicate_of IS NOT NULL, w.id
            """, [.integer(root), .integer(root), .integer(workID)]) { row in
            CorpusWorkVersion(id: row.int64(0), title: row.optionalText(1), author: row.optionalText(2),
                              dynasty: row.optionalText(3), packName: row.text(4), isPrimary: row.int(5) == 1)
        }
    }
}
