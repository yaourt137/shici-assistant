import Testing
@testable import PoetryCore

/// 用「平仄中？」描述一句：中＝多音字（可平可仄），？＝未收录字（空集合）。
private func tones(_ pattern: String) -> [Set<Tone>] {
    pattern.map { character in
        switch character {
        case "平": [.ping]
        case "仄": [.ze]
        case "中": [.ping, .ze]
        default: []
        }
    }
}

private func meter(_ lines: String...) -> MeterAnalysis {
    MeterAnalyzer.analyze(lines.map(tones))
}

@Suite("律句")
struct LineMeterTests {
    @Test("五言四种基本句型", arguments: [
        ("仄仄平平仄", "仄起仄收"), ("平平仄仄平", "平起平收"),
        ("平平平仄仄", "平起仄收"), ("仄仄仄平平", "仄起平收"),
    ])
    func fiveCharacterTypes(pattern: String, name: String) {
        let line = meter(pattern).lines[0].meter
        #expect(line?.displayName == name)
        #expect(line?.variant == .standard)
        #expect(line?.length == 5)
    }

    @Test("七言四种基本句型", arguments: [
        ("平平仄仄平平仄", "平起仄收"), ("仄仄平平仄仄平", "仄起平收"),
        ("仄仄平平平仄仄", "仄起仄收"), ("平平仄仄仄平平", "平起平收"),
    ])
    func sevenCharacterTypes(pattern: String, name: String) {
        let line = meter(pattern).lines[0].meter
        #expect(line?.displayName == name)
        #expect(line?.variant == .standard)
    }

    @Test("句型文字标出可平可仄处")
    func patternText() {
        #expect(meter("仄仄平平仄").lines[0].meter?.patternText == "中仄中平仄")
        #expect(meter("仄仄仄平平").lines[0].meter?.patternText == "中仄仄平平")
        #expect(meter("平平仄仄仄平平").lines[0].meter?.patternText == "中平中仄仄平平")
    }

    @Test("可平可仄处不影响律句")
    func flexiblePositions() {
        #expect(meter("平仄仄平仄").lines[0].meter?.variant == .standard)
        #expect(meter("仄平平仄仄平平").lines[0].meter?.displayName == "平起平收")
    }

    @Test("孤平不是律句，孤平拗救是")
    func guPing() {
        #expect(meter("仄平仄仄平").lines[0] == .irregular)
        #expect(meter("仄仄仄平仄仄平").lines[0] == .irregular)
        #expect(meter("仄平平仄平").lines[0].meter?.variant == .guPingRescued)
        #expect(meter("仄仄仄平平仄平").lines[0].meter?.variant == .guPingRescued)
    }

    @Test("三平尾不是律句")
    func sanPingWei() {
        #expect(meter("仄仄平平平").lines[0] == .irregular)
        #expect(meter("平平仄仄平平平").lines[0] == .irregular)
    }

    @Test("特拗与三仄尾算律句并注明")
    func teAoAndSanZeWei() {
        #expect(meter("平平仄平仄").lines[0].meter?.variant == .teAo)
        #expect(meter("仄仄平平仄平仄").lines[0].meter?.variant == .teAo)
        #expect(meter("平平仄仄仄").lines[0].meter?.variant == .sanZeWei)
    }

    @Test("非律句")
    func irregular() {
        #expect(meter("平仄平仄平").lines[0] == .irregular)
        #expect(meter("平平平平平").lines[0] == .irregular)
        #expect(meter("仄仄仄仄仄仄仄").lines[0] == .irregular)
    }

    @Test("非五七言不判断", arguments: ["平仄", "平平仄仄", "仄仄平平仄仄", "平平仄仄平平仄仄", ""])
    func unsupported(pattern: String) {
        let analysis = meter(pattern)
        #expect(analysis.lines[0] == .unsupported)
        #expect(analysis.supportedLineCount == 0)
    }

