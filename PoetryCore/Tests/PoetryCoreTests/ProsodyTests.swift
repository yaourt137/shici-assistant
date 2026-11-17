import Testing
@testable import PoetryCore

private let analyzer = PoemAnalyzer()

private func kinds(_ analysis: PoemAnalysis, _ severity: Severity? = nil) -> [IssueKind] {
    analysis.issues.filter { severity == nil || $0.severity == severity }.map(\.kind)
}

private func describe(_ analysis: PoemAnalysis) -> String {
    analysis.issues.map { "[\($0.severity.displayName)] \($0.message)" }.joined(separator: "\n")
}

@Suite("文本切分")
struct SegmenterTests {
    @Test func segments() {
        let segments = TextSegmenter.segments(of: "白日依山尽，\n黄河入海流。abc")
        #expect(segments.map(\.count) == [5, 5])
        #expect(segments[1][0].character == "黄")
        #expect(segments[1][0].offset == 7)
    }

    @Test("空文本与纯标点")
    func empty() {
        #expect(TextSegmenter.segments(of: "").isEmpty)
        #expect(TextSegmenter.segments(of: "，。！\n  ").isEmpty)
    }

    @Test("按句长重切与不对齐")
    func fit() {
        let segments = TextSegmenter.segments(of: "一二三四五六七八九十")
        let (lines, aligned) = TextSegmenter.fit(segments, lengths: [5, 5])
        #expect(aligned)
        #expect(lines.map(\.count) == [5, 5])
        let (unchanged, misaligned) = TextSegmenter.fit(segments, lengths: [5, 4])
        #expect(!misaligned)
        #expect(unchanged.map(\.count) == [10])
    }
}

@Suite("近体诗格律")
struct RegulatedTests {
    // 仄起首句不入韵的标准五绝（人工构造，各字平仄单一）。
    let standard = "白雪春山落，春花落月天。春山花落雪，白雪静山前。"

    @Test("合律五绝无错误")
    func standardPoem() {
        let analysis = analyzer.analyze(standard, form: .automatic, book: .pingshui)
        #expect(analysis.formName == "五绝")
        #expect(analysis.variantName == "仄起，首句不入韵")
        #expect(analysis.errorCount == 0, "\(describe(analysis))")
        #expect(analysis.rhymeKeys["A"].map(CharDictionary.shared.displayName(of:)) == "下平·一先")
        #expect(analysis.lines[1].characters[4].rhymeGroup == "A")
        #expect(analysis.lines[0].characters[4].rhymeGroup == nil)
    }

    @Test("无标点时按字数切分")
    func noPunctuation() {
        let analysis = analyzer.analyze("白雪春山落春花落月天春山花落雪白雪静山前", form: .automatic, book: .pingshui)
        #expect(analysis.formName == "五绝")
        #expect(analysis.lines.count == 4)
        #expect(analysis.errorCount == 0)
    }

    @Test("孤平")
    func guPing() {
        let analysis = analyzer.analyze("白雪春山落，雪花落月天。春山花落雪，白雪静山前。", form: .automatic, book: .pingshui)
        #expect(kinds(analysis, .error).contains(.guPing))
    }

    @Test("孤平拗救不算错")
    func guPingRescued() {
        let analysis = analyzer.analyze("白雪春山落，雪花春月天。春山花落雪，白雪静山前。", form: .automatic, book: .pingshui)
        #expect(!kinds(analysis, .error).contains(.guPing))
        #expect(kinds(analysis).contains(.guPingRescued))
        #expect(analysis.lines[1].characters[2].status == .rescued)
    }

    @Test("三平尾")
    func sanPingWei() {
        let analysis = analyzer.analyze("白雪春山落，春花落月天。春山花落雪，白雪春山前。", form: .automatic, book: .pingshui)
        #expect(kinds(analysis, .error).contains(.sanPingWei))
        #expect(!kinds(analysis, .error).contains(.toneMismatch))
    }

