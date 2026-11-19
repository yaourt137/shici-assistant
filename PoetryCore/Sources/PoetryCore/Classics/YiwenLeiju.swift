import Foundation

/// 《艺文类聚》的一条：「事」为经史子书的引文，「文」为诗赋等作品（`genre` 为文体）。
public struct LeijuEntry: Sendable, Hashable {
    /// 卷序（1...100）。
    public let juan: Int
    /// 部，例如「山部上」。
    public let part: String
    /// 子目，例如「衡山」。
    public let topic: String
    /// 文体（诗、赋、赞……）；「事」为 nil。
    public let genre: String?
    /// 正文（原书字形；夹注以全角括号标出）。
    public let text: String

    public init(juan: Int, part: String, topic: String, genre: String?, text: String) {
        self.juan = juan
        self.part = part
        self.topic = topic
        self.genre = genre
        self.text = text
    }

    /// 出处与正文：引文多以「某书曰」「某朝某人某篇曰」起首，在前 40 字内的第一个「曰」处分开。
    public var attributionAndBody: (attribution: String?, body: String) {
        let characters = Array(text)
        guard let index = characters.prefix(40).firstIndex(of: "曰"), index > 0 else { return (nil, text) }
        return (String(characters[..<index]), String(characters[(index + 1)...]))
    }
}

/// 《艺文类聚》漢リポ文本（KR3k0003）的解析。
///
/// 每卷一部（或数部），部名缩进一格，部下分子目；子目标题缩进两格，引文顶格。原书引文各自另起一行，
/// 文本按版面每行 21 字折行，因此不满一行的行视为一条引文的结尾。满 20 字的行可能是结尾，
/// 也可能是含异体字的满行：下一行开头 12 字内出现「曰」时视为新引文。
/// 「文」的部分以文体名起首（如「詩晉庾闡登楚山詩曰」），之后各条沿用该文体，直到子目结束。
public enum LeijuParser {
    public struct Result: Sendable {
        public let entries: [LeijuEntry]
        /// 不在任何子目下的引文数。
        public let skipped: Int
    }

    static let fullLineWidth = 21

    /// 文体名，长者在前以便优先匹配。
    static let genres: [String] = [
        "哀䇿文", "哀策文", "謚策文", "放生碑", "䇿文", "策文", "哀策", "哀辭", "祭文", "弔文", "墓誌", "墓志", "行狀",
        "檄文", "移文", "書奏", "寺碑", "連珠", "樂府", "啓事",
        "賦", "詩", "賛", "贊", "表", "銘", "啓", "唘", "啟", "頌", "書", "論", "箴", "序", "叙", "碑", "誄", "文", "誌",
        "詔", "議", "教", "敎", "牋", "箋", "述", "章", "令", "狀", "奏", "謳", "謌", "歌", "吟", "誡", "戒", "訓", "傳",
        "解", "疏", "歎", "譏", "弔", "敕", "勑", "記", "誥", "策", "難", "檄", "詠", "引", "勢", "說", "説", "志", "七",
        "移", "彈", "對",
    ]

    /// 文体名之后须紧接朝代名，才视为「文」的开始。
    static let dynasties: [String] = [
        "後漢", "東晉", "西晉", "後魏", "北魏", "北齊", "後周", "北周",
        "周", "秦", "漢", "魏", "吳", "呉", "吴", "蜀", "晉", "晋", "宋", "齊", "梁", "陳", "隋", "唐", "楚", "古",
    ]