    @Test("未收录字按可平可仄处理")
    func unknownCharacter() {
        #expect(meter("？？平平仄").lines[0].meter?.displayName == "仄起仄收")
        #expect(meter("？？？？？").lines[0].meter != nil)
    }

    @Test("单独一句大拗不算律句")
    func daAoAlone() {
        #expect(meter("仄仄平仄仄").lines[0] == .irregular)
    }
}

@Suite("律对与粘")
struct CoupletMeterTests {
    @Test("平收对句的律对")
    func opposed() {
        let analysis = meter("仄仄平平仄", "平平仄仄平")
        #expect(analysis.couplets.count == 1)
        #expect(analysis.couplets[0].relation == .opposed)
        #expect(analysis.couplets[0].sharesEnding == false)
        #expect(analysis.couplets[0].adheres == nil)
    }

    @Test("出句入韵：同收平声或同收仄声", arguments: [
        ("仄仄仄平平", "平平仄仄平"), ("平平平仄仄", "仄仄平平仄"),
    ])
    func sharesEnding(out: String, response: String) {
        let couplet = meter(out, response).couplets[0]
        #expect(couplet.relation == .opposed)
        #expect(couplet.sharesEnding)
    }

    @Test("仄韵：出句平收、对句仄收也算律对")
    func zeRhyme() {
        #expect(meter("平平仄仄平", "仄仄平平仄").couplets[0].relation == .opposed)
    }

    @Test("两句皆律句但不相对")
    func notOpposed() {
        #expect(meter("仄仄平平仄", "仄仄仄平平").couplets[0].relation == .notOpposed)
    }

    @Test("五七言混用不算律对")
    func lengthMismatch() {
        #expect(meter("仄仄平平仄", "仄仄平平仄仄平").couplets[0].relation == .notOpposed)
    }

    @Test("含非律句即为非律联")
    func irregularCouplet() {
        #expect(meter("仄仄平平平", "平平仄仄平").couplets[0].relation == .irregular)
        #expect(meter("平仄", "平平仄仄平").couplets[0].relation == .irregular)
    }

    @Test("大拗由对句第三字用平救")
    func daAoRescued() {
        let rescued = meter("仄仄平仄仄", "平平平仄平")
        #expect(rescued.couplets[0].relation == .opposed)
        #expect(rescued.lines[0].meter?.variant == .daAoRescued)
        #expect(rescued.lines[1].meter?.variant == .standard)

        let sevenRescued = meter("平平仄仄平仄仄", "仄仄平平平仄平")
        #expect(sevenRescued.lines[0].meter?.variant == .daAoRescued)

        let unrescued = meter("仄仄平仄仄", "平平仄仄平")
        #expect(unrescued.couplets[0].relation == .irregular)
        #expect(unrescued.lines[0] == .irregular)
        #expect(unrescued.lines[1].meter?.variant == .standard)
    }

    @Test("对句不能以大拗成立")
    func daAoInResponse() {
        #expect(meter("平平仄仄平", "仄仄平仄仄").lines[1] == .irregular)
    }

    @Test("多音字取能构成律对的读法")
    func polyphonicResolution() {
        // 出句可读作「仄仄平平仄」或「平平平仄仄」；单独看取前者，与「仄仄仄平平」相对时取后者。
        #expect(meter("平中平中仄").lines[0].meter?.displayName == "仄起仄收")
        let analysis = meter("平中平中仄", "仄仄仄平平")
        #expect(analysis.couplets[0].relation == .opposed)
        #expect(analysis.lines[0].meter?.displayName == "平起仄收")
    }

    @Test("粘与不粘")
    func adherence() {
        let adhered = meter("仄仄平平仄", "平平仄仄平", "平平平仄仄", "仄仄仄平平")
        #expect(adhered.couplets[1].adheres == true)
        #expect(adhered.adheredCount == 1)
        #expect(adhered.adherenceCheckedCount == 1)

        let broken = meter("仄仄平平仄", "平平仄仄平", "仄仄平平仄", "平平仄仄平")
        #expect(broken.couplets[1].adheres == false)
        #expect(broken.adheredCount == 0)
    }