    @Test("出韵")
    func chuYun() {
        let analysis = analyzer.analyze("白雪春山落，春花落月天。春山花落雪，白雪静山东。", form: .automatic, book: .pingshui)
        #expect(kinds(analysis, .error).contains(.chuYun))
        #expect(analysis.lines[3].characters[4].status == .mismatch)
    }

    @Test("首句借邻韵只作提示")
    func neighborRhyme() {
        let analysis = analyzer.analyze("白雪静山寒，春花落月天。春山花落雪，白雪静山前。", form: .automatic, book: .pingshui)
        #expect(analysis.variantName == "仄起，首句入韵")
        #expect(kinds(analysis).contains(.neighborRhyme))
        #expect(!kinds(analysis, .error).contains(.chuYun))
    }

    @Test("首句入韵")
    func firstLineRhymes() {
        let analysis = analyzer.analyze("白雪静山年，春花落月天。春山花落雪，白雪静山前。", form: .automatic, book: .pingshui)
        #expect(analysis.variantName == "仄起，首句入韵")
        #expect(analysis.errorCount == 0, "\(describe(analysis))")
        #expect(analysis.lines[0].characters[4].rhymeGroup == "A")
    }

    @Test("出句拗、对句救")
    func aoRescued() {
        let rescued = analyzer.analyze("白雪春月落，春花春月天。春山花落雪，白雪静山前。", form: .automatic, book: .pingshui)
        #expect(kinds(rescued).contains(.aoRescued))
        #expect(rescued.errorCount == 0, "\(describe(rescued))")
        let unrescued = analyzer.analyze("白雪春月落，春花落月天。春山花落雪，白雪静山前。", form: .automatic, book: .pingshui)
        #expect(kinds(unrescued, .error).contains(.aoUnrescued))
    }

    @Test("特拗与三仄尾")
    func teAoAndSanZeWei() {
        let teAo = analyzer.analyze("白雪春山落，春花落月天。春山落花雪，白雪静山前。", form: .automatic, book: .pingshui)
        #expect(kinds(teAo).contains(.teAo))
        #expect(teAo.errorCount == 0, "\(describe(teAo))")
        let sanZe = analyzer.analyze("白雪春山落，春花落月天。春山落月雪，白雪静山前。", form: .automatic, book: .pingshui)
        #expect(kinds(sanZe).contains(.sanZeWei))
        #expect(sanZe.errorCount == 0)
    }

    @Test("失粘")
    func shiNian() {
        let analysis = analyzer.analyze("白雪春山落，春花落月天。白雪春山落，春花落月天。", form: .automatic, book: .pingshui)
        #expect(kinds(analysis, .error).contains(.shiNian))
    }

    @Test("失对")
    func shiDui() {
        let analysis = analyzer.analyze("白雪春山落，白雪静山前。春山花落雪，白雪静山年。", form: .automatic, book: .pingshui)
        #expect(kinds(analysis, .error).contains(.shiDui))
    }

    @Test("重韵与重字")
    func repeats() {
        let analysis = analyzer.analyze("白雪春山落，春花落月天。春山花落雪，白雪静山天。", form: .automatic, book: .pingshui)
        #expect(kinds(analysis, .warning).contains(.repeatedRhyme))
        #expect(kinds(analysis, .hint).contains(.repeatedCharacter))
    }

    @Test("叠字不算重字")
    func reduplication() {
        let analysis = analyzer.analyze("萧萧", form: .free, book: .pingshui)
        #expect(!kinds(analysis).contains(.repeatedCharacter))
    }

    @Test("句数与字数不符")
    func structuralErrors() {
        let short = analyzer.analyze("白雪春山落，春花落月天。春山花落雪。", form: .regulated(.wujue), book: .pingshui)
        #expect(kinds(short, .error).contains(.lineCount))
        let wrongLength = analyzer.analyze("白雪春山落，春花落月天。春山花落，白雪静山前。", form: .regulated(.wujue), book: .pingshui)
        #expect(kinds(wrongLength, .error).contains(.lineLength))
        #expect(kinds(wrongLength, .error).contains(.lineCount) == false)
    }

