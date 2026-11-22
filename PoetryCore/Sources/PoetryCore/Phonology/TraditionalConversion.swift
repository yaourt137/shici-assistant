import Foundation

/// 一段文字的字形：按「只见于繁体的字」与「只见于简体的字」判断。
public enum ScriptKind: String, Sendable, Hashable {
    case traditional = "繁体"
    case simplified = "简体"
    case mixed = "繁简混杂"
    /// 全是繁简同形的字（或没有汉字），看不出。
    case neutral = "繁简同形"
}

extension ScriptConverter {
    /// 判断字形：含繁体专用字（简化后会变的字）且不含简体专用字（繁体字表中没有它自身的字）为繁体，反之为简体；两者都有为混杂。
    public func scriptKind(of text: String) -> ScriptKind {
        var hasTraditional = false
        var hasSimplified = false
        for character in text where TextSegmenter.isHan(character) {
            if simplified(character) != character {
                hasTraditional = true
            } else if !traditionalCandidates(character).contains(character) {
                hasSimplified = true
            }
        }
        switch (hasTraditional, hasSimplified) {
        case (true, true): return .mixed
        case (true, false): return .traditional
        case (false, true): return .simplified
        case (false, false): return .neutral
        }
    }
}

/// 转为繁体的结果：转好的文字，以及字表中有多种繁体、需人工核对的字。
public struct TraditionalConversion: Sendable, Hashable {
    /// 需核对的一字：`offset` 为在 `text` 中的字符位置，`candidates` 的第一个即 `text` 中采用的字。
    public struct Choice: Sendable, Hashable {
        public let offset: Int
        public let candidates: [Character]
    }

    public let text: String
    public let choices: [Choice]

    /// 逐句转换：句子（简体归一后）见于 `known` 时照抄其原书字形；否则逐字查字表，已是繁体的字不动，
    /// 有多种繁体的取字表中的第一个并记入 `choices`。非汉字原样保留，字符位置与原文一一对应。
    /// - Parameter known: 简体句 → 原书繁体句（等长）。
    public static func convert(_ text: String, converter: ScriptConverter, known: [String: String] = [:]) -> TraditionalConversion {
        var characters = Array(text)
        var choices: [Choice] = []
        for segment in TextSegmenter.segments(of: text) {
            let norm = converter.simplified(String(segment.map(\.character)))
            if let original = known[norm].map(Array.init), original.count == segment.count {
                for (item, character) in zip(segment, original) { characters[item.offset] = character }
                continue
            }
            for item in segment where converter.simplified(item.character) == item.character {
                var candidates: [Character] = []
                for candidate in converter.traditionalCandidates(item.character) where !candidates.contains(candidate) {
                    candidates.append(candidate)
                }
                guard let first = candidates.first else { continue }
                characters[item.offset] = first
                if candidates.count > 1 { choices.append(Choice(offset: item.offset, candidates: candidates)) }
            }
        }
        return TraditionalConversion(text: String(characters), choices: choices)
    }

    /// 把 `offset` 处的字换成 `character`；位置越界时原样返回。
    public static func replacing(at offset: Int, with character: Character, in text: String) -> String {
        var characters = Array(text)
        guard characters.indices.contains(offset) else { return text }
        characters[offset] = character
        return String(characters)
    }
}

extension CorpusIndex {
    /// 在已启用的繁体语料包中查找这些简体句，返回 简体句 → 原书字形（按语料包优先级取第一处，等长且简化后一致才算）。
    /// 单字句不查（脱离上下文，借不到字形）。
    public func traditionalLines(for norms: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        var segmentsByWork: [Int64: [String]] = [:]
        for norm in Set(norms) where norm.count >= 2 {
            let rows = try database.query("""
                SELECT l.work_id, l.idx FROM lines l JOIN packs p ON p.id = l.pack_id
                WHERE l.norm = ? AND p.enabled = 1 AND p.script = 'traditional' ORDER BY p.priority, l.work_id LIMIT 20
                """, [.text(norm)]) { (work: $0.int64(0), index: $0.int(1)) }
            for row in rows {
                if segmentsByWork[row.work] == nil { segmentsByWork[row.work] = try originalLines(id: row.work) }
                guard let segments = segmentsByWork[row.work], segments.indices.contains(row.index) else { continue }
                let original = segments[row.index]
                if original.count == norm.count, dictionary.converter.simplified(original) == norm {
                    result[norm] = original
                    break
                }
            }
        }
        return result
    }
}
