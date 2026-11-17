import Foundation

/// 近体诗体裁。
public enum RegulatedForm: String, Sendable, Hashable, CaseIterable, Codable {
    case wujue = "五绝"
    case qijue = "七绝"
    case wulv = "五律"
    case qilv = "七律"

    public var lineLength: Int { (self == .wujue || self == .wulv) ? 5 : 7 }
    public var lineCount: Int { (self == .wujue || self == .qijue) ? 4 : 8 }
}

/// 近体诗首句的起收：起看第二字，收看末字（平收即首句入韵）。
public enum RegulatedOpening: String, Sendable, Hashable, CaseIterable, Codable {
    case pingPing = "平起平收"
    case pingZe = "平起仄收"
    case zePing = "仄起平收"
    case zeZe = "仄起仄收"

    public var startsPing: Bool { self == .pingPing || self == .pingZe }
    public var firstLineRhymes: Bool { self == .pingPing || self == .zePing }
}

/// 用户为作品选择的体裁。
public enum FormSelection: Sendable, Hashable {
    case automatic
    /// opening 为 nil 时自动判断起收。
    case regulated(RegulatedForm, opening: RegulatedOpening? = nil)
    case ci(String)
    case free

    public var storageValue: String {
        switch self {
        case .automatic: "auto"
        case .regulated(let form, let opening): "regulated:\(form.rawValue)" + (opening.map { ":\($0.rawValue)" } ?? "")
        case .ci(let id): "ci:\(id)"
        case .free: "free"
        }
    }

    public init?(storageValue: String) {
        if storageValue == "auto" { self = .automatic; return }
        if storageValue == "free" { self = .free; return }
        if storageValue.hasPrefix("regulated:") {
            let parts = storageValue.dropFirst("regulated:".count).split(separator: ":", omittingEmptySubsequences: false)
            guard (1...2).contains(parts.count), let form = RegulatedForm(rawValue: String(parts[0])) else { return nil }
            guard parts.count == 2 else {
                self = .regulated(form)
                return
            }
            guard let opening = RegulatedOpening(rawValue: String(parts[1])) else { return nil }
            self = .regulated(form, opening: opening)
            return
        }
        if storageValue.hasPrefix("ci:") {
            let id = String(storageValue.dropFirst(3))
            guard !id.isEmpty else { return nil }
            self = .ci(id)
            return
        }
        return nil
    }
}

// MARK: - 词谱

public struct CiLine: Sendable, Hashable {
    public let slots: [ToneSlot]
    /// 押韵组标记（如 "A"）；nil 表示此句不押韵。
    public let rhymeGroup: String?
    public let stanza: Int

    public var patternText: String { String(slots.map(\.rawValue)) }
}

public struct CiExample: Sendable, Hashable, Codable {
    public let author: String
    public let title: String
    public let text: String
}

public struct CiTune: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let aliases: [String]
    public let summary: String
    public let lines: [CiLine]
    public let example: CiExample?

    public var characterCount: Int { lines.reduce(0) { $0 + $1.slots.count } }
}

public enum CiTuneError: Error, CustomStringConvertible, Equatable {
    case unsupportedFormat(String)
    case invalidLine(tune: String, line: String, reason: String)
    case duplicateID(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let detail): "词谱格式不支持：\(detail)"
        case .invalidLine(let tune, let line, let reason): "词谱「\(tune)」中的句式「\(line)」无效：\(reason)"
        case .duplicateID(let id): "词谱 id 重复：\(id)"
        }
    }
}

/// 词谱库。数据格式与语料包同一套 manifest 约定（kind = "formbook"）。
public struct CiTuneLibrary: Sendable {
    public let tunes: [CiTune]

    public static let bundled: CiTuneLibrary = {
        do {
            guard let url = Bundle.module.url(forResource: "cipu", withExtension: "json", subdirectory: "Resources") else {
                throw CharDictionaryError.missingResource("cipu.json")
            }
            return try CiTuneLibrary(json: Data(contentsOf: url))
        } catch {
            fatalError("内置词谱加载失败：\(error)")
        }
    }()

    public init(tunes: [CiTune]) {
        self.tunes = tunes
    }

    public func tune(id: String) -> CiTune? {
        tunes.first { $0.id == id }
    }

    private struct File: Decodable {
        let formatVersion: Int
        let kind: String
        let tunes: [Entry]
    }

    private struct Entry: Decodable {
        let id: String
        let name: String
        let aliases: [String]?
        let summary: String?
        let stanzas: [[String]]
        let example: CiExample?
    }

    public init(json: Data) throws {
        let file = try JSONDecoder().decode(File.self, from: json)
        guard file.formatVersion == 1 else { throw CiTuneError.unsupportedFormat("formatVersion \(file.formatVersion)") }
        guard file.kind == "formbook" else { throw CiTuneError.unsupportedFormat("kind \(file.kind)") }
        var ids = Set<String>()
        var tunes: [CiTune] = []
        for entry in file.tunes {
            guard ids.insert(entry.id).inserted else { throw CiTuneError.duplicateID(entry.id) }
            var lines: [CiLine] = []
            for (stanza, specs) in entry.stanzas.enumerated() {
                for spec in specs {
                    lines.append(try CiTuneLibrary.parseLine(spec, stanza: stanza, tune: entry.name))
                }
            }
            tunes.append(CiTune(id: entry.id, name: entry.name, aliases: entry.aliases ?? [],
                                summary: entry.summary ?? "", lines: lines, example: entry.example))
        }
        self.tunes = tunes
    }

    /// 句式写法：平仄中组成的串，末尾可跟一个大写字母表示押韵组，例如 `中仄中平中仄平A`。
    static func parseLine(_ spec: String, stanza: Int, tune: String) throws -> CiLine {
        var body = Substring(spec)
        var group: String?
        if let last = body.last, last.isASCII, last.isUppercase {
            group = String(last)
            body = body.dropLast()
        }
        guard !body.isEmpty else {
            throw CiTuneError.invalidLine(tune: tune, line: spec, reason: "句式为空")
        }
        var slots: [ToneSlot] = []
        for character in body {
            guard let slot = ToneSlot(rawValue: character) else {
                throw CiTuneError.invalidLine(tune: tune, line: spec, reason: "含有非平仄中字符「\(character)」")
            }
            slots.append(slot)
        }
        if group != nil, slots.last == .any {
            throw CiTuneError.invalidLine(tune: tune, line: spec, reason: "韵脚位置必须标明平或仄")
        }
        return CiLine(slots: slots, rhymeGroup: group, stanza: stanza)
    }
}