    @Test("空文本")
    func empty() {
        let analysis = analyzer.analyze("，。\n", form: .automatic, book: .pingshui)
        #expect(analysis.lines.isEmpty)
        #expect(analysis.issues.isEmpty)
    }

    @Test("未识别体裁时自由标注")
    func freeFallback() {
        let analysis = analyzer.analyze("床前明月光", form: .automatic, book: .pingshui)
        #expect(analysis.formName == "自由")
        #expect(kinds(analysis).contains(.unrecognizedForm))
        #expect(analysis.lines[0].characters.allSatisfy { $0.expected == nil })
    }

    @Test("未收录字提示")
    func unknownCharacters() {
        let analysis = analyzer.analyze("白雪春山𠀋", form: .free, book: .pingshui)
        #expect(kinds(analysis).contains(.unknownCharacter))
    }

    @Test("经典作品合律", arguments: [
        ("王之涣《登鹳雀楼》", "白日依山尽，黄河入海流。欲穷千里目，更上一层楼。", "五绝"),
        ("杜甫《绝句》", "两个黄鹂鸣翠柳，一行白鹭上青天。窗含西岭千秋雪，门泊东吴万里船。", "七绝"),
        ("杜甫《春望》", "国破山河在，城春草木深。感时花溅泪，恨别鸟惊心。烽火连三月，家书抵万金。白头搔更短，浑欲不胜簪。", "五律"),
        ("杜甫《登高》", "风急天高猿啸哀，渚清沙白鸟飞回。无边落木萧萧下，不尽长江滚滚来。万里悲秋常作客，百年多病独登台。艰难苦恨繁霜鬓，潦倒新停浊酒杯。", "七律"),
        ("繁体《登鸛雀樓》", "白日依山盡，黃河入海流。欲窮千里目，更上一層樓。", "五绝"),
    ])
    func classics(title: String, text: String, form: String) {
        let analysis = analyzer.analyze(text, form: .automatic, book: .pingshui)
        #expect(analysis.formName == form)
        #expect(analysis.errorCount == 0, "\(title)\n\(describe(analysis))")
    }

    @Test("古绝《静夜思》不合近体格律")
    func jingYeSi() {
        let analysis = analyzer.analyze("床前明月光，疑是地上霜。举头望明月，低头思故乡。", form: .automatic, book: .pingshui)
        #expect(analysis.errorCount > 0)
    }

    @Test("通韵按今音：「一」读平致三平尾")
    func tongyunModernTone() {
        let analysis = analyzer.analyze("白日依山尽，黄河入海流。欲穷千里目，更上一层楼。", form: .automatic, book: .tongyun)
        #expect(kinds(analysis, .error).contains(.sanPingWei))
    }

    @Test("体裁存储值往返")
    func formStorage() {
        let forms: [FormSelection] = [.automatic, .free, .regulated(.qilv), .ci("huanxisha")]
        for form in forms {
            #expect(FormSelection(storageValue: form.storageValue) == form)
        }
        #expect(FormSelection(storageValue: "ci:") == nil)
        #expect(FormSelection(storageValue: "regulated:六绝") == nil)
        #expect(FormSelection(storageValue: "") == nil)
    }

    @Test("起收的存储值：旧值按自动处理，坏值拒绝")
    func openingStorage() {
        for opening in RegulatedOpening.allCases {
            let form = FormSelection.regulated(.qijue, opening: opening)
            #expect(FormSelection(storageValue: form.storageValue) == form)
        }
        #expect(FormSelection.regulated(.wulv, opening: .pingPing).storageValue == "regulated:五律:平起平收")
        #expect(FormSelection(storageValue: "regulated:五绝") == .regulated(.wujue))
        #expect(FormSelection.regulated(.wujue).storageValue == "regulated:五绝")
        #expect(FormSelection(storageValue: "regulated:七律:") == nil)
        #expect(FormSelection(storageValue: "regulated:七律:平起") == nil)
        #expect(FormSelection(storageValue: "regulated:七律:平起平收:x") == nil)
        #expect(FormSelection(storageValue: "regulated:") == nil)
        #expect(FormSelection(storageValue: "regulated::平起平收") == nil)
    }

