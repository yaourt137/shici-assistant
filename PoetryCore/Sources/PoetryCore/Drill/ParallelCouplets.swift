import Foundation

/// 语料中的一联对仗（简体归一）。
public struct ParallelCouplet: Sendable, Hashable {
    public let workID: Int64
    /// 出句在作品中的序号。
    public let lineIndex: Int
    public let left: String
    public let right: String
}

/// 从语料取对仗联并统计同位字对。
///
/// 取法：句数为偶数且不少于八句、各句同为五言或七言的作品（律诗与排律），除首尾两联外的各联，
/// 且两句须成律对、出句仄收而对句平收（以此排除古体）。这些联绝大多数是对仗，逐字对齐即得「某字常对某字」的统计。
/// 跨语料包重复的作品只取保留的那份；含缺字的联不取。
public enum ParallelCouplets {
    /// 统计格式：改变取法或计数方式时加一，旧统计随之重建。2：排除重复作品与含缺字的联。
    public static let format = 2
    /// 双字词对至少出现这么多次才保存（单字对全部保存）。
    static let minimumWordPairCount = 2

    /// 一首诗中可作对仗统计的联：返回出句序号与两句。
    static func middleCouplets(of lines: [String]) -> [(index: Int, left: String, right: String)] {
        guard lines.count >= 8, lines.count.isMultiple(of: 2), let length = lines.first?.count,
              length == 5 || length == 7, lines.allSatisfy({ $0.count == length }) else { return [] }
        return stride(from: 2, to: lines.count - 2, by: 2).map { (index: $0, left: lines[$0], right: lines[$0 + 1]) }
    }

    /// 两句成律对，且出句仄收、对句平收。
    static func isRegulatedPair(_ left: String, _ right: String, dictionary: CharDictionary) -> Bool {
        let tones = [left, right].map { line in line.map { dictionary.tones(of: $0, in: .pingshui) } }
        let analysis = MeterAnalyzer.analyze(tones)
        guard analysis.couplets.first?.relation == .opposed, let out = analysis.lines[0].meter,
              let response = analysis.lines[1].meter else { return false }
        return !out.endsPing && response.endsPing
    }

    /// 同位字对与同位双字词对的次数；两边相同的位置不计。
    static func countPairs(_ couplets: [(left: String, right: String)]) -> [PairKey: Int] {
        var counts: [PairKey: Int] = [:]
        for couplet in couplets {
            let left = Array(couplet.left)
            let right = Array(couplet.right)
            guard left.count == right.count else { continue }
            for index in left.indices where left[index] != right[index] {
                counts[PairKey(String(left[index]), String(right[index])), default: 0] += 1
            }
            for index in left.indices.dropLast() {
                let leftWord = String(left[index...index + 1])
                let rightWord = String(right[index...index + 1])
                if leftWord != rightWord { counts[PairKey(leftWord, rightWord), default: 0] += 1 }
            }
        }
        return counts
    }
}

extension CorpusIndex {
    /// 当前已启用语料包的标识；与统计时记下的不同即需重建。
    func parallelSignature() throws -> String {
        let packs = try database.query("SELECT id, imported_at, index_format FROM packs WHERE enabled = 1 ORDER BY id") { row in
            "\(row.text(0))@\(row.double(1))#\(row.int(2))"
        }
        return "v\(ParallelCouplets.format);" + packs.joined(separator: ";")
    }

    /// 对仗统计是否与当前语料一致。
    public func isParallelIndexCurrent() throws -> Bool {
        let stored = try database.query("SELECT value FROM parallel_meta WHERE key = 'signature'") { $0.text(0) }.first
        return stored == (try parallelSignature())
    }

