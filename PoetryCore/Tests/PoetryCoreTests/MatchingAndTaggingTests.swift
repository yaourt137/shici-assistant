import Foundation
import Testing
@testable import PoetryCore

@Suite("槽位约束")
struct MatchingTests {
    let dictionary = CharDictionary.shared

    @Test("平仄与韵脚过滤")
    func accepts() {
        let xian = RhymeKey(book: .pingshui, id: 15)  // 下平·一先
        let constraint = SlotConstraint(slots: [.ping, .ze, .ping], rhyme: RhymeRequirement(key: xian, tone: .ping), book: .pingshui)
        #expect(constraint.accepts("春月天", dictionary: dictionary))
        #expect(!constraint.accepts("春月东", dictionary: dictionary))   // 东不在先韵
        #expect(!constraint.accepts("月月天", dictionary: dictionary))   // 首字应平
        #expect(!constraint.accepts("春月", dictionary: dictionary))     // 字数不符
        #expect(constraint.accepts("春，月天", dictionary: dictionary))   // 标点不计
        #expect(constraint.patternText == "平仄平")
    }

    @Test("未收录字只能落在中位")
    func unknownCharacter() {
        let any = SlotConstraint(slots: [.any], rhyme: nil, book: .pingshui)
        let ping = SlotConstraint(slots: [.ping], rhyme: nil, book: .pingshui)
        #expect(any.accepts("𠀋", dictionary: dictionary))
        #expect(!ping.accepts("𠀋", dictionary: dictionary))
    }

    @Test("位掩码")
    func masks() {
        let masks = ToneMasks.of(Array("春月看"), book: .pingshui, dictionary: dictionary)
        #expect(masks.ping == 0b101)
        #expect(masks.ze == 0b110)
        let constraint = SlotConstraint(slots: [.ping, .ze, .any], rhyme: nil, book: .pingshui)
        #expect(constraint.requiredMasks == ToneMasks(ping: 0b001, ze: 0b010))
        #expect(masks.satisfies(constraint.requiredMasks))
        #expect(!ToneMasks(ping: 0, ze: 0b111).satisfies(constraint.requiredMasks))
    }

    @Test("由分析结果生成约束")
    func fromAnalysis() throws {
        let analysis = PoemAnalyzer().analyze("白雪春山落，春花落月天。春山花落雪，白雪静山前。", form: .automatic, book: .pingshui)
        let tail = try #require(analysis.constraint(line: 1, range: 2...4))
        #expect(tail.slots == [.any, .ze, .ping])       // 平平仄仄平的第三字可平可仄
        #expect(tail.rhyme?.key == analysis.rhymeKeys["A"])
        let head = try #require(analysis.constraint(line: 1, range: 0...1))
        #expect(head.rhyme == nil)
        #expect(analysis.constraint(line: 9, range: 0...1) == nil)
        #expect(analysis.constraint(line: 0, range: 3...7) == nil)
    }

    @Test("无模板时保持原字平仄")
    func freeConstraint() throws {
        let analysis = PoemAnalyzer().analyze("春看月", form: .free, book: .pingshui)
        let constraint = try #require(analysis.constraint(line: 0, range: 0...2))
        #expect(constraint.slots == [.ping, .any, .ze])
    }
}

@Suite("标签与筛选表达式")
struct TaggingTests {
    func phrase(_ text: String, tags: [String], kind: PhraseKind = .word, source: ProvenanceKind = .original,
                status: ReviewStatus = .accepted) -> Phrase {
        Phrase(text: text, kind: kind, provenance: Provenance(kind: source),
               tags: tags.map { TagAssignment(path: $0, addedBy: .user) }, status: status)
    }

    @Test("路径规范化", arguments: [
        (" 季节 / 秋 ", "季节/秋"), ("季节／秋//晚秋/", "季节/秋/晚秋"), ("月", "月"),
    ])
    func normalize(raw: String, expected: String) {
        #expect(TagPath.normalize(raw) == expected)
    }

    @Test("空路径", arguments: ["", " / ", "//"])
    func emptyPath(raw: String) {
        #expect(TagPath.normalize(raw) == nil)
    }