    @Test("起收的平仄含义")
    func openingMeaning() {
        #expect(RegulatedOpening.pingPing.startsPing && RegulatedOpening.pingPing.firstLineRhymes)
        #expect(RegulatedOpening.pingZe.startsPing && !RegulatedOpening.pingZe.firstLineRhymes)
        #expect(!RegulatedOpening.zePing.startsPing && RegulatedOpening.zePing.firstLineRhymes)
        #expect(!RegulatedOpening.zeZe.startsPing && !RegulatedOpening.zeZe.firstLineRhymes)
    }
}

@Suite("指定起收")
struct RegulatedOpeningTests {
    // 仄起仄收的五绝与平起仄收的七绝（人工构造，各字平仄单一）。
    let wujue = "白雪春山落，春花落月天。春山花落雪，白雪静山前。"
    let qijue = "春山白雪春山落，白雪春花落月天。白雪春山花落雪，春山白雪静山前。"

    @Test("指定与实际相符时无错误，并注明指定")
    func matching() {
        let five = analyzer.analyze(wujue, form: .regulated(.wujue, opening: .zeZe), book: .pingshui)
        #expect(five.variantName == "仄起，首句不入韵（指定）")
        #expect(five.errorCount == 0, "\(describe(five))")
        let seven = analyzer.analyze(qijue, form: .regulated(.qijue, opening: .pingZe), book: .pingshui)
        #expect(seven.variantName == "平起，首句不入韵（指定）")
        #expect(seven.errorCount == 0, "\(describe(seven))")
    }

    @Test("自动判断不加「指定」")
    func automatic() {
        #expect(analyzer.analyze(qijue, form: .regulated(.qijue), book: .pingshui).variantName == "平起，首句不入韵")
    }

    @Test("指定与实际不符时按指定格式报错，不再自动改选", arguments: RegulatedOpening.allCases)
    func forced(opening: RegulatedOpening) {
        let analysis = analyzer.analyze(wujue, form: .regulated(.wujue, opening: opening), book: .pingshui)
        let start = opening.startsPing ? "平起" : "仄起"
        let rhyme = opening.firstLineRhymes ? "入韵" : "不入韵"
        #expect(analysis.variantName == "\(start)，首句\(rhyme)（指定）")
        #expect((analysis.errorCount == 0) == (opening == .zeZe), "\(describe(analysis))")
    }

    @Test("指定平收时首句末字按韵脚要求")
    func firstLineRhymes() {
        let analysis = analyzer.analyze("白雪静山年，春花落月天。春山花落雪，白雪静山前。",
                                        form: .regulated(.wujue, opening: .zePing), book: .pingshui)
        #expect(analysis.errorCount == 0, "\(describe(analysis))")
        #expect(analysis.lines[0].characters[4].rhymeGroup == "A")
        #expect(analysis.lines[0].patternText == "中仄仄平平")
    }

    @Test("句数不足时仍按指定格式分析")
    func shortPoem() {
        let analysis = analyzer.analyze("白雪春山落，春花落月天。", form: .regulated(.wujue, opening: .pingPing), book: .pingshui)
        #expect(analysis.variantName == "平起，首句入韵（指定）")
        #expect(kinds(analysis, .error).contains(.lineCount))
    }
}

@Suite("词谱")
struct CiTests {
    @Test("内置词谱可加载")
    func bundled() {
        let library = CiTuneLibrary.bundled
        #expect(library.tunes.count >= 13)
        #expect(library.tune(id: "shuidiaogetou")?.characterCount == 95)
        #expect(library.tune(id: "huanxisha")?.characterCount == 42)
        #expect(library.tune(id: "nonexistent") == nil)
    }

