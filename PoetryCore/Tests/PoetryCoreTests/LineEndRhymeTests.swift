import Testing
@testable import PoetryCore

@Suite("句末字韵部")
struct LineEndRhymeTests {
    private let analyzer = PoemAnalyzer()
    private let dictionary = CharDictionary.shared

    @Test("平水韵显示韵目")
    func pingshui() {
        let analysis = analyzer.analyze("白雪春山落，春花落月天。", form: .free, book: .pingshui)
        let labels = analysis.lineEndRhymeLabels(dictionary: dictionary)
        #expect(labels.count == 2)
        #expect(labels[1] == ["下平·一先"])
        #expect(labels[0].count == 1)
        #expect(labels[0][0].hasPrefix("入声"))
    }

    @Test("词林正韵与中华通韵前加平仄")
    func otherBooks() {
        let cilin = analyzer.analyze("春花落月天", form: .free, book: .cilin).lineEndRhymeLabels(dictionary: dictionary)
        #expect(cilin == [["平·第七部"]])
        let tongyun = analyzer.analyze("春花落月天", form: .free, book: .tongyun).lineEndRhymeLabels(dictionary: dictionary)
        #expect(tongyun == [["平·十一安"]])
    }

    @Test("多音字列出全部韵部")
    func polyphonic() {
        let labels = analyzer.analyze("春山独自看", form: .free, book: .pingshui).lineEndRhymeLabels(dictionary: dictionary)
        #expect(labels[0].contains("上平·十四寒"))
        #expect(labels[0].count >= 2)
    }

    @Test("未收录字为空")
    func unknownCharacter() {
        let labels = analyzer.analyze("春花落月𠀀", form: .free, book: .pingshui).lineEndRhymeLabels(dictionary: dictionary)
        #expect(labels == [[]])
    }

    @Test("空文本")
    func empty() {
        #expect(analyzer.analyze("", form: .free, book: .pingshui).lineEndRhymeLabels(dictionary: dictionary).isEmpty)
    }

    @Test("读法简称")
    func readingLabel() {
        #expect(dictionary.label(of: Reading(tone: .ze, rhyme: RhymeKey(book: .cilin, id: 1))) == "仄·第一部")
        #expect(dictionary.label(of: Reading(tone: .ping, rhyme: RhymeKey(book: .tongyun, id: 99))) == "平·未知韵")
    }
}
