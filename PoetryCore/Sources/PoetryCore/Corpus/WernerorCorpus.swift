import Foundation

/// Werneror/Poetry 古诗词数据（先秦至当代约 85 万首，CSV，仓库标注 MIT 许可，未说明数据来源）。
/// 按时代分为几个语料包；下载后转换为标准语料包。与其他语料包重复的作品由索引去重，优先保留其他语料包的版本。
public struct WernerorSource: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// 语料包的时代标签（各作品另有 CSV 中的朝代）。
    public let era: String
    /// 仓库中的 CSV 文件名（不含扩展名）。
    public let files: [String]
    /// 下载大小（字节，CSV 合计）。
    public let downloadSize: Int
    /// 作品数（据仓库说明）。
    public let workCount: Int

    /// 固定到仓库的某次提交，避免数据变动。
    static let commit = "4cfe49c06858e00d15f84d192fe5294295f79689"
    static let baseURL = "https://raw.githubusercontent.com/Werneror/Poetry/\(commit)"
    public static let repository = "https://github.com/Werneror/Poetry"
    /// 重复作品优先保留其他语料包（缺省 0）的版本。
    static let priority = 10

    public static let all: [WernerorSource] = [
        WernerorSource(id: "werneror-pre-sui", name: "先秦至隋（Werneror）", era: "先秦至隋",
                       files: ["先秦", "秦", "汉", "魏晋", "魏晋末南北朝初", "南北朝", "隋", "隋末唐初"],
                       downloadSize: 2_975_891, workCount: 10_184),
        WernerorSource(id: "werneror-tang", name: "唐五代（Werneror）", era: "唐五代",
                       files: ["唐", "唐末宋初"], downloadSize: 12_487_743, workCount: 50_313),
        WernerorSource(id: "werneror-song", name: "宋（Werneror）", era: "宋",
                       files: ["宋_1", "宋_2", "宋_3", "宋_4", "宋末元初", "宋末金初"], downloadSize: 79_852_918, workCount: 299_406),
        WernerorSource(id: "werneror-liao-jin-yuan", name: "辽金元（Werneror）", era: "辽金元",
                       files: ["辽", "金", "金末元初", "元", "元末明初"], downloadSize: 16_802_203, workCount: 58_893),
        WernerorSource(id: "werneror-ming", name: "明（Werneror）", era: "明",
                       files: ["明_1", "明_2", "明_3", "明_4"], downloadSize: 65_806_766, workCount: 236_957),
        WernerorSource(id: "werneror-qing", name: "清（Werneror）", era: "清",
                       files: ["明末清初", "清_1", "清_2", "清末民国初", "清末近现代初"], downloadSize: 43_535_890, workCount: 135_620),
        WernerorSource(id: "werneror-modern", name: "近现代与当代（Werneror）", era: "近现代",
                       files: ["近现代", "近现代末当代初", "民国末当代初", "当代"], downloadSize: 18_044_929, workCount: 62_012),
    ]

    func remoteURL(for file: String) -> URL? {
        guard let path = "\(file).csv".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(WernerorSource.baseURL)/\(path)")
    }

    public func manifest(files: [String]) -> PackManifest {
        PackManifest(id: id, name: name, version: "1", era: era, script: "simplified",
                     license: "仓库标注 MIT，未说明数据来源", source: "\(WernerorSource.repository)（提交 \(WernerorSource.commit.prefix(7))）",
                     files: files, fieldMapping: ["lines": "paragraphs"], priority: WernerorSource.priority)
    }
}

/// 转换后的一首（写入语料包的 JSON）。
struct WernerorPoem: Codable, Equatable {
    let title: String
    let author: String
    let dynasty: String
    let paragraphs: [String]
}

public enum WernerorError: Error, Equatable, CustomStringConvertible {
    case unexpectedHeader(String)
    case noPoems(String)