    /// 由已启用的语料包重建对仗统计，返回所得联数。
    @discardableResult
    public func buildParallelIndex(progress: @Sendable (ImportProgress) -> Void = { _ in }) throws -> Int {
        progress(ImportProgress(phase: "读取诗句", fraction: 0))
        var couplets: [ParallelCouplet] = []
        var currentWork: Int64?
        var lines: [String] = []
        func flush() {
            guard let work = currentWork else { return }
            for couplet in ParallelCouplets.middleCouplets(of: lines)
            where !couplet.left.contains(CorpusIndex.missingCharacter) && !couplet.right.contains(CorpusIndex.missingCharacter)
                && ParallelCouplets.isRegulatedPair(couplet.left, couplet.right, dictionary: dictionary) {
                couplets.append(ParallelCouplet(workID: work, lineIndex: couplet.index, left: couplet.left, right: couplet.right))
            }
        }
        let rows = try database.query("""
            SELECT l.work_id, l.norm FROM lines l JOIN packs p ON p.id = l.pack_id JOIN works w ON w.id = l.work_id
            WHERE p.enabled = 1 AND w.duplicate_of IS NULL ORDER BY l.work_id, l.idx
            """) { (work: $0.int64(0), norm: $0.text(1)) }
        for row in rows {
            if row.work != currentWork {
                flush()
                currentWork = row.work
                lines = []
            }
            lines.append(row.norm)
        }
        flush()

        progress(ImportProgress(phase: "统计字对", fraction: 0.6))
        let counts = ParallelCouplets.countPairs(couplets.map { (left: $0.left, right: $0.right) })
        let signature = try parallelSignature()
        try database.transaction {
            try database.execute("DELETE FROM parallel_lines; DELETE FROM parallel_pairs; DELETE FROM parallel_meta;")
            let insertLine = try database.prepare("INSERT INTO parallel_lines (work_id, idx, left, right) VALUES (?, ?, ?, ?)")
            for couplet in couplets {
                try insertLine.run([.integer(couplet.workID), .int(couplet.lineIndex), .text(couplet.left), .text(couplet.right)])
            }
            let insertPair = try database.prepare("INSERT INTO parallel_pairs (a, b, n) VALUES (?, ?, ?)")
            for (key, count) in counts where key.first.count == 1 || count >= ParallelCouplets.minimumWordPairCount {
                try insertPair.run([.text(key.first), .text(key.second), .int(count)])
            }
            try database.run("INSERT INTO parallel_meta (key, value) VALUES ('signature', ?)", [.text(signature)])
        }
        progress(ImportProgress(phase: "完成", fraction: 1))
        return couplets.count
    }

    /// 对仗联总数（用于换算评分门槛）。
    public func parallelCoupletCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM parallel_lines") { $0.int(0) }.first ?? 0
    }

    /// 全部对仗联，按作品与句序。
    public func parallelCouplets() throws -> [ParallelCouplet] {
        try database.query("SELECT work_id, idx, left, right FROM parallel_lines ORDER BY work_id, idx") { row in
            ParallelCouplet(workID: row.int64(0), lineIndex: row.int(1), left: row.text(2), right: row.text(3))
        }
    }

    /// 各键在对仗联中同位出现的次数（未出现的不在结果中）。键须为简体。
    public func pairCounts(_ keys: [PairKey]) throws -> [PairKey: Int] {
        var result: [PairKey: Int] = [:]
        for key in Set(keys) {
            let count = try database.query("SELECT n FROM parallel_pairs WHERE a = ? AND b = ?",
                                           [.text(key.first), .text(key.second)]) { $0.int(0) }.first
            if let count { result[key] = count }
        }
        return result
    }

    /// 律诗对仗中与 `text`（一或两个简体字）最常相对的字或词，次数多的在前。
    public func parallelCounterparts(of text: String, limit: Int = 10) throws -> [(text: String, count: Int)] {
        guard !text.isEmpty, limit > 0 else { return [] }
        return try database.query("""
            SELECT b, n FROM parallel_pairs WHERE a = ? UNION ALL SELECT a, n FROM parallel_pairs WHERE b = ?
            ORDER BY 2 DESC, 1 LIMIT ?
            """, [.text(text), .text(text), .int(limit)]) { (text: $0.text(0), count: $0.int(1)) }
    }
}
