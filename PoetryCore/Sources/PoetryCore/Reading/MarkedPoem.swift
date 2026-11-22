import Foundation

/// 圈点的种类。圈与点标在字下，同一字只取其一；专名线与书名线画在字下，同一字只取其一。
public enum PoemMarkKind: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    /// 圈「○」：好字、好词；整句连圈即密圈。
    case circle = "圈"
    /// 点「、」：次一等的佳处。
    case dot = "点"
    /// 专名线：人名、地名旁的直线。
    case properName = "专名线"
    /// 书名线：书名、篇名旁的波浪线。
    case bookTitle = "书名线"

    public var id: String { rawValue }

    /// 互斥的一组：同一字同组只能有一种。
    public var isUnderline: Bool { self == .properName || self == .bookTitle }
}

/// 一行中的一段字（按字计，含标点）。
public struct LineRange: Sendable, Hashable, Codable {
    public let line: Int
    public let start: Int
    public let length: Int

    public init(line: Int, start: Int, length: Int) {
        self.line = line
        self.start = start
        self.length = length
    }

    public var end: Int { start + length }

    public func contains(line: Int, offset: Int) -> Bool {
        self.line == line && offset >= start && offset < end
    }
}

/// 一处圈点。
public struct PoemMark: Sendable, Hashable, Codable {
    public let kind: PoemMarkKind
    public let range: LineRange

    public init(kind: PoemMarkKind, range: LineRange) {
        self.kind = kind
        self.range = range
    }
}

/// 一条批注。
public struct PoemNote: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public let range: LineRange
    public var text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), range: LineRange, text: String, createdAt: Date = Date()) {
        self.id = id
        self.range = range
        self.text = text
        self.createdAt = createdAt
    }
}

/// 圈点本的来源。
public enum MarkedPoemOrigin: Sendable, Hashable, Codable {
    /// 语料中的作品（记下语料包名与当时的作品 id，仅作说明；正文已存入圈点本）。
    case corpus(packName: String, workID: Int64)
    /// 自己粘入的文本。
    case pasted
}

/// 圈点本：一首诗词的正文（存一份，语料变动不影响）与其上的圈点、批注。
public struct MarkedPoem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public var title: String
    public var author: String?
    public var dynasty: String?
    public let origin: MarkedPoemOrigin
    /// 正文，按换行分行（只用 `\n`）。
    public let body: String
    public var marks: [PoemMark]
    public var notes: [PoemNote]
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), title: String, author: String? = nil, dynasty: String? = nil, origin: MarkedPoemOrigin,
                body: String, marks: [PoemMark] = [], notes: [PoemNote] = [], createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.author = author
        self.dynasty = dynasty
        self.origin = origin
        self.body = body
        self.marks = marks
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var lines: [String] { MarkedPoem.lines(of: body) }

    public var source: SourceInfo { SourceInfo(author: author, title: title.isEmpty ? nil : title, dynasty: dynasty) }

    static func lines(of body: String) -> [String] {
        body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// 某段字的文本；越界的部分忽略。
    public func text(of range: LineRange) -> String {
        let lines = lines
        guard lines.indices.contains(range.line) else { return "" }
        let characters = Array(lines[range.line])
        let lower = min(max(0, range.start), characters.count)
        let upper = min(max(lower, range.end), characters.count)
        return String(characters[lower..<upper])
    }

    /// 整理粘入的文本：统一换行，去掉各行首尾空白与首尾空行，连续空行并为一行。
    public static func normalizedBody(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result: [String] = []
        for line in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, result.last?.isEmpty ?? true { continue }
            result.append(trimmed)
        }
        while result.last?.isEmpty == true { result.removeLast() }
        return result.joined(separator: "\n")
    }
}

