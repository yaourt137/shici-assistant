import Foundation
import Testing
@testable import PoetryCore

private func range(_ line: Int, _ start: Int, _ length: Int) -> LineRange {
    LineRange(line: line, start: start, length: length)
}

private func mark(_ kind: PoemMarkKind, _ line: Int, _ start: Int, _ length: Int) -> PoemMark {
    PoemMark(kind: kind, range: range(line, start, length))
}

@Suite("圈点")
struct PoemMarkingTests {
    @Test("加圈点：同组替换，异组并存；全已是同一种时取消")
    func apply() {
        var marks = PoemMarking.apply(.circle, to: range(0, 0, 5), in: [])
        #expect(marks == [mark(.circle, 0, 0, 5)])
        marks = PoemMarking.apply(.dot, to: range(0, 1, 2), in: marks)
        #expect(marks == [mark(.circle, 0, 0, 1), mark(.dot, 0, 1, 2), mark(.circle, 0, 3, 2)], "点替换中间的圈，两侧留下")
        marks = PoemMarking.apply(.properName, to: range(0, 0, 2), in: marks)
        #expect(marks.contains(mark(.properName, 0, 0, 2)))
        #expect(marks.contains(mark(.dot, 0, 1, 2)), "专名线与圈点不同组，并存")
        marks = PoemMarking.apply(.dot, to: range(0, 1, 2), in: marks)
        #expect(!marks.contains { $0.kind == .dot }, "再按一次取消")
        #expect(marks.contains(mark(.circle, 0, 0, 1)) && marks.contains(mark(.circle, 0, 3, 2)), "取消时不动其他圈")
    }

    @Test("部分已有同种圈点时补全而不是取消；不同行互不影响")
    func partialAndLines() {
        var marks = [mark(.circle, 0, 0, 2), mark(.circle, 1, 0, 5)]
        marks = PoemMarking.apply(.circle, to: range(0, 0, 4), in: marks)
        #expect(marks == [mark(.circle, 0, 0, 4), mark(.circle, 1, 0, 5)])
        let names = PoemMarking.apply(.properName, to: range(0, 2, 2), in: [mark(.properName, 0, 0, 2)])
        #expect(names == [mark(.properName, 0, 0, 2), mark(.properName, 0, 2, 2)], "相邻的两个专名各自成段，不合并")
        let title = PoemMarking.apply(.bookTitle, to: range(0, 1, 2), in: names)
        #expect(title == [mark(.properName, 0, 0, 1), mark(.bookTitle, 0, 1, 2), mark(.properName, 0, 3, 1)])
    }

