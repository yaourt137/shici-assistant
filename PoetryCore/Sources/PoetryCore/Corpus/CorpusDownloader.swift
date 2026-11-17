import Foundation

/// 可下载的公开语料（chinese-poetry，MIT 许可）。下载后在 Packs 目录生成标准语料包。
public struct CorpusSource: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let era: String
    public let script: String
    public let remoteDirectory: String
    public let filePrefix: String
    public let fieldMapping: [String: String]

    public static let chinesePoetryTang = CorpusSource(
        id: "chinese-poetry-tang", name: "唐诗（chinese-poetry）", era: "唐", script: "traditional",
        remoteDirectory: "全唐诗", filePrefix: "poet.tang", fieldMapping: ["lines": "paragraphs"])

    public static let chinesePoetrySongCi = CorpusSource(
        id: "chinese-poetry-songci", name: "宋词（chinese-poetry）", era: "宋", script: "simplified",
        remoteDirectory: "宋词", filePrefix: "ci.song", fieldMapping: ["lines": "paragraphs", "tune": "rhythmic", "title": "rhythmic"])

    public static let all = [chinesePoetryTang, chinesePoetrySongCi]

    static let baseURL = "https://raw.githubusercontent.com/chinese-poetry/chinese-poetry/master"
    static let fileStep = 1_000
    static let maximumFiles = 400

    func fileName(index: Int) -> String { "\(filePrefix).\(index * CorpusSource.fileStep).json" }

    func remoteURL(for fileName: String) -> URL? {
        let path = "\(remoteDirectory)/\(fileName)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        return URL(string: "\(CorpusSource.baseURL)/\(path)")
    }

    public func manifest(files: [String]) -> PackManifest {
        PackManifest(id: id, name: name, version: "1", era: era, script: script, license: "MIT（chinese-poetry 数据集）",
                     source: "https://github.com/chinese-poetry/chinese-poetry \(remoteDirectory)目录",
                     files: files, fieldMapping: fieldMapping)
    }
}

public enum CorpusDownloadError: Error, CustomStringConvertible {
    case badStatus(String, Int)
    case nothingDownloaded(String)

    public var description: String {
        switch self {
        case .badStatus(let file, let status): "下载 \(file) 失败（HTTP \(status)）"
        case .nothingDownloaded(let name): "未能下载 \(name) 的任何文件"
        }
    }
}

public enum CorpusDownloader {
    /// 依次下载 `prefix.0.json`、`prefix.1000.json`……直到返回 404；已存在的文件跳过（可断点续传）。
    /// 返回生成好的语料包目录。
    public static func download(_ source: CorpusSource, into packs: URL, session: URLSession = .shared,
                                progress: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let directory = packs.appendingPathComponent(source.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files: [String] = []
        for index in 0..<CorpusSource.maximumFiles {
            let name = source.fileName(index: index)
            let destination = directory.appendingPathComponent(name)
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 {
                files.append(name)
                continue
            }
            guard let url = source.remoteURL(for: name) else { break }
            progress("\(source.name)：下载第 \(index + 1) 个文件")
            let (temporary, response) = try await session.download(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 404 {
                try? FileManager.default.removeItem(at: temporary)
                break
            }
            guard status == 200 else { throw CorpusDownloadError.badStatus(name, status) }
            try FileManager.default.moveItem(at: temporary, to: destination)
            files.append(name)
        }
        guard !files.isEmpty else { throw CorpusDownloadError.nothingDownloaded(source.name) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(source.manifest(files: files)).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}