/// 圈点的增删（纯函数）。
public enum PoemMarking {
    /// 把 `range` 限制在正文之内；行号越界或长度为零时为 nil。
    public static func clamped(_ range: LineRange, in lines: [String]) -> LineRange? {
        guard lines.indices.contains(range.line) else { return nil }
        let count = lines[range.line].count
        let start = min(max(0, range.start), count)
        let end = min(max(start, range.end), count)
        guard end > start else { return nil }
        return LineRange(line: range.line, start: start, length: end - start)
    }

    /// 加一种圈点：同组的旧圈点在此范围内的部分被替换；若范围内的字已全是这一种，则改为去掉（再按一次即取消）。
    public static func apply(_ kind: PoemMarkKind, to range: LineRange, in marks: [PoemMark]) -> [PoemMark] {
        let sameGroup = { (mark: PoemMark) in mark.kind.isUnderline == kind.isUnderline }
        let trimmed = trim(marks, outOf: range, where: sameGroup)
        if isCovered(range, by: kind, in: marks) { return sorted(trimmed) }
        return sorted(trimmed + [PoemMark(kind: kind, range: range)])
    }

    /// 去掉范围内的所有圈点。
    public static func erase(_ range: LineRange, in marks: [PoemMark]) -> [PoemMark] {
        sorted(trim(marks, outOf: range) { _ in true })
    }

    /// 范围内的每个字是否都已有这种圈点。
    static func isCovered(_ range: LineRange, by kind: PoemMarkKind, in marks: [PoemMark]) -> Bool {
        guard range.length > 0 else { return false }
        return (range.start..<range.end).allSatisfy { offset in
            marks.contains { $0.kind == kind && $0.range.contains(line: range.line, offset: offset) }
        }
    }

    /// 把符合条件的圈点中落在 `range` 内的部分切掉，两侧余下的部分保留为各自的圈点。
    private static func trim(_ marks: [PoemMark], outOf range: LineRange, where matches: (PoemMark) -> Bool) -> [PoemMark] {
        marks.flatMap { mark -> [PoemMark] in
            let current = mark.range
            guard matches(mark), current.line == range.line, current.start < range.end, range.start < current.end else { return [mark] }
            var pieces: [PoemMark] = []
            if current.start < range.start {
                pieces.append(PoemMark(kind: mark.kind, range: LineRange(line: current.line, start: current.start,
                                                                         length: range.start - current.start)))
            }
            if range.end < current.end {
                pieces.append(PoemMark(kind: mark.kind, range: LineRange(line: current.line, start: range.end,
                                                                         length: current.end - range.end)))
            }
            return pieces
        }
    }

    private static func sorted(_ marks: [PoemMark]) -> [PoemMark] {
        marks.sorted { ($0.range.line, $0.range.start, $0.kind.rawValue) < ($1.range.line, $1.range.start, $1.kind.rawValue) }
    }

    /// 某字所在的分句（前后到非汉字为止）；该字不是汉字时为 nil。
    public static func clause(in lines: [String], line: Int, offset: Int) -> LineRange? {
        guard lines.indices.contains(line) else { return nil }
        let characters = Array(lines[line])
        guard characters.indices.contains(offset), TextSegmenter.isHan(characters[offset]) else { return nil }
        var start = offset
        while start > 0, TextSegmenter.isHan(characters[start - 1]) { start -= 1 }
        var end = offset + 1
        while end < characters.count, TextSegmenter.isHan(characters[end]) { end += 1 }
        return LineRange(line: line, start: start, length: end - start)
    }

    /// 拖选的范围：限于起点所在的一行；终点在别的行时取到行首或行尾。起点行号越界时为 nil。
    public static func selection(from start: CharacterSlot, to end: CharacterSlot, in lines: [String]) -> LineRange? {
        guard lines.indices.contains(start.line) else { return nil }
        let count = lines[start.line].count
        guard count > 0 else { return nil }
        let anchor = min(max(0, start.offset), count - 1)
        let target: Int
        if end.line > start.line {
            target = count - 1
        } else if end.line < start.line {
            target = 0
        } else {
            target = min(max(0, end.offset), count - 1)
        }
        let lower = min(anchor, target)
        return LineRange(line: start.line, start: lower, length: max(anchor, target) - lower + 1)
    }

