import Foundation
import Testing
@testable import PoetryCore

@Suite("多音字指定读音")
struct ReadingChoiceTests {
    private let analyzer = PoemAnalyzer()
    private let dictionary = CharDictionary.shared

    /// 按韵部名称取某字的读音。
    private func reading(_ character: Character, _ label: String, _ book: RhymeBook = .pingshui) throws -> Reading {
        try #require(dictionary.readings(of: character, in: book).first { dictionary.label(of: $0) == label })
    }

    private func zeReading(_ character: Character, _ book: RhymeBook = .pingshui) throws -> Reading {
        try #require(dictionary.readings(of: character, in: book).first { $0.tone == .ze })
    }

    // MARK: - 正文改动

    @Test("改动在指定字之后则保留")
    func retainedAfterEdit() throws {
        let choice = ReadingChoice(offset: 4, character: "看", reading: try reading("看", "上平·十四寒"))
        #expect(ReadingChoice.retained([choice], from: "春山独自看", to: "春山独自看，") == [choice])
        #expect(ReadingChoice.retained([choice], from: "春山独自看，月", to: "春山独自看，") == [choice])
        #expect(ReadingChoice.retained([choice], from: "春山独自看", to: "春山独自看") == [choice])
    }

    @Test("改动在指定字之前或就是该字则作废")
    func droppedWhenMoved() throws {
        let choice = ReadingChoice(offset: 4, character: "看", reading: try reading("看", "上平·十四寒"))
        #expect(ReadingChoice.retained([choice], from: "春山独自看", to: "青春山独自看").isEmpty, "前方插入，位置后移")
        #expect(ReadingChoice.retained([choice], from: "春山独自看", to: "春独自看").isEmpty, "前方删除，位置前移")
        #expect(ReadingChoice.retained([choice], from: "春山独自看", to: "春山独自望").isEmpty, "字被替换")
        #expect(ReadingChoice.retained([choice], from: "春山独自看", to: "春山独自").isEmpty, "字被删除")
        #expect(ReadingChoice.retained([choice], from: "春山独自看", to: "").isEmpty)
        #expect(ReadingChoice.retained([], from: "春", to: "秋").isEmpty)
    }

    @Test("修改作品正文时自动作废失效的指定")
    func poemBodyEdit() throws {
        let choice = ReadingChoice(offset: 1, character: "看", reading: try reading("看", "上平·十四寒"))
        var poem = Poem(body: "独看", readingChoices: [choice])
        poem.body = "独看月"
        #expect(poem.readingChoices == [choice])
        poem.body = "孤独看月"
        #expect(poem.readingChoices.isEmpty)
    }

    @Test("同一位置同一韵书只保留一个，不同韵书各自保留")
    func updating() throws {
        let han = try reading("看", "上平·十四寒")
        let zePingshui = try zeReading("看")
        let cilin = try #require(dictionary.readings(of: "看", in: .cilin).first)
        var choices = ReadingChoice.updating([], character: "看", at: 2, book: .pingshui, to: han)
        #expect(choices.map(\.reading) == [han])
        choices = ReadingChoice.updating(choices, character: "看", at: 2, book: .pingshui, to: zePingshui)
        #expect(choices.map(\.reading) == [zePingshui])
        choices = ReadingChoice.updating(choices, character: "看", at: 2, book: .cilin, to: cilin)
        #expect(choices.count == 2)
        choices = ReadingChoice.updating(choices, character: "看", at: 2, book: .pingshui, to: nil)
        #expect(choices.map(\.reading) == [cilin], "清除只影响当前韵书")
        #expect(ReadingChoice.updating([], character: "看", at: 0, book: .pingshui, to: cilin).isEmpty, "读音与韵书不符则不加入")
    }

    @Test("编码往返")
    func codable() throws {
        let choice = ReadingChoice(offset: 3, character: "行", reading: try reading("行", "下平·七阳"))
        let data = try JSONEncoder().encode([choice])
        #expect(try JSONDecoder().decode([ReadingChoice].self, from: data) == [choice])
    }

    // MARK: - 分析

    @Test("指定后平仄唯一，不再列为多音字")
    func tones() throws {
        let text = "春山独自看"
        let automatic = analyzer.analyze(text, form: .free, book: .pingshui)
        #expect(automatic.lines[0].characters[4].tones == [.ping, .ze])
        #expect(automatic.lines[0].characters[4].chosenReading == nil)

        let han = try reading("看", "上平·十四寒")
        let chosen = analyzer.analyze(text, form: .free, book: .pingshui,
                                      choices: [ReadingChoice(offset: 4, character: "看", reading: han)])
        #expect(chosen.lines[0].characters[4].tones == [.ping])
        #expect(chosen.lines[0].characters[4].chosenReading == han)
        #expect(chosen.lineEndRhymeLabels(dictionary: dictionary) == [["上平·十四寒"]])
    }