    @Test("相邻两句有非律句或字数不同时不判断粘")
    func adherenceUnchecked() {
        #expect(meter("仄仄平平仄", "平平平平平", "平平平仄仄", "仄仄仄平平").couplets[1].adheres == nil)
        #expect(meter("仄仄平平仄", "平平仄仄平", "平平仄仄仄平平", "仄仄平平仄仄平").couplets[1].adheres == nil)
    }

    @Test("奇数句末句落单，仍判断与上联的粘")
    func unpaired() {
        let analysis = meter("仄仄平平仄", "平平仄仄平", "平平平仄仄")
        #expect(analysis.couplets.count == 2)
        #expect(analysis.couplets[1].relation == .unpaired)
        #expect(analysis.couplets[1].firstLine == 2)
        #expect(analysis.couplets[1].lastLine == 2)
        #expect(analysis.couplets[1].adheres == true)
        #expect(analysis.pairedCoupletCount == 1)
        #expect(analysis.couplet(containing: 2)?.relation == .unpaired)
    }

    @Test("统计")
    func counts() {
        let analysis = meter("仄仄平平仄", "平平仄仄平", "平仄平仄平", "平平仄仄平", "平平")
        #expect(analysis.supportedLineCount == 4)
        #expect(analysis.regularLineCount == 3)
        #expect(analysis.pairedCoupletCount == 2)
        #expect(analysis.opposedCoupletCount == 1)
        #expect(analysis.couplet(containing: 1)?.firstLine == 0)
        #expect(analysis.couplet(containing: 9) == nil)
    }

    @Test("空输入")
    func empty() {
        let analysis = MeterAnalyzer.analyze([])
        #expect(analysis.lines.isEmpty)
        #expect(analysis.couplets.isEmpty)
        #expect(analysis.regularLineCount == 0)
    }
}

@Suite("律句律对：接入诗作分析")
struct PoemMeterTests {
    @Test("自由体裁下也能判定律句律对")
    func freeForm() {
        let analysis = PoemAnalyzer().analyze("白雪春山落，春花落月天。春山花落雪，白雪静山前。春花白雪", form: .free, book: .pingshui)
        let meter = analysis.meter
        #expect(meter.lines.count == 5)
        #expect(meter.lines[0].meter?.displayName == "仄起仄收")
        #expect(meter.couplets[0].relation == .opposed)
        #expect(meter.couplets[1].relation == .opposed)
        #expect(meter.couplets[1].adheres == true)
        #expect(meter.lines[4] == .unsupported)
        #expect(meter.couplets[2].relation == .unpaired)
    }

    @Test("是否按律绝分析")
    func regulatedForm() {
        let analyzer = PoemAnalyzer()
        let text = "白雪春山落，春花落月天。春山花落雪，白雪静山前。"
        #expect(analyzer.analyze(text, form: .automatic, book: .pingshui).regulatedForm == .wujue)
        #expect(analyzer.analyze(text, form: .regulated(.wujue, opening: .zeZe), book: .pingshui).regulatedForm == .wujue)
        #expect(analyzer.analyze(text, form: .free, book: .pingshui).regulatedForm == nil)
        #expect(analyzer.analyze(text, form: .ci("huanxisha"), book: .pingshui).regulatedForm == nil)
        #expect(analyzer.analyze("白雪春山落，春花落月天。", form: .automatic, book: .pingshui).regulatedForm == nil)
        #expect(analyzer.analyze("", form: .automatic, book: .pingshui).regulatedForm == nil)
    }

    @Test("空文本")
    func emptyText() {
        let meter = PoemAnalyzer().analyze("", form: .free, book: .pingshui).meter
        #expect(meter.lines.isEmpty)
        #expect(meter.couplets.isEmpty)
    }
}
