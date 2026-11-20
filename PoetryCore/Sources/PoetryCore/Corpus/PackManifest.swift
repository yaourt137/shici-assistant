import Foundation

public enum PackError: Error, Equatable, CustomStringConvertible {
    case missingManifest(String)
    case invalidManifest(String)
    case missingFile(String)
    case unreadableFile(String, String)
    case noValidRecords(String)

    public var description: String {
        switch self {
        case .missingManifest(let path): "缺少 manifest.json：\(path)"
        case .invalidManifest(let detail): "manifest.json 无效：\(detail)"
        case .missingFile(let name): "manifest 列出的文件不存在：\(name)"
        case .unreadableFile(let name, let detail): "无法读取 \(name)：\(detail)"
        case .noValidRecords(let detail): "没有可导入的作品：\(detail)"
        }
    }
}

/// 语料包清单（`manifest.json`）。
public struct PackManifest: Codable, Sendable, Hashable {
    public static let supportedFormatVersion = 1
    /// 标准字段，`fieldMapping` 的键必须在其中。
    public static let standardFields: Set<String> = ["id", "title", "author", "dynasty", "form", "tune", "preface", "lines", "tags", "notes"]

    public var formatVersion: Int
    public var kind: String
    public var id: String
    public var name: String
    public var version: String?
    public var era: String?
    public var script: String?
    public var license: String?
    public var source: String?
    public var files: [String]
    public var fieldMapping: [String: String]?
    /// 与其他语料包重复的作品保留哪一份：数值小的优先，缺省为 0；相同时先导入的优先。
    public var priority: Int?

    public static let priorityRange = 0...1_000

    public init(formatVersion: Int = supportedFormatVersion, kind: String = "corpus", id: String, name: String,
                version: String? = nil, era: String? = nil, script: String? = nil, license: String? = nil,
                source: String? = nil, files: [String], fieldMapping: [String: String]? = nil, priority: Int? = nil) {
        self.formatVersion = formatVersion
        self.kind = kind
        self.id = id
        self.name = name
        self.version = version
        self.era = era
        self.script = script
        self.license = license
        self.source = source
        self.files = files
        self.fieldMapping = fieldMapping
        self.priority = priority
    }

    public static func load(from directory: URL) throws -> PackManifest {
        let url = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: url.path) else { throw PackError.missingManifest(directory.path) }
        let manifest: PackManifest
        do {
            manifest = try JSONDecoder().decode(PackManifest.self, from: Data(contentsOf: url))
        } catch let error as DecodingError {
            throw PackError.invalidManifest(String(describing: error))
        }
        try manifest.validate(in: directory)
        return manifest
    }

    public func validate(in directory: URL) throws {
        guard formatVersion == PackManifest.supportedFormatVersion else {
            throw PackError.invalidManifest("formatVersion 应为 \(PackManifest.supportedFormatVersion)，实为 \(formatVersion)")
        }
        guard kind == "corpus" else { throw PackError.invalidManifest("kind 应为 corpus，实为 \(kind)") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !id.isEmpty, id.unicodeScalars.allSatisfy(allowed.contains) else {
            throw PackError.invalidManifest("id 只能包含字母、数字、-、_、.")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw PackError.invalidManifest("name 不能为空") }
        guard !files.isEmpty else { throw PackError.invalidManifest("files 不能为空") }
        if let script, !["traditional", "simplified", "mixed"].contains(script) {
            throw PackError.invalidManifest("script 应为 traditional、simplified 或 mixed")
        }
        if let priority, !PackManifest.priorityRange.contains(priority) {
            throw PackError.invalidManifest("priority 应在 \(PackManifest.priorityRange.lowerBound)–\(PackManifest.priorityRange.upperBound) 之间")
        }
        if let mapping = fieldMapping {
            let unknown = Set(mapping.keys).subtracting(PackManifest.standardFields)
            guard unknown.isEmpty else {
                throw PackError.invalidManifest("fieldMapping 含未知标准字段：\(unknown.sorted().joined(separator: "、"))")
            }
        }
        for file in files {
            guard !file.contains(".."), !file.hasPrefix("/") else { throw PackError.invalidManifest("文件路径不能越出包目录：\(file)") }
            guard file.hasSuffix(".json") || file.hasSuffix(".jsonl") else {
                throw PackError.invalidManifest("只支持 .json 与 .jsonl：\(file)")
            }
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(file).path) else {
                throw PackError.missingFile(file)
            }
        }
    }
}