    @Test("经典例词在词林正韵下合谱", arguments: CiTuneLibrary.bundled.tunes.map(\.id))
    func examples(id: String) throws {
        let tune = try #require(CiTuneLibrary.bundled.tune(id: id))
        let example = try #require(tune.example)
        let analysis = analyzer.analyze(example.text, form: .ci(id), book: .cilin)
        #expect(analysis.errorCount == 0, "\(tune.name)\n\(describe(analysis))")
        let pingshui = analyzer.analyze(example.text, form: .ci(id), book: .pingshui)
        #expect(pingshui.errorCount == 0, "\(tune.name)（平水韵）\n\(describe(pingshui))")
        #expect(pingshui.rhymeBookForKeys == .cilin)
    }

    @Test("换韵：菩萨蛮四组韵各自成部")
    func rhymeChanges() throws {
        let tune = try #require(CiTuneLibrary.bundled.tune(id: "pusaman"))
        let analysis = analyzer.analyze(try #require(tune.example).text, form: .ci("pusaman"), book: .cilin)
        #expect(Set(analysis.rhymeKeys.keys) == ["A", "B", "C", "D"])
        #expect(analysis.rhymeKeys["B"]?.id == 12)
    }

    @Test("字数不符")
    func lengthMismatch() {
        let analysis = analyzer.analyze("山下兰芽短浸溪，松间沙路净无泥。", form: .ci("huanxisha"), book: .cilin)
        #expect(kinds(analysis, .error).contains(.lineLength))
    }

    @Test("词中出韵")
    func chuYun() {
        let text = "山下兰芽短浸溪，松间沙路净无泥，萧萧暮雨子规啼。谁道人生无再少？门前流水尚能西！休将白发唱黄风。"
        let analysis = analyzer.analyze(text, form: .ci("huanxisha"), book: .cilin)
        #expect(kinds(analysis, .error).contains(.chuYun))
    }

    @Test("未找到词牌")
    func missingTune() {
        let analysis = analyzer.analyze("春风", form: .ci("missing"), book: .cilin)
        #expect(kinds(analysis, .error).contains(.unrecognizedForm))
    }

    @Test("句式解析与校验")
    func parseLine() throws {
        let line = try CiTuneLibrary.parseLine("中仄平A", stanza: 1, tune: "测试")
        #expect(line.slots == [.any, .ze, .ping])
        #expect(line.rhymeGroup == "A")
        #expect(line.stanza == 1)
        #expect(throws: CiTuneError.self) { try CiTuneLibrary.parseLine("中仄中A", stanza: 0, tune: "测试") }
        #expect(throws: CiTuneError.self) { try CiTuneLibrary.parseLine("平x仄", stanza: 0, tune: "测试") }
        #expect(throws: CiTuneError.self) { try CiTuneLibrary.parseLine("A", stanza: 0, tune: "测试") }
    }

    @Test("词谱文件格式校验")
    func fileValidation() {
        let wrongKind = #"{"formatVersion":1,"kind":"corpus","tunes":[]}"#
        #expect(throws: CiTuneError.self) { try CiTuneLibrary(json: Data(wrongKind.utf8)) }
        let duplicate = #"{"formatVersion":1,"kind":"formbook","tunes":[{"id":"a","name":"甲","stanzas":[["平A"]]},{"id":"a","name":"乙","stanzas":[["平A"]]}]}"#
        #expect(throws: CiTuneError.duplicateID("a")) { try CiTuneLibrary(json: Data(duplicate.utf8)) }
        let version = #"{"formatVersion":2,"kind":"formbook","tunes":[]}"#
        #expect(throws: CiTuneError.self) { try CiTuneLibrary(json: Data(version.utf8)) }
    }
}

import Foundation