    @Test("近体诗中指定读音后多音字提示消失")
    func polyphonicHint() throws {
        let text = "山中春雨晴，江上客舟行。月白千峰静，风清一鸟鸣。"
        let before = analyzer.analyze(text, form: .automatic, book: .pingshui)
        #expect(before.issues.contains { $0.kind == .polyphonic && $0.message.contains("行") })
        let after = analyzer.analyze(text, form: .automatic, book: .pingshui,
                                     choices: [ReadingChoice(offset: 10, character: "行", reading: try reading("行", "下平·八庚"))])
        #expect(!after.issues.contains { $0.kind == .polyphonic && $0.message.contains("行") })
        #expect(after.character(at: CharPosition(line: 1, column: 4))?.status == .ok)
    }

    @Test("韵脚按指定韵部判断出韵")
    func rhymeByChosenGroup() throws {
        // 五律四个必押韵脚中三个属庚韵，韵部判断不受「行」的读音左右。
        let text = "山中春雨晴，江上客舟行。月白千峰静，风清一鸟鸣。云开孤嶂出，水阔远帆轻。回首烟波外，苍茫万里情。"
        let position = CharPosition(line: 1, column: 4)
        let automatic = analyzer.analyze(text, form: .automatic, book: .pingshui)
        #expect(!automatic.issues.contains { $0.kind == .chuYun }, "自动判断时取能押庚韵的读音")

        let geng = analyzer.analyze(text, form: .automatic, book: .pingshui,
                                    choices: [ReadingChoice(offset: 10, character: "行", reading: try reading("行", "下平·八庚"))])
        #expect(!geng.issues.contains { $0.kind == .chuYun })

        let yang = analyzer.analyze(text, form: .automatic, book: .pingshui,
                                    choices: [ReadingChoice(offset: 10, character: "行", reading: try reading("行", "下平·七阳"))])
        #expect(yang.issues.contains { $0.kind == .chuYun && $0.positions == [position] })
        #expect(yang.character(at: position)?.status == .mismatch)
    }

    @Test("韵脚指定为仄声：报平仄不合，不重复报出韵")
    func rhymeChosenZe() throws {
        let text = "山中春雨晴，江上客舟行。月白千峰静，风清一鸟鸣。"
        let analysis = analyzer.analyze(text, form: .automatic, book: .pingshui,
                                        choices: [ReadingChoice(offset: 10, character: "行", reading: try zeReading("行"))])
        let position = CharPosition(line: 1, column: 4)
        #expect(analysis.character(at: position)?.tones == [.ze])
        #expect(analysis.character(at: position)?.status == .mismatch)
        #expect(!analysis.issues.contains { $0.kind == .chuYun && $0.positions == [position] })
    }

    @Test("无效的指定被忽略：换了韵书、字不符、读音不属于该字")
    func invalidChoicesIgnored() throws {
        let han = try reading("看", "上平·十四寒")
        let text = "春山独自看"
        let otherBook = analyzer.analyze(text, form: .free, book: .cilin,
                                         choices: [ReadingChoice(offset: 4, character: "看", reading: han)])
        #expect(otherBook.lines[0].characters[4].chosenReading == nil, "切换韵书后回到自动判断")
        #expect(otherBook.lines[0].characters[4].tones == [.ping, .ze])

        let wrongCharacter = analyzer.analyze("春山独自望", form: .free, book: .pingshui,
                                              choices: [ReadingChoice(offset: 4, character: "看", reading: han)])
        #expect(wrongCharacter.lines[0].characters[4].chosenReading == nil)

        let foreignReading = analyzer.analyze("春山独自天", form: .free, book: .pingshui,
                                              choices: [ReadingChoice(offset: 4, character: "天", reading: han)])
        #expect(foreignReading.lines[0].characters[4].chosenReading == nil)

        let outOfRange = analyzer.analyze("春", form: .free, book: .pingshui,
                                          choices: [ReadingChoice(offset: 99, character: "看", reading: han)])
        #expect(outOfRange.lines[0].characters[0].chosenReading == nil)
    }

    @Test("词用平水韵时，指定读音换算为词林正韵部判断押韵")
    func cilinMapping() throws {
        let yang = try reading("行", "下平·七阳")
        let geng = try reading("行", "下平·八庚")
        let yangSection = try #require(dictionary.cilinReading(of: "行", fromPingshui: yang))
        let gengSection = try #require(dictionary.cilinReading(of: "行", fromPingshui: geng))
        #expect(yangSection.rhyme != gengSection.rhyme)
        #expect(dictionary.cilinReading(of: "行", fromPingshui: yangSection) == nil, "非平水韵读音不换算")

        let resolver = ReadingResolver(dictionary: dictionary, book: .pingshui,
                                       choices: [ReadingChoice(offset: 0, character: "行", reading: yang)])
        #expect(resolver.rhymeKeys(of: "行", at: 0, in: .cilin, tone: .ping) == [yangSection.rhyme])
        #expect(resolver.rhymeKeys(of: "行", at: 0, in: .pingshui, tone: .ping) == [yang.rhyme])
        #expect(resolver.rhymeKeys(of: "行", at: 0, in: .pingshui, tone: .ze).isEmpty)
        #expect(resolver.rhymeKeys(of: "行", at: 1, in: .pingshui, tone: .ping).count == 2, "未指定的位置取全部读音")
    }
}