    @Test("擦除：去掉范围内的所有圈点，切开跨界的")
    func erase() {
        let marks = [mark(.circle, 0, 0, 5), mark(.properName, 0, 2, 3), mark(.dot, 1, 0, 2)]
        #expect(Set(PoemMarking.erase(range(0, 1, 2), in: marks))
                == [mark(.circle, 0, 0, 1), mark(.circle, 0, 3, 2), mark(.properName, 0, 3, 2), mark(.dot, 1, 0, 2)])
        #expect(PoemMarking.erase(range(0, 0, 9), in: marks) == [mark(.dot, 1, 0, 2)])
        #expect(PoemMarking.erase(range(2, 0, 1), in: marks).count == 3, "没有圈点的行")
    }

    @Test("范围限制在正文内")
    func clamp() {
        let lines = ["白日依山盡，", "", "黃河入海流。"]
        #expect(PoemMarking.clamped(range(0, 3, 10), in: lines) == range(0, 3, 3))
        #expect(PoemMarking.clamped(range(0, -2, 3), in: lines) == range(0, 0, 1))
        #expect(PoemMarking.clamped(range(1, 0, 1), in: lines) == nil, "空行")
        #expect(PoemMarking.clamped(range(3, 0, 1), in: lines) == nil, "行号越界")
        #expect(PoemMarking.clamped(range(0, 2, 0), in: lines) == nil, "长度为零")
        #expect(PoemMarking.clamped(range(0, 6, 2), in: lines) == nil, "起点在行尾之后")
    }

    @Test("分句：前后到标点为止；标点上为 nil")
    func clause() {
        let lines = ["白日依山盡，黃河入海流。", "欲窮千里目"]
        #expect(PoemMarking.clause(in: lines, line: 0, offset: 2) == range(0, 0, 5))
        #expect(PoemMarking.clause(in: lines, line: 0, offset: 6) == range(0, 6, 5))
        #expect(PoemMarking.clause(in: lines, line: 0, offset: 5) == nil, "逗号")
        #expect(PoemMarking.clause(in: lines, line: 1, offset: 4) == range(1, 0, 5), "行尾没有标点")
        #expect(PoemMarking.clause(in: lines, line: 1, offset: 5) == nil)
        #expect(PoemMarking.clause(in: lines, line: 2, offset: 0) == nil)
    }

    @Test("拖选：限于起点所在行，可向前拖")
    func selection() {
        let lines = ["白日依山盡，", "黃河入海流。", ""]
        let slot = { (line: Int, offset: Int) in CharacterSlot(line: line, offset: offset) }
        #expect(PoemMarking.selection(from: slot(0, 1), to: slot(0, 3), in: lines) == range(0, 1, 3))
        #expect(PoemMarking.selection(from: slot(0, 3), to: slot(0, 1), in: lines) == range(0, 1, 3), "向前拖")
        #expect(PoemMarking.selection(from: slot(0, 2), to: slot(0, 2), in: lines) == range(0, 2, 1), "单字")
        #expect(PoemMarking.selection(from: slot(0, 2), to: slot(1, 0), in: lines) == range(0, 2, 4), "拖到下一行取到行尾")
        #expect(PoemMarking.selection(from: slot(1, 2), to: slot(0, 5), in: lines) == range(1, 0, 3), "拖到上一行取到行首")
        #expect(PoemMarking.selection(from: slot(0, 9), to: slot(0, 0), in: lines) == range(0, 0, 6), "越界的字序限制在行内")
        #expect(PoemMarking.selection(from: slot(2, 0), to: slot(2, 0), in: lines) == nil, "空行")
        #expect(PoemMarking.selection(from: slot(5, 0), to: slot(5, 0), in: lines) == nil)
    }

    @Test("各字上的圈点")
    func byCharacter() {
        let map = PoemMarking.marksByCharacter([mark(.circle, 0, 0, 2), mark(.properName, 0, 1, 2)])
        #expect(map[CharacterSlot(line: 0, offset: 0)] == [.circle])
        #expect(Set(map[CharacterSlot(line: 0, offset: 1)] ?? []) == [.circle, .properName])
        #expect(map[CharacterSlot(line: 0, offset: 2)] == [.properName])
        #expect(map[CharacterSlot(line: 0, offset: 3)] == nil)
    }
}

@Suite("圈点本")
struct MarkedPoemTests {
    private func poem() -> MarkedPoem {
        MarkedPoem(title: "登鸛雀樓", author: "王之渙", dynasty: "唐", origin: .pasted, body: "白日依山盡，黃河入海流。\n欲窮千里目，更上一層樓。")
    }

    @Test("整理粘入的文本")
    func normalize() {
        #expect(MarkedPoem.normalizedBody("  白日依山盡，\r\n\r\n\r\n　黃河入海流。 \r更上一層樓。\n\n") == "白日依山盡，\n\n黃河入海流。\n更上一層樓。")
        #expect(MarkedPoem.normalizedBody("\n\n  \n") == "")
        #expect(MarkedPoem.normalizedBody("") == "")
    }

    @Test("取一段字；越界部分忽略")
    func text() {
        let poem = poem()
        #expect(poem.lines.count == 2)
        #expect(poem.text(of: range(1, 0, 5)) == "欲窮千里目")
        #expect(poem.text(of: range(1, 9, 9)) == "層樓。")
        #expect(poem.text(of: range(5, 0, 1)) == "")
        #expect(poem.text(of: range(0, -3, 4)) == "白")
        #expect(poem.source.summary == "〔唐〕王之渙《登鸛雀樓》")
    }

