import Foundation

/// 基于 OpenCC 字表的逐字繁简转换。只做字级映射，不处理词级歧义。
public struct ScriptConverter: Sendable {
    private let toSimplified: [Character: Character]
    private let toTraditional: [Character: [Character]]
    /// 繁转简字表的反查：简体字 → 所有简化为它的繁体字（含异体，如「为」→「為」「爲」）。
    private let fromSimplified: [Character: [Character]]

    /// - Parameters:
    ///   - traditionalToSimplified: OpenCC `TSCharacters.txt` 的内容。
    ///   - simplifiedToTraditional: OpenCC `STCharacters.txt` 的内容。
    public init(traditionalToSimplified: String, simplifiedToTraditional: String) {
        var simplified: [Character: Character] = [:]
        var reverse: [Character: [Character]] = [:]
        for (key, values) in ScriptConverter.parse(traditionalToSimplified) {
            guard let first = values.first else { continue }
            simplified[key] = first
            if !(reverse[first]?.contains(key) ?? false) { reverse[first, default: []].append(key) }
        }
        self.toSimplified = simplified
        self.fromSimplified = reverse
        self.toTraditional = Dictionary(ScriptConverter.parse(simplifiedToTraditional), uniquingKeysWith: { first, _ in first })
    }

    private static func parse(_ text: String) -> [(Character, [Character])] {
        var result: [(Character, [Character])] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard !line.hasPrefix("#") else { continue }
            let columns = line.split(separator: "\t", maxSplits: 1)
            guard columns.count == 2, columns[0].count == 1, let key = columns[0].first else { continue }
            let values = columns[1].split(separator: " ").compactMap { $0.count == 1 ? $0.first : nil }
            if !values.isEmpty { result.append((key, values)) }
        }
        return result
    }

    public func simplified(_ character: Character) -> Character {
        toSimplified[character] ?? character
    }

    public func simplified(_ text: String) -> String {
        String(text.map { simplified($0) })
    }

    /// 简体字可能对应的繁体字（含自身，若字表如此列出）；无映射时返回自身。
    public func traditionalCandidates(_ character: Character) -> [Character] {
        toTraditional[character] ?? [character]
    }

    /// 繁转简字表中简化为该字的全部繁体字（按字表顺序）；没有则为空。
    /// 用于补足简转繁字表只列出一个异体的情况，例如简转繁「为」只给「爲」，而韵书收「為」。
    public func traditionalVariants(_ character: Character) -> [Character] {
        fromSimplified[character] ?? []
    }
}