/// 标准化后的作品记录。
public struct WorkRecord: Sendable, Hashable {
    public var externalID: String?
    public var title: String?
    public var author: String?
    public var dynasty: String?
    public var form: String?
    public var tune: String?
    public var preface: String?
    public var lines: [String]
    public var tags: [String]
    public var notes: String?
}

/// 读取语料包文件并按 `fieldMapping` 映射为标准记录。
public enum PackReader {
    public struct Result: Sendable {
        public let records: [WorkRecord]
        public let skipped: Int
        public let errors: [String]
    }

    public static func read(_ manifest: PackManifest, in directory: URL) throws -> Result {
        var records: [WorkRecord] = []
        var skipped = 0
        var errors: [String] = []
        func note(_ message: String) {
            skipped += 1
            if errors.count < 20 { errors.append(message) }
        }
        for file in manifest.files {
            let url = directory.appendingPathComponent(file)
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw PackError.unreadableFile(file, error.localizedDescription)
            }
            if file.hasSuffix(".jsonl") {
                let text = String(decoding: data, as: UTF8.self)
                for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    guard let object = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
                        note("\(file) 第 \(index + 1) 行不是 JSON 对象")
                        continue
                    }
                    if let record = record(from: object, manifest: manifest) {
                        records.append(record)
                    } else {
                        note("\(file) 第 \(index + 1) 行缺少正文")
                    }
                }
            } else {
                let object: Any
                do {
                    object = try JSONSerialization.jsonObject(with: data)
                } catch {
                    throw PackError.unreadableFile(file, "JSON 解析失败：\(error.localizedDescription)")
                }
                guard let array = object as? [Any] else { throw PackError.unreadableFile(file, "顶层应为作品数组") }
                for (index, element) in array.enumerated() {
                    guard let dictionary = element as? [String: Any], let record = record(from: dictionary, manifest: manifest) else {
                        note("\(file) 第 \(index + 1) 条缺少正文或格式错误")
                        continue
                    }
                    records.append(record)
                }
            }
        }
        guard !records.isEmpty else { throw PackError.noValidRecords(errors.first ?? "文件为空") }
        return Result(records: records, skipped: skipped, errors: errors)
    }

    static func record(from object: [String: Any], manifest: PackManifest) -> WorkRecord? {
        let mapping = manifest.fieldMapping ?? [:]
        func value(_ field: String) -> Any? { object[mapping[field] ?? field] }
        func string(_ field: String) -> String? {
            switch value(field) {
            case let text as String:
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            case let number as NSNumber:
                return number.stringValue
            default:
                return nil
            }
        }
        func strings(_ field: String, separators: CharacterSet) -> [String] {
            switch value(field) {
            case let array as [Any]:
                return array.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            case let text as String:
                return text.components(separatedBy: separators).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default:
                return []
            }
        }
        let lines = strings("lines", separators: .newlines)
        guard lines.contains(where: { !TextSegmenter.hanOnly($0).isEmpty }) else { return nil }
        return WorkRecord(
            externalID: string("id"),
            title: string("title"),
            author: string("author"),
            dynasty: string("dynasty") ?? manifest.era,
            form: string("form"),
            tune: string("tune"),
            preface: string("preface"),
            lines: lines,
            tags: strings("tags", separators: CharacterSet(charactersIn: ",，、")),
            notes: string("notes")
        )
    }
}