    @Test("圈点与擦除：越界报错")
    func marks() throws {
        var poem = poem()
        try poem.applyMark(.circle, to: range(1, 6, 99))
        #expect(poem.marks == [mark(.circle, 1, 6, 6)], "限制到行尾")
        try poem.eraseMarks(in: range(1, 0, 8))
        #expect(poem.marks == [mark(.circle, 1, 8, 4)])
        #expect(throws: MarkedPoemError.invalidRange) { try poem.applyMark(.dot, to: range(2, 0, 1)) }
        #expect(throws: MarkedPoemError.invalidRange) { try poem.eraseMarks(in: range(0, 0, 0)) }
    }

    @Test("批注：按位置排序，可改可删；内容为空或找不到时报错")
    func notes() throws {
        var poem = poem()
        let now = Date(timeIntervalSince1970: 100)
        let later = try poem.addNote("  寫景  ", to: range(1, 0, 5), now: now)
        let first = try poem.addNote("起句", to: range(0, 0, 5), now: now)
        #expect(poem.notes.map(\.id) == [first.id, later.id])
        #expect(later.text == "寫景")
        #expect(poem.notes(at: CharacterSlot(line: 1, offset: 4)).map(\.id) == [later.id])
        #expect(poem.notes(at: CharacterSlot(line: 1, offset: 5)).isEmpty)
        try poem.updateNote(id: later.id, text: "登高望遠")
        #expect(poem.notes.last?.text == "登高望遠")
        #expect(throws: MarkedPoemError.emptyNote) { try poem.updateNote(id: later.id, text: " \n") }
        #expect(throws: MarkedPoemError.emptyNote) { try poem.addNote("", to: range(0, 0, 1)) }
        #expect(throws: MarkedPoemError.invalidRange) { try poem.addNote("x", to: range(9, 0, 1)) }
        try poem.removeNote(id: first.id)
        #expect(poem.notes.map(\.id) == [later.id])
        #expect(throws: MarkedPoemError.noteNotFound) { try poem.removeNote(id: first.id) }
        #expect(throws: MarkedPoemError.noteNotFound) { try poem.updateNote(id: UUID(), text: "x") }
    }
}

@Suite("读诗排版")
struct MarkedPoemLayoutTests {
    private let metrics = MarkedPoemLayout.Metrics(cellWidth: 10, rowHeight: 20, emptyLineHeight: 5)

    @Test("每字一格，放不下时折行；空行占较小高度")
    func layout() {
        let result = MarkedPoemLayout.layout(lines: ["甲乙丙", "", "丁戊己庚辛"], length: 35, metrics: metrics)
        #expect(result.cells.count == 8)
        #expect(result.cells[2].x == 20 && result.cells[2].y == 0)
        #expect(result.cells[3].slot == CharacterSlot(line: 2, offset: 0))
        #expect(result.cells[3].y == 25, "第一行 20 加空行 5")
        #expect(result.cells[6].x == 0 && result.cells[6].y == 45, "第三格后折行")
        #expect(result.extent == 65)
    }

    @Test("标点不放在行首：悬挂在上一行末尾，只悬挂一个")
    func hangingPunctuation() {
        let result = MarkedPoemLayout.layout(lines: ["甲乙丙，丁戊。。"], length: 30, metrics: metrics)
        #expect(result.cells[3].x == 30 && result.cells[3].y == 0, "逗号悬挂在第一行之外")
        #expect(result.cells[4].x == 0 && result.cells[4].y == 20, "丁在第二行行首")
        #expect(result.cells[6].x == 20 && result.cells[6].y == 20, "第二行未满，句号照常排")
        #expect(result.cells[7].x == 30 && result.cells[7].y == 20, "第二个句号悬挂")
        #expect(result.extent == 40)
        let double = MarkedPoemLayout.layout(lines: ["甲乙丙，。丁"], length: 30, metrics: metrics)
        #expect(double.cells[4].x == 0 && double.cells[4].y == 20, "连续两个标点只悬挂一个")
        #expect(double.extent == 40)
    }