    /// 各字上的圈点，键为（行，字序）。
    public static func marksByCharacter(_ marks: [PoemMark]) -> [CharacterSlot: [PoemMarkKind]] {
        var result: [CharacterSlot: [PoemMarkKind]] = [:]
        for mark in marks {
            for offset in mark.range.start..<mark.range.end {
                result[CharacterSlot(line: mark.range.line, offset: offset), default: []].append(mark.kind)
            }
        }
        return result
    }
}

/// 正文中一个字的位置。
public struct CharacterSlot: Sendable, Hashable, Comparable {
    public let line: Int
    public let offset: Int

    public init(line: Int, offset: Int) {
        self.line = line
        self.offset = offset
    }

    public static func < (lhs: CharacterSlot, rhs: CharacterSlot) -> Bool {
        (lhs.line, lhs.offset) < (rhs.line, rhs.offset)
    }
}

/// 读诗页的逐字排版：每字一格，一行放不下时折行；标点不放在折行后的行首，而是悬挂在上一行末尾。空行占较小的厚度。
/// 横排时各行自上而下；竖排时一行排成一列，各列自右向左。
public enum MarkedPoemLayout {
    public struct Metrics: Sendable, Hashable {
        /// 沿行的方向每字所占的长度（横排为宽，竖排为高）。
        public let cellWidth: Double
        /// 一行所占的厚度（横排为行高，竖排为列宽）。
        public let rowHeight: Double
        public let emptyLineHeight: Double
        public let isVertical: Bool

        public init(cellWidth: Double, rowHeight: Double, emptyLineHeight: Double, isVertical: Bool = false) {
            self.cellWidth = cellWidth
            self.rowHeight = rowHeight
            self.emptyLineHeight = emptyLineHeight
            self.isVertical = isVertical
        }

        /// 一个字格的宽与高。
        public var cellSize: (width: Double, height: Double) {
            isVertical ? (rowHeight, cellWidth) : (cellWidth, rowHeight)
        }
    }

    public struct Cell: Sendable, Hashable {
        public let slot: CharacterSlot
        public let x: Double
        public let y: Double
    }

    /// 按最长一行定字格长度：放得下时取上限，否则缩小，但不小于下限（再放不下就折行）。
    /// `length` 为沿行方向的可用长度（横排为宽，竖排为高）；其中留一格给悬挂的标点，故按「最长一行的字数」均分。
    public static func fittedCellWidth(width length: Double, lines: [String], range: ClosedRange<Double>) -> Double {
        let longest = lines.map(\.count).max() ?? 0
        guard longest > 0, length > 0 else { return range.upperBound }
        return min(max(length / Double(longest), range.lowerBound), range.upperBound)
    }

    /// 各字格子的左上角，与各行合计的厚度（横排为总高，竖排为总宽）。
    /// `length` 为沿行方向的可用长度；竖排时第一列贴在总宽的最右边。
    public static func layout(lines: [String], length: Double, metrics: Metrics) -> (cells: [Cell], extent: Double) {
        // 加一点余量，免得浮点误差让恰好放得下的一行少放一字。
        let perRow = max(1, Int(length / metrics.cellWidth + 1e-9))
        var placed: [(slot: CharacterSlot, along: Double, across: Double)] = []
        var across = 0.0
        for (lineIndex, line) in lines.enumerated() {
            guard !line.isEmpty else {
                across += metrics.emptyLineHeight
                continue
            }
            var row = 0
            var column = 0
            for (offset, character) in line.enumerated() {
                if column >= perRow {
                    if !TextSegmenter.isHan(character), column == perRow {
                        // 悬挂：标点留在本行行尾之外。
                        placed.append((CharacterSlot(line: lineIndex, offset: offset), Double(column) * metrics.cellWidth,
                                       across + Double(row) * metrics.rowHeight))
                        column += 1
                        continue
                    }
                    row += 1
                    column = 0
                }
                placed.append((CharacterSlot(line: lineIndex, offset: offset), Double(column) * metrics.cellWidth,
                               across + Double(row) * metrics.rowHeight))
                column += 1
            }
            across += Double(row + 1) * metrics.rowHeight
        }
        let extent = across
        let cells = placed.map { item in
            metrics.isVertical
                ? Cell(slot: item.slot, x: extent - item.across - metrics.rowHeight, y: item.along)
                : Cell(slot: item.slot, x: item.along, y: item.across)
        }
        return (cells, extent)
    }