    @Test("层级匹配")
    func hierarchy() {
        #expect(TagPath.matches("季节", path: "季节/秋/晚秋"))
        #expect(TagPath.matches("季节/秋", path: "季节/秋/晚秋"))
        #expect(TagPath.matches("秋", path: "季节/秋/晚秋"))
        #expect(!TagPath.matches("季节/冬", path: "季节/秋"))
        #expect(!TagPath.matches("季", path: "季节/秋"))
        #expect(!TagPath.matches("秋/晚秋", path: "季节/秋/晚秋"))
        #expect(TagPath.lineage(of: "a/b/c") == ["a", "a/b", "a/b/c"])
        #expect(TagPath.renamed("a/b/c", from: "a/b", to: "x") == "x/c")
        #expect(TagPath.renamed("a/bc", from: "a/b", to: "x") == nil)
    }

    @Test("与、或、非与分面")
    func expressions() throws {
        let moonAutumn = phrase("明月", tags: ["意象/月", "季节/秋"])
        let goose = phrase("孤鸿", tags: ["意象/雁", "季节/秋"], source: .agent, status: .inbox)
        let spring = phrase("春风十里扬州路", tags: ["季节/春"], kind: .line, source: .excerpt)
        func run(_ query: String) throws -> [String] {
            let filter = try PhraseFilterParser.parse(query)
            return [moonAutumn, goose, spring].filter(filter.matches).map(\.text)
        }
        #expect(try run("") == ["明月", "孤鸿", "春风十里扬州路"])
        #expect(try run("秋") == ["明月", "孤鸿"])
        #expect(try run("秋 月") == ["明月"])
        #expect(try run("月|雁") == ["明月", "孤鸿"])
        #expect(try run("季节 -秋") == ["春风十里扬州路"])
        #expect(try run("!来源:agent") == ["明月", "春风十里扬州路"])
        #expect(try run("字数:7") == ["春风十里扬州路"])
        #expect(try run("类型:句") == ["春风十里扬州路"])
        #expect(try run("来源:AGENT") == ["孤鸿"])
        #expect(try run("状态:收件箱") == ["孤鸿"])
        #expect(try run("含：风") == ["春风十里扬州路"])
        #expect(try run("秋｜春 -月") == ["孤鸿", "春风十里扬州路"])
    }

    @Test("非法表达式", arguments: ["-", "月|", "|月", "字数:abc", "字数:0", "类型:诗", "来源:网络", "状态:草稿", "字数:", "月 /"])
    func invalid(query: String) {
        #expect(throws: FilterParseError.self) { try PhraseFilterParser.parse(query) }
    }

    @Test("标签树")
    func tree() {
        let tree = TagTreeNode.build(["季节/秋/晚秋", "季节/春", "意象", " / "])
        #expect(tree.map(\.name) == ["季节", "意象"])
        #expect(tree[0].children?.map(\.id) == ["季节/春", "季节/秋"])
        #expect(tree[0].children?[1].children?.first?.name == "晚秋")
        #expect(tree[1].children == nil)
        #expect(TagTreeNode.build([]).isEmpty)
    }

    @Test("类型推断", arguments: [("月", PhraseKind.character), ("明月", .word), ("床前明月光", .line), ("明月光，地上霜", .couplet)])
    func inferKind(text: String, kind: PhraseKind) {
        #expect(PhraseKind.infer(from: text) == kind)
    }

    @Test("无汉字时推断失败")
    func inferEmpty() {
        #expect(PhraseKind.infer(from: "abc，。") == nil)
    }
}

@Suite("文本替换")
struct ReplacementTests {
    @Test func replace() {
        let text = "白日依山尽，\n黄河入海流。"
        #expect(TextReplacement.replace(in: text, offsets: [3, 4], with: "孤城") == "白日依孤城，\n黄河入海流。")
        #expect(TextReplacement.replace(in: text, offsets: [7], with: "，长") == "白日依山尽，\n长河入海流。")
    }

    @Test("长度不符或越界", arguments: [([3, 4], "孤"), ([99], "孤"), ([], "")])
    func invalid(offsets: [Int], replacement: String) {
        #expect(TextReplacement.replace(in: "白日依山尽", offsets: offsets, with: replacement) == nil)
    }
}