    @Test("字格宽度按最长一行缩放，限于上下限之间")
    func fittedCellWidth() {
        let fit = { (width: Double, lines: [String]) in MarkedPoemLayout.fittedCellWidth(width: width, lines: lines, range: 26...34) }
        #expect(fit(800, ["鳳凰臺上鳳凰遊，鳳去臺空江自流。"]) == 34, "放得下取上限")
        #expect(fit(480, ["鳳凰臺上鳳凰遊，鳳去臺空江自流。"]) == 30, "480 / 16")
        #expect(fit(300, ["鳳凰臺上鳳凰遊，鳳去臺空江自流。"]) == 26, "不小于下限")
        #expect(fit(300, []) == 34)
        #expect(fit(300, ["", ""]) == 34, "只有空行")
        #expect(fit(0, ["甲"]) == 34)
    }

    @Test("宽度不足一格时每行一字；没有正文时高度为零")
    func narrow() {
        let result = MarkedPoemLayout.layout(lines: ["甲乙"], length: 3, metrics: metrics)
        #expect(result.cells.map(\.y) == [0, 20])
        #expect(MarkedPoemLayout.layout(lines: [], length: 100, metrics: metrics).extent == 0)
    }

    @Test("竖排：一行一列，自右向左；折行另起一列；点击按竖排格子定位")
    func vertical() {
        let vertical = MarkedPoemLayout.Metrics(cellWidth: 10, rowHeight: 20, emptyLineHeight: 5, isVertical: true)
        let result = MarkedPoemLayout.layout(lines: ["甲乙丙", "", "丁戊己庚"], length: 30, metrics: vertical)
        #expect(result.extent == 65, "两列 20、一列折行 20、空行 5")
        #expect(result.cells[0].x == 45 && result.cells[0].y == 0, "第一列贴最右")
        #expect(result.cells[2].x == 45 && result.cells[2].y == 20)
        #expect(result.cells[3].x == 20 && result.cells[3].y == 0, "空行之后的第一列")
        #expect(result.cells[6].x == 0 && result.cells[6].y == 0, "庚折到下一列（更靠左）")
        #expect(vertical.cellSize.width == 20 && vertical.cellSize.height == 10)
        #expect(MarkedPoemLayout.slot(at: (x: 50, y: 15), in: result.cells, metrics: vertical) == CharacterSlot(line: 0, offset: 1))
        #expect(MarkedPoemLayout.slot(at: (x: 50, y: 31), in: result.cells, metrics: vertical) == nil, "列尾之下")
        let hanging = MarkedPoemLayout.layout(lines: ["甲乙，丙"], length: 20, metrics: vertical)
        #expect(hanging.cells[2].x == 20 && hanging.cells[2].y == 20, "竖排同样悬挂标点")
        #expect(hanging.cells[3].x == 0 && hanging.cells[3].y == 0)
    }

    @Test("竖排标点字形")
    func verticalForms() {
        #expect(MarkedPoemLayout.verticalForm(of: "，") == "︐")
        #expect(MarkedPoemLayout.verticalForm(of: "。") == "︒")
        #expect(MarkedPoemLayout.verticalForm(of: "「") == "﹁")
        #expect(MarkedPoemLayout.verticalForm(of: "《") == "︽")
        #expect(MarkedPoemLayout.verticalForm(of: "月") == "月", "汉字不变")
        #expect(MarkedPoemLayout.verticalForm(of: "a") == "a")
    }

    @Test("点击定位到字；格子外为 nil")
    func hitTest() {
        let cells = MarkedPoemLayout.layout(lines: ["甲乙丙", "丁"], length: 100, metrics: metrics).cells
        #expect(MarkedPoemLayout.slot(at: (x: 15, y: 5), in: cells, metrics: metrics) == CharacterSlot(line: 0, offset: 1))
        #expect(MarkedPoemLayout.slot(at: (x: 0, y: 20), in: cells, metrics: metrics) == CharacterSlot(line: 1, offset: 0))
        #expect(MarkedPoemLayout.slot(at: (x: 35, y: 5), in: cells, metrics: metrics) == nil, "行尾之外")
        #expect(MarkedPoemLayout.slot(at: (x: -1, y: 5), in: cells, metrics: metrics) == nil)
        #expect(MarkedPoemLayout.slot(at: (x: 5, y: 45), in: cells, metrics: metrics) == nil)
    }
}