    /// 点在哪个字的格子里；不在任何格子里时为 nil。
    public static func slot(at point: (x: Double, y: Double), in cells: [Cell], metrics: Metrics) -> CharacterSlot? {
        let size = metrics.cellSize
        return cells.first { cell in
            point.x >= cell.x && point.x < cell.x + size.width && point.y >= cell.y && point.y < cell.y + size.height
        }?.slot
    }

    /// 竖排时标点的字形（如「，」作「︐」）；没有竖排字形的字原样返回。
    public static func verticalForm(of character: Character) -> Character {
        verticalForms[character] ?? character
    }

    private static let verticalForms: [Character: Character] = [
        "，": "︐", "。": "︒", "、": "︑", "：": "︓", "；": "︔", "！": "︕", "？": "︖",
        "「": "﹁", "」": "﹂", "『": "﹃", "』": "﹄", "《": "︽", "》": "︾", "〈": "︿", "〉": "﹀",
        "（": "︵", "）": "︶", "【": "︻", "】": "︼", "〔": "︹", "〕": "︺", "…": "︙", "—": "︱",
    ]
}

public enum MarkedPoemError: Error, Equatable, CustomStringConvertible {
    case emptyNote
    case invalidRange
    case noteNotFound

    public var description: String {
        switch self {
        case .emptyNote: "批注内容为空"
        case .invalidRange: "所选位置不在正文中"
        case .noteNotFound: "找不到这条批注"
        }
    }
}

extension MarkedPoem {
    /// 在所选范围加一种圈点（再按一次取消）；范围越界的部分忽略。
    public mutating func applyMark(_ kind: PoemMarkKind, to range: LineRange) throws {
        guard let range = PoemMarking.clamped(range, in: lines) else { throw MarkedPoemError.invalidRange }
        marks = PoemMarking.apply(kind, to: range, in: marks)
    }

    /// 去掉所选范围内的圈点。
    public mutating func eraseMarks(in range: LineRange) throws {
        guard let range = PoemMarking.clamped(range, in: lines) else { throw MarkedPoemError.invalidRange }
        marks = PoemMarking.erase(range, in: marks)
    }

    /// 加一条批注，按位置排序；返回新批注。
    @discardableResult
    public mutating func addNote(_ text: String, to range: LineRange, now: Date = Date()) throws -> PoemNote {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MarkedPoemError.emptyNote }
        guard let range = PoemMarking.clamped(range, in: lines) else { throw MarkedPoemError.invalidRange }
        let note = PoemNote(range: range, text: trimmed, createdAt: now)
        notes.append(note)
        notes.sort { ($0.range.line, $0.range.start, $0.createdAt) < ($1.range.line, $1.range.start, $1.createdAt) }
        return note
    }

    /// 修改批注；内容为空时报错（删除请用 `removeNote`）。
    public mutating func updateNote(id: UUID, text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MarkedPoemError.emptyNote }
        guard let index = notes.firstIndex(where: { $0.id == id }) else { throw MarkedPoemError.noteNotFound }
        notes[index].text = trimmed
    }

    public mutating func removeNote(id: UUID) throws {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { throw MarkedPoemError.noteNotFound }
        notes.remove(at: index)
    }

    /// 覆盖某字的批注。
    public func notes(at slot: CharacterSlot) -> [PoemNote] {
        notes.filter { $0.range.contains(line: slot.line, offset: slot.offset) }
    }
}