    public var description: String {
        switch self {
        case .unexpectedHeader(let file): "\(file) 的表头不是「题目,朝代,作者,内容」"
        case .noPoems(let file): "\(file) 中没有可用的作品"
        }
    }
}

enum WernerorConverter {
    static let header = ["题目", "朝代", "作者", "内容"]
    /// 原数据把 utf8mb4 生僻字替换为「?」，另有「■」与「{訁亞}」式的部件描述；转换时都改为一个缺字符号。
    static let missingCharacter: Character = "□"
    private static let missingMarks: Set<Character> = ["?", "■"]
    /// 部件描述最长的字数（更长的花括号内容不视为一个字）。
    private static let maximumComponentLength = 8
    private static let sentenceEnds: Set<Character> = ["。", "！", "？"]

    static func restoreMissing(_ text: String) -> String {
        var result = ""
        var pending: String?
        for character in text {
            if var component = pending {
                if character == "}" {
                    result.append(missingCharacter)
                    pending = nil
                } else if character == "{" || component.count >= maximumComponentLength {
                    // 不像部件描述：原样保留已读的部分。
                    result += "{" + component
                    pending = character == "{" ? "" : nil
                    if pending == nil { result.append(character) }
                } else {
                    component.append(character)
                    pending = component
                }
            } else if character == "{" {
                pending = ""
            } else {
                result.append(missingMarks.contains(character) ? missingCharacter : character)
            }
        }
        if let component = pending { result += "{" + component }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 按句末标点（。！？）与换行分段，标点留在段末。
    static func paragraphs(of content: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for character in content {
            if character.isNewline {
                flush()
            } else {
                current.append(character)
                if sentenceEnds.contains(character) { flush() }
            }
        }
        flush()
        return result
    }

    /// 解析一个 CSV 文件；列数不对或正文没有汉字的行跳过并计数。
    static func poems(fromCSV data: Data, file: String) throws -> (poems: [WernerorPoem], skipped: Int) {
        let rows = try CSVReader.rows(data)
        guard let first = rows.first, first == header else { throw WernerorError.unexpectedHeader(file) }
        var poems: [WernerorPoem] = []
        var skipped = 0
        for row in rows.dropFirst() {
            guard row.count == header.count else {
                skipped += 1
                continue
            }
            let content = restoreMissing(row[3])
            let paragraphs = paragraphs(of: content)
            guard paragraphs.contains(where: { !TextSegmenter.hanOnly($0).isEmpty }) else {
                skipped += 1
                continue
            }
            poems.append(WernerorPoem(title: restoreMissing(row[0]), author: restoreMissing(row[2]),
                                      dynasty: row[1].trimmingCharacters(in: .whitespaces), paragraphs: paragraphs))
        }
        guard !poems.isEmpty else { throw WernerorError.noPoems(file) }
        return (poems, skipped)
    }
}

public enum WernerorDownloader {
    /// 逐个下载 CSV 并转换为 `<文件名>.json`；已转换的文件跳过（可断点续传）。返回生成好的语料包目录。
    public static func download(_ source: WernerorSource, into packs: URL, session: URLSession = .shared,
                                progress: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let directory = packs.appendingPathComponent(source.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        var files: [String] = []
        for (index, file) in source.files.enumerated() {
            let name = "\(file).json"
            let destination = directory.appendingPathComponent(name)
            files.append(name)
            if let size = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { continue }
            guard let url = source.remoteURL(for: file) else { throw CorpusDownloadError.nothingDownloaded(source.name) }
            progress("\(source.name)：下载 \(file)（\(index + 1)/\(source.files.count)）")
            let (temporary, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw CorpusDownloadError.badStatus("\(file).csv", status) }
            progress("\(source.name)：转换 \(file)（\(index + 1)/\(source.files.count)）")
            let converted = try WernerorConverter.poems(fromCSV: Data(contentsOf: temporary), file: "\(file).csv")
            try encoder.encode(converted.poems).write(to: destination, options: .atomic)
        }
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try manifestEncoder.encode(source.manifest(files: files)).write(to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}