@Suite("圈点本存取")
struct MarkedPoemStoreTests {
    private func makeService(_ directory: TemporaryDirectory) throws -> PoetryService {
        try PoetryService(paths: AppPaths(root: directory.url.appendingPathComponent("data")))
    }

    @Test("从语料打开：用原书字形，再次打开沿用同一本并更新阅读时间")
    func openFromCorpus() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        _ = try await service.installPack(from: try DrillFixtures.makePack(in: directory))
        let line = try #require(try await service.corpus.usages(of: "明月松间照").first)
        let first = try await service.openMarkedPoem(corpusWorkID: line.workID, now: Date(timeIntervalSince1970: 10))
        #expect(first.title == "山居秋暝")
        #expect(first.author == "王維" || first.author == "王维")
        #expect(first.body.contains("明月松間照"), "原书字形")
        #expect(first.lines.count == 4)
        if case .corpus(let packName, let workID) = first.origin {
            #expect(packName == "对仗测试")
            #expect(workID == line.workID)
        } else {
            Issue.record("来源应为语料")
        }

        var marked = first
        try marked.applyMark(.circle, to: LineRange(line: 1, start: 0, length: 5))
        try service.library.save(marked)
        let again = try await service.openMarkedPoem(corpusWorkID: line.workID, now: Date(timeIntervalSince1970: 20))
        #expect(again.id == first.id)
        #expect(again.marks == marked.marks)
        #expect(again.updatedAt == Date(timeIntervalSince1970: 20))
        #expect(try service.library.markedPoems().count == 1)

        await #expect(throws: LibraryError.notFound("语料作品 99999")) { try await service.openMarkedPoem(corpusWorkID: 99_999) }
    }

    @Test("粘入：整理正文，空字段为 nil；没有汉字时报错")
    func paste() throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        let poem = try service.createMarkedPoem(title: "  ", author: " 佚名 ", dynasty: "", text: "  床前明月光，\r\n疑是地上霜。\n\n\n",
                                             now: Date(timeIntervalSince1970: 5))
        #expect(poem.title == "")
        #expect(poem.author == "佚名")
        #expect(poem.dynasty == nil)
        #expect(poem.body == "床前明月光，\n疑是地上霜。")
        #expect(poem.origin == .pasted)
        #expect(try service.library.markedPoem(id: poem.id) == poem)
        #expect(throws: LibraryError.emptyText) { try service.createMarkedPoem(title: "x", author: nil, dynasty: nil, text: " ，。\n") }
    }

    @Test("存取圈点与批注；最近读过的在前；删除")
    func storage() throws {
        let directory = try TemporaryDirectory()
        let store = try LibraryStore(url: directory.url.appendingPathComponent("library.sqlite"))
        var older = MarkedPoem(title: "甲", origin: .pasted, body: "白日依山盡",
                               createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
        try older.applyMark(.dot, to: LineRange(line: 0, start: 0, length: 2))
        try older.addNote("佳", to: LineRange(line: 0, start: 2, length: 3), now: Date(timeIntervalSince1970: 1))
        let newer = MarkedPoem(title: "乙", author: "某", origin: .corpus(packName: "唐诗", workID: 7), body: "黃河入海流",
                               createdAt: Date(timeIntervalSince1970: 2), updatedAt: Date(timeIntervalSince1970: 2))
        try store.save(older)
        try store.save(newer)
        #expect(try store.markedPoems().map(\.id) == [newer.id, older.id])
        #expect(try store.markedPoem(id: older.id) == older)
        #expect(try store.markedPoem(title: "乙", author: "某", body: "黃河入海流")?.id == newer.id)
        #expect(try store.markedPoem(title: "乙", author: nil, body: "黃河入海流") == nil, "作者不同")
        #expect(try store.markedPoem(title: "甲", author: nil, body: "白日依山盡")?.id == older.id, "作者都为空")

        older.title = "甲二"
        older.updatedAt = Date(timeIntervalSince1970: 3)
        try store.save(older)
        #expect(try store.markedPoems().first?.title == "甲二")
        try store.deleteMarkedPoem(id: older.id)
        #expect(try store.markedPoems().map(\.id) == [newer.id])
        try store.deleteMarkedPoem(id: UUID())
        #expect(try store.markedPoem(id: older.id) == nil)
    }
}
