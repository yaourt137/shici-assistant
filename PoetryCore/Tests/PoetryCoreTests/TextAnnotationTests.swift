import Testing
@testable import PoetryCore

@Suite("语料全文逐字标注")
struct TextAnnotationTests {
    private let dictionary = CharDictionary.shared

    private func annotate(_ text: String, _ book: RhymeBook = .pingshui) -> [[AnnotatedCharacter]] {
        TextAnnotator.annotate(text, book: book, dictionary: dictionary)
    }

    @Test("逐字平仄，标点不标注")
    func tones() {
        let lines = annotate("春花落，月天。")
        #expect(lines.count == 1)
        let line = lines[0]
        #expect(line.map(\.character) == Array("春花落，月天。"))
        #expect(line[0].tones == [.ping])
        #expect(line[2].tones == [.ze])
        #expect(!line[3].isHan)
        #expect(line[3].tones.isEmpty)
        #expect(line[3].rhymeLabels == nil)
    }

    @Test("只在分句末字标韵部")
    func clauseEndRhymes() {
        let line = annotate("春花落，月天。")[0]
        #expect(line[0].rhymeLabels == nil)
        #expect(line[1].rhymeLabels == nil)
        #expect(line[2].rhymeLabels?.first?.hasPrefix("入声") == true)
        #expect(line[4].rhymeLabels == nil)
        #expect(line[5].rhymeLabels == ["下平·一先"])
    }

    @Test("无标点时行尾字为句末")
    func lineEnd() {
        let lines = annotate("春花落月天\n白雪")
        #expect(lines.count == 2)
        #expect(lines[0][4].rhymeLabels == ["下平·一先"])
        #expect(lines[0][3].rhymeLabels == nil)
        #expect(lines[1][1].rhymeLabels != nil)
    }

    @Test("按所选韵书标注")
    func book() {
        #expect(annotate("月天", .cilin)[0][1].rhymeLabels == ["平·第七部"])
        #expect(annotate("月天", .tongyun)[0][1].rhymeLabels == ["平·十一安"])
    }

    @Test("多音字与未收录字")
    func polyphonicAndUnknown() {
        let line = annotate("独自看，𠀀。")[0]
        #expect(line[2].tones == [.ping, .ze])
        #expect((line[2].rhymeLabels?.count ?? 0) >= 2)
        #expect(line[4].isHan)
        #expect(line[4].tones.isEmpty)
        #expect(line[4].rhymeLabels == [])
    }

    @Test("空文本、空行与纯标点")
    func edgeCases() {
        #expect(annotate("") == [[]])
        let lines = annotate("春\n\n天")
        #expect(lines.count == 3)
        #expect(lines[1].isEmpty)
        #expect(annotate("，。")[0].allSatisfy { !$0.isHan && $0.rhymeLabels == nil })
    }

    @Test("平仄标签")
    func toneLabel() {
        #expect(Set<Tone>().label == "？")
        #expect(Set<Tone>([.ping]).label == "平")
        #expect(Set<Tone>([.ze]).label == "仄")
        #expect(Set<Tone>([.ping, .ze]).label == "平仄")
    }
}