    /// 解析一个卷文件；`juan` 为卷序。提要、序等非正文卷返回空结果。
    public static func parse(_ text: String, juan: Int) -> Result {
        guard let label = KanripoText.property("JUAN", in: text), label.hasPrefix("卷") else {
            return Result(entries: [], skipped: 0)
        }
        var entries: [LeijuEntry] = []
        var skipped = 0
        var part = ""
        var topic: String?
        var genre: String?
        var paragraph = ""

        func endParagraph() {
            let cleaned = clean(paragraph)
            paragraph = ""
            guard !cleaned.isEmpty else { return }
            guard let topic else {
                skipped += 1
                return
            }
            var body = cleaned
            if let (label, rest) = genreLabel(of: cleaned) {
                genre = label
                body = rest
            }
            entries.append(LeijuEntry(juan: juan, part: part, topic: topic, genre: genre, text: body))
        }

        let lines = KanripoText.bodyLines(text)
        for (index, line) in lines.enumerated() {
            let indentation = line.prefix(while: KanripoText.isSpace).count
            let trimmed = KanripoText.trimmingSpaces(line)
            if trimmed.isEmpty || trimmed.hasPrefix("欽定四庫全書") || (trimmed.hasPrefix("藝文類聚") && indentation > 0) {
                endParagraph()
                continue
            }
            if indentation > 0 {
                endParagraph()
                if indentation == 1, let name = partName(trimmed) {
                    part = name
                    topic = nil
                    genre = nil
                } else if trimmed.hasPrefix("(") {
                    // 部名下的子目总目（双行小字）的续行。
                } else if indentation >= 2, trimmed.count <= 12, !trimmed.contains("曰") {
                    topic = trimmed
                    genre = nil
                } else {
                    paragraph = trimmed
                    endParagraph()
                }
                continue
            }
            paragraph += trimmed
            let width = visualWidth(trimmed)
            let next = lines[(index + 1)...].first { !KanripoText.trimmingSpaces($0).isEmpty } ?? ""
            let nextStartsEntry = next.prefix(12).contains("曰")
            let continues = width >= fullLineWidth || (width == fullLineWidth - 1 && !nextStartsEntry)
            if !continues { endParagraph() }
        }
        endParagraph()
        return Result(entries: entries, skipped: skipped)
    }

    /// 部名行：部名后接子目总目（双行小字），例如「山部上(總載山/衡山)　(崑崙山/廬山)」取「山部上」。
    /// 个别卷的部名不带「部」字（如「歳時下」「内典上」），因此以「名称 + 总目」的版式判断；
    /// 只有一个子目的部没有总目（如「后妃部」），此时须含「部」字。
    static func partName(_ line: String) -> String? {
        let name: String
        if let open = line.firstIndex(of: "(") {
            name = KanripoText.trimmingSpaces(line[..<open])
        } else {
            guard line.contains("部") else { return nil }
            name = KanripoText.trimmingSpaces(line)
        }
        guard !name.isEmpty, name.count <= 8, !name.contains("曰") else { return nil }
        return name
    }

    /// 版面宽度：夹注的双行小字按较长一行计。
    static func visualWidth(_ line: String) -> Int {
        var width = 0
        var note = ""
        var depth = 0
        for character in line {
            if character == "(" {
                depth += 1
                if depth == 1 { note = "" } else { note.append(character) }
            } else if character == ")", depth > 0 {
                depth -= 1
                if depth == 0 {
                    width += note.split(separator: "/", omittingEmptySubsequences: false).map(\.count).max() ?? 0
                } else {
                    note.append(character)
                }
            } else if depth > 0 {
                note.append(character)
            } else {
                width += 1
            }
        }
        if depth > 0 { width += note.count }
        return width
    }

    /// 文体名起首且其后紧接朝代名时，返回文体与去掉文体名后的正文。
    static func genreLabel(of text: String) -> (String, String)? {
        for label in genres where text.hasPrefix(label) {
            let rest = String(text.dropFirst(label.count))
            if dynasties.contains(where: rest.hasPrefix) { return (label, rest) }
        }
        return nil
    }

    /// 夹注合并双行、改用全角括号。
    static func clean(_ text: String) -> String {
        KanripoText.joinColumns(text).replacingOccurrences(of: "(", with: "（").replacingOccurrences(of: ")", with: "）")
    }
}
