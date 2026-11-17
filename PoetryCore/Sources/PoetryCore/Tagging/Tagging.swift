import Foundation

/// 层级标签路径，例如「季节/秋/晚秋」。
public enum TagPath {
    /// 规范化：去首尾空白，统一全角斜杠，去掉空层级。全空时返回 nil。
    public static func normalize(_ raw: String) -> String? {
        let components = raw
            .replacingOccurrences(of: "／", with: "/")
            .split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    public static func components(of path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    /// 自身及所有上级路径：「季节/秋/晚秋」→ [季节, 季节/秋, 季节/秋/晚秋]。
    public static func lineage(of path: String) -> [String] {
        let parts = components(of: path)
        return parts.indices.map { parts[0...$0].joined(separator: "/") }
    }

    /// 标签条件是否命中某标签：完全相同、为其上级，或（条件不含层级时）等于其中某一层。
    public static func matches(_ atom: String, path: String) -> Bool {
        if path == atom || path.hasPrefix(atom + "/") { return true }
        guard !atom.contains("/") else { return false }
        return components(of: path).contains(atom)
    }

    /// 改名：把 `old` 及其下级替换为 `new` 前缀。不受影响时返回 nil。
    public static func renamed(_ path: String, from old: String, to new: String) -> String? {
        if path == old { return new }
        if path.hasPrefix(old + "/") { return new + path.dropFirst(old.count) }
        return nil
    }
}

/// 标签树节点（用于侧边栏展示）。
public struct TagTreeNode: Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let children: [TagTreeNode]?

    /// 由路径列表构建树；缺失的上级路径会自动补出。
    public static func build(_ paths: [String]) -> [TagTreeNode] {
        let all = Set(paths.compactMap(TagPath.normalize).flatMap(TagPath.lineage(of:)))
        var childrenByParent: [String: [String]] = [:]
        for path in all {
            let components = TagPath.components(of: path)
            let parent = components.dropLast().joined(separator: "/")
            childrenByParent[parent, default: []].append(path)
        }
        func nodes(under parent: String) -> [TagTreeNode]? {
            guard let children = childrenByParent[parent], !children.isEmpty else { return nil }
            return children.sorted().map { path in
                TagTreeNode(id: path, name: TagPath.components(of: path).last ?? path, children: nodes(under: path))
            }
        }
        return nodes(under: "") ?? []
    }
}

/// 收藏筛选的分面条件。
public enum PhraseFacet: String, Sendable, Hashable, CaseIterable {
    case length = "字数"
    case kind = "类型"
    case source = "来源"
    case status = "状态"
    case contains = "含"
}

public indirect enum PhraseFilter: Sendable, Hashable {
    case all
    case tag(String)
    case facet(PhraseFacet, String)
    case not(PhraseFilter)
    case and([PhraseFilter])
    case or([PhraseFilter])

    public func matches(_ phrase: Phrase) -> Bool {
        switch self {
        case .all:
            return true
        case .tag(let atom):
            return phrase.tags.contains { TagPath.matches(atom, path: $0.path) }
        case .facet(let facet, let value):
            switch facet {
            case .length: return Int(value) == phrase.hanText.count
            case .kind: return phrase.kind.rawValue == value
            case .source: return phrase.provenance.kind.rawValue.lowercased() == value.lowercased()
            case .status: return phrase.status.displayName == value
            case .contains: return phrase.text.contains(value) || phrase.hanText.contains(value)
            }
        case .not(let inner):
            return !inner.matches(phrase)
        case .and(let filters):
            return filters.allSatisfy { $0.matches(phrase) }
        case .or(let filters):
            return filters.contains { $0.matches(phrase) }
        }
    }
}

public struct FilterParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// 筛选表达式：空格分隔表示「且」，`|` 表示「或」，前缀 `-` 或 `!` 表示「非」；
/// `字数:5`、`类型:句`、`来源:摘录`、`状态:收件箱`、`含:月` 为分面条件，其余为标签。
/// 例：`季节/秋 月|雁 -来源:agent`
public enum PhraseFilterParser {
    public static func parse(_ query: String) throws(FilterParseError) -> PhraseFilter {
        let tokens = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !tokens.isEmpty else { return .all }
        var terms: [PhraseFilter] = []
        for token in tokens {
            var body = Substring(token)
            var negated = false
            if let first = body.first, first == "-" || first == "!" || first == "－" || first == "！" {
                negated = true
                body = body.dropFirst()
            }
            guard !body.isEmpty else { throw FilterParseError(message: "「\(token)」：否定符后缺少条件") }
            let alternatives = body.replacingOccurrences(of: "｜", with: "|").split(separator: "|", omittingEmptySubsequences: false)
            guard alternatives.allSatisfy({ !$0.isEmpty }) else {
                throw FilterParseError(message: "「\(token)」：「|」两侧都需要条件")
            }
            let atoms = try alternatives.map { alternative throws(FilterParseError) in try atom(String(alternative)) }
            let term: PhraseFilter = atoms.count == 1 ? atoms[0] : .or(atoms)
            terms.append(negated ? .not(term) : term)
        }
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    private static func atom(_ text: String) throws(FilterParseError) -> PhraseFilter {
        let normalized = text.replacingOccurrences(of: "：", with: ":")
        if let separator = normalized.firstIndex(of: ":"),
           let facet = PhraseFacet(rawValue: String(normalized[..<separator])) {
            let value = String(normalized[normalized.index(after: separator)...])
            guard !value.isEmpty else { throw FilterParseError(message: "「\(text)」：缺少取值") }
            switch facet {
            case .length:
                guard let number = Int(value), number > 0 else {
                    throw FilterParseError(message: "「\(text)」：字数应为正整数")
                }
            case .kind:
                guard PhraseKind(rawValue: value) != nil else {
                    throw FilterParseError(message: "「\(text)」：类型应为字、词、句或联")
                }
            case .source:
                guard ProvenanceKind.allCases.contains(where: { $0.rawValue.lowercased() == value.lowercased() }) else {
                    throw FilterParseError(message: "「\(text)」：来源应为自撰、摘录或 agent")
                }
            case .status:
                guard value == ReviewStatus.inbox.displayName || value == ReviewStatus.accepted.displayName else {
                    throw FilterParseError(message: "「\(text)」：状态应为收件箱或已入库")
                }
            case .contains:
                break
            }
            return .facet(facet, value)
        }
        guard let path = TagPath.normalize(text) else { throw FilterParseError(message: "「\(text)」：标签为空") }
        return .tag(path)
    }
}
