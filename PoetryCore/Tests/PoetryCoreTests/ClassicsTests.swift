import Foundation
import Testing
@testable import PoetryCore

private let dictionary = CharDictionary.shared

private func groupID(_ section: PingshuiSection, _ number: Int) throws -> Int {
    try #require(dictionary.groups.first { $0.section == section && $0.number == number }).id
}

@Suite("声律启蒙")
struct ShengLvQiMengTests {
    let primer: RhymePrimer

    init() throws {
        primer = try RhymePrimer.loadBundled(.shengLvQiMeng, groups: dictionary.groups)
    }

    @Test("三十节对应平水韵三十个平声韵，每节三段、每段四行")
    func structure() throws {
        #expect(primer.sections.count == 30)
        #expect(primer.sections.map(\.groupID) == dictionary.groups.filter { $0.tone == .ping }.map(\.id))
        #expect(primer.sections[0].title == "一、東")
        #expect(primer.sections[15].title == "一、先")
        #expect(primer.sections.allSatisfy { $0.stanzas.count == 3 && $0.stanzas.allSatisfy { $0.count == 4 } })
        #expect(primer.section(forGroup: try groupID(.xiaPing, 1))?.title == "一、先")
        #expect(primer.section(forGroup: try groupID(.shang, 1)) == nil, "仄声韵没有对应的节")
    }

    @Test("韵脚：句末字，三分句的句子另取第二分句末字")
    func rhymes() {
        let first = primer.sections[0].stanzas[0]
        #expect(first[0].rhymeCharacters == ["風", "空", "蟲"])
        #expect(first[1].rhymeCharacters == ["弓", "東", "宮"])
        #expect(first[3].rhymeCharacters == ["翁"])
        let line = RhymePrimer.parseLine("甲，乙。丙")
        #expect(line.rhymeOffsets == [2], "没有句号的尾巴不取韵脚")
        #expect(RhymePrimer.parseLine("").rhymeOffsets.isEmpty)
    }

    @Test("异文取主文，另存异文")
    func variant() {
        let line = primer.sections[0].stanzas[0][2]
        #expect(line.text == "兩岸曉煙楊柳綠，一園春雨杏花紅。")
        #expect(line.variant == "夾岸曉煙楊柳綠，滿園春色杏花紅。")
        #expect(primer.sections[0].stanzas[0][0].variant == nil)
    }

    @Test("韵脚绝大多数属本韵；不属本韵的列出实际韵目")
    func rhymeCheck() throws {
        let all = primer.sections.flatMap { section in section.stanzas.flatMap { $0 }.flatMap(\.rhymeCharacters).map { (section, $0) } }
        let matched = all.filter { dictionary.pingshuiGroupIDs(of: $0.1).contains($0.0.groupID) }
        #expect(Double(matched.count) / Double(all.count) > 0.97)
        let mismatches = primer.rhymeMismatches(dictionary: dictionary)
        let qingGroup = try groupID(.xiaPing, 9)
        let qing = try #require(primer.sections.firstIndex { $0.groupID == qingGroup })
        let deng = try #require(mismatches.first { $0.sectionIndex == qing && $0.character == "燈" })
        #expect(deng.actualGroupIDs == [try groupID(.xiaPing, 10)], "燈属蒸韵")
        #expect(mismatches.contains { $0.character == "啼" && $0.actualGroupIDs.isEmpty }, "啼为韵表漏收")
        #expect(Set(mismatches.map { "\($0.sectionIndex)\($0.character)" }).count == mismatches.count, "同节去重")
    }

    @Test("对仗：「甲對乙」与等长相邻分句")
    func couplets() {
        let pairs = Set(primer.couplets.filter { $0.sectionIndex == 0 }.map { "\($0.left)|\($0.right)" })
        for expected in ["雲|雨", "雪|風", "晚照|晴空", "來鴻|去燕", "三尺劍|六鈞弓", "嶺北|江東", "人間清暑殿|天上廣寒宮",
                         "兩岸曉煙楊柳綠|一園春雨杏花紅", "兩鬢風霜途次早行之客|一蓑煙雨溪邊晚釣之翁"] {
            #expect(pairs.contains(expected), "\(expected)")
        }
        let mixed = RhymePrimer.couplets(in: "甲對乙乙，丙丁，戊。", sectionIndex: 3)
        #expect(mixed.isEmpty, "两边不等长不成对，落单的分句不成对")
        let long = RhymePrimer.couplets(in: "十月塞邊，颯颯寒霜驚戍旅；三冬江上，漫漫朔雪冷漁翁。", sectionIndex: 0)
        #expect(long.map { "\($0.left)|\($0.right)" } == ["十月塞邊，颯颯寒霜驚戍旅|三冬江上，漫漫朔雪冷漁翁"], "长对整体成对")
        #expect(RhymePrimer.couplets(in: "甲乙，丙丁戊；己庚，辛壬。", sectionIndex: 0).map(\.left) == ["己庚"],
                "两半分句字数不同则不作长对，只取等长相邻分句")
        #expect(RhymePrimer.couplets(in: "甲乙；丙丁。", sectionIndex: 0).count == 1, "只有一个分句的两半按相邻分句成对，不重复")
    }

    @Test("按词查对：繁简不拘、双向")
    func lookup() {
        let converter = dictionary.converter
        #expect(primer.couplets(matching: "云", converter: converter).map(\.counterpart).contains("雨"))
        #expect(primer.couplets(matching: "雨", converter: converter).map(\.counterpart).contains("雲"))
        #expect(primer.couplets(matching: "来鸿", converter: converter).map(\.counterpart) == ["去燕"])
        #expect(primer.couplets(matching: "两鬓风霜途次早行之客", converter: converter).map(\.counterpart) == ["一蓑煙雨溪邊晚釣之翁"])
        #expect(primer.couplets(matching: "", converter: converter).isEmpty)
        #expect(primer.couplets(matching: "，。", converter: converter).isEmpty)
        #expect(primer.couplets(matching: "不存在的词", converter: converter).isEmpty)
        #expect(primer.rhymeCharacters(of: primer.sections[0], converter: converter).isSuperset(of: ["风", "空", "虫"]))
    }

    @Test("节名无法对应、卷名缺失或没有任何一节时报错")
    func errors() {
        let groups = dictionary.groups
        #expect(throws: RhymePrimerError.unknownSection("一、冬")) {
            try RhymePrimer.shengLvQiMeng(wikitext: "==卷上==\n===一、冬===\n雲對雨。\n", groups: groups)
        }
        #expect(throws: RhymePrimerError.unknownSection("一、東")) {
            try RhymePrimer.shengLvQiMeng(wikitext: "===一、東===\n雲對雨。\n", groups: groups)
        }
        #expect(throws: RhymePrimerError.unknownSection("東")) {
            try RhymePrimer.shengLvQiMeng(wikitext: "==卷上==\n===東===\n", groups: groups)
        }
        #expect(throws: RhymePrimerError.noSections) { try RhymePrimer.shengLvQiMeng(wikitext: "{{header}}\n", groups: groups) }
        #expect(throws: RhymePrimerError.noSections) { try RhymePrimer.shengLvQiMeng(wikitext: "==卷上==\n===一、東===\n", groups: groups) }
    }

    @Test("问号、叹号也断句")
    func questionMarks() {
        let line = RhymePrimer.parseLine("色艷北堂，草號忘憂憂甚事？香濃南國，花名含笑笑何人？")
        #expect(line.rhymeCharacters == ["人"], "以问号断开的前半句末字不押韵")
        #expect(RhymePrimer.parseLine("甲乙！丙丁。").rhymeCharacters == ["丁"])
        #expect(RhymePrimer.parseLine("甲乙。丙丁！").rhymeCharacters == ["乙", "丁"])
        let pairs = RhymePrimer.couplets(in: line.text, sectionIndex: 0).map { "\($0.left)|\($0.right)" }
        #expect(pairs == ["色艷北堂，草號忘憂憂甚事|香濃南國，花名含笑笑何人"], "以问号隔开的长对整体成对")
        #expect(RhymePrimer.couplets(in: "甲對乙，丙對丁。戊對己，庚對辛。", sectionIndex: 0).count == 4, "含「對」的句子不作长对")
    }
}

@Suite("笠翁对韵")
struct LiwengDuiyunTests {
    let primer: RhymePrimer

    init() throws {
        primer = try RhymePrimer.loadBundled(.liwengDuiyun, groups: dictionary.groups)
    }

    @Test("三十节依次对应平水韵三十个平声韵，每节二至四段、每段七行")
    func structure() {
        #expect(primer.work == .liwengDuiyun)
        #expect(primer.sections.count == 30)
        #expect(primer.sections.map(\.groupID) == dictionary.groups.filter { $0.tone == .ping }.map(\.id))
        #expect(primer.sections[0].title == "一、東")
        #expect(primer.sections[16].title == "二、蕭")
        #expect(primer.sections.allSatisfy { (2...4).contains($0.stanzas.count) && $0.stanzas.allSatisfy { $0.count == 7 } })
        #expect(primer.sections[2].stanzas.count == 2, "江韵只有两段")
        #expect(primer.sections[0].stanzas[0].first?.text == "天對地，雨對風。", "去掉行首的「:」与全角空格")
        #expect(primer.sections[16].stanzas[0].first?.text == "琴對管，斧對瓢。", "<poem> 包裹的页面同样解析")
    }

    @Test("对仗与韵脚")
    func couplets() {
        let pairs = Set(primer.couplets.filter { $0.sectionIndex == 0 }.map { "\($0.left)|\($0.right)" })
        for expected in ["天|地", "雨|風", "大陸|長空", "雷隱隱|霧濛濛", "風高秋月白|雨霽晚霞紅",
                         "十月塞邊，颯颯寒霜驚戍旅|三冬江上，漫漫朔雪冷漁翁"] {
            #expect(pairs.contains(expected), "\(expected)")
        }
        #expect(primer.sections[0].stanzas[0][0].rhymeCharacters == ["風"])
        let rhymes = primer.sections.flatMap { section in section.stanzas.flatMap { $0 }.flatMap(\.rhymeCharacters).map { (section, $0) } }
        let matched = rhymes.filter { dictionary.pingshuiGroupIDs(of: $0.1).contains($0.0.groupID) }
        #expect(Double(matched.count) / Double(rhymes.count) > 0.9)
    }

    @Test("节名与韵目代表字不符、缺节名或没有正文时报错")
    func errors() {
        let groups = dictionary.groups
        #expect(throws: RhymePrimerError.unknownSection("冬")) {
            try RhymePrimer.liwengDuiyun(wikitext: "{{header\n| section  = 冬\n}}\n:天對地。\n", groups: groups)
        }
        #expect(throws: RhymePrimerError.unknownSection("東冬")) {
            try RhymePrimer.liwengDuiyun(wikitext: "{{header\n| section  = 東冬\n}}\n:天對地。\n", groups: groups)
        }
        #expect(throws: RhymePrimerError.noSections) {
            try RhymePrimer.liwengDuiyun(wikitext: "{{header\n| section  = \n}}\n:天對地。\n", groups: groups)
        }
        #expect(throws: RhymePrimerError.noSections) { try RhymePrimer.liwengDuiyun(wikitext: "", groups: groups) }
        let one = try? RhymePrimer.liwengDuiyun(wikitext: "{{header\n| section  = 東\n}}\n:　　天對地。\n:　　\n:山對海。\n", groups: groups)
        #expect(one?.sections.first?.stanzas.count == 2, "只有「:」的行分段")
    }
}

@Suite("佩文韵府解析")
struct PeiwenParserTests {
    let result = PeiwenParser.parse(ClassicsFixtures.peiwen, groups: dictionary.groups)

    private func entries(_ head: String, _ kind: YunfuEntryKind) -> [YunfuEntry] {
        result.entries.filter { $0.head == head && $0.kind == kind }
    }

    @Test("字头注与韵藻：跨行的词条与注文合并，「丨」还原")
    func yunzao() {
        #expect(entries("東", .gloss).map(\.note) == ["德紅切眷方也漢書少陽在東方東動也從日在木中會意也禮記大明生於東"])
        #expect(entries("東", .yunzao).map(\.phrase) == ["南東", "自東", "小東", "乃東", "首陽東"])
        let notes = Dictionary(uniqueKeysWithValues: entries("東", .yunzao).map { ($0.phrase, $0) })
        #expect(notes["南東"]?.note == "詩南東其畝李孝先詩")
        #expect(notes["小東"]?.note == "詩小東大東杼柚其空言大小皆取給於東國", "下一行开头的注文接在上一条")
        #expect(notes["乃東"]?.note == "本草乃東夏枯草名", "词条被拆在两行")
        #expect(notes["首陽東"]?.note == "詩采葑采葑首陽之東")
        #expect(notes["首陽東"]?.rawNote == "詩采葑采葑丨丨之丨")
        #expect(result.entries.filter { $0.head == "東" }.allSatisfy { $0.groupID == 0 && $0.juan == "卷一之一" })
        #expect(entries("同", .yunzao).map(\.note) == ["書四海會同"])
    }

    @Test("对语与摘句")
    func duiyuAndZhaiju() {
        #expect(entries("東", .duiyu).map { "\($0.counterpart ?? "")|\($0.phrase)" } == ["縕瑟|吹東", "千户劍|半通東"])
        #expect(entries("東", .zhaiju).map(\.phrase) == ["力障百川東", "光升必自東", "内庭秋燕玉池東", "半溪春水帶愁東",
                                                     "菊花依舊繞籬東", "宛似山光小閣東"])
    }

    @Test("一行两个韵字、缺字实体、跨行注文")
    func layoutEdgeCases() {
        #expect(!entries("鸝", .gloss).isEmpty)
        #expect(entries("緀", .gloss).map(\.note) == ["七稽切緀斐文章相錯貎"])
        #expect(entries("〓", .gloss).map(\.note) == ["徂紅切籠〓取魚器"])
        #expect(entries("〓", .zeng).map(\.phrase) == ["萬尺〓"], "「韻藻增」连写时直接进入「增」")
        #expect(entries("〓", .zeng).map(\.note) == ["陸龜䝉詩到頭江畔織作中流萬尺〓"])
    }

    @Test("「增冰」是词条而非段名；异体「増」也是段名；换韵目")
    func zengMarker() throws {
        let zheng = try groupID(.xiaPing, 10)
        #expect(entries("冰", .yunzao).map(\.phrase) == ["增冰", "層冰"])
        #expect(entries("冰", .zeng).map(\.phrase) == ["瀆冰"])
        #expect(entries("冰", .zeng).map(\.note) == ["某書瀆冰"])
        #expect(result.entries.filter { $0.head == "冰" }.allSatisfy { $0.groupID == zheng })
    }

    @Test("韵目之前的文字与残缺的对语计入跳过")
    func skipped() {
        #expect(result.skipped == 3)
        #expect(!result.entries.contains { $0.phrase.contains("孤行") })
    }

    @Test("目录卷、序与缺卷次的文件不解析")
    func nonContentFiles() {
        #expect(PeiwenParser.parse(ClassicsFixtures.peiwenCatalog, groups: dictionary.groups).entries.isEmpty)
        #expect(PeiwenParser.parse("#+PROPERTY: JUAN 御製序\n東(德紅切)¶", groups: dictionary.groups).entries.isEmpty)
        #expect(PeiwenParser.parse("東(德紅切)¶", groups: dictionary.groups).entries.isEmpty)
        #expect(PeiwenParser.parse("", groups: dictionary.groups).entries.isEmpty)
    }

    @Test("韵目标题按声部与序数对应")
    func headers() throws {
        let groups = dictionary.groups
        #expect(PeiwenParser.groupID(fromHeader: "上平聲　　　　一東韻一", groups: groups) == 0)
        #expect(PeiwenParser.groupID(fromHeader: "去聲　　一送韻", groups: groups) == (try groupID(.qu, 1)))
        #expect(PeiwenParser.groupID(fromHeader: "去聲　　　二十三〓韻三", groups: groups) == (try groupID(.qu, 23)))
        #expect(PeiwenParser.groupID(fromHeader: "入聲三〓韻四", groups: groups) == (try groupID(.ru, 3)))
        #expect(PeiwenParser.groupID(fromHeader: "上平聲一東", groups: groups) == nil)
        #expect(PeiwenParser.groupID(fromHeader: "上聲", groups: groups) == nil)
        #expect(PeiwenParser.groupID(fromHeader: "上平聲九十九東韻", groups: groups) == nil)
        #expect(PeiwenParser.groupID(fromHeader: "上聲(某)韻", groups: groups) == nil)
        #expect(PeiwenParser.groupID(fromHeader: "東韻", groups: groups) == nil)
    }

    @Test("「丨」还原", arguments: [
        ("詩丨丨其畝", "南東", "詩南東其畝"),
        ("丨丨之丨", "首陽東", "首陽之東"),
        ("在丨方丨動", "東", "在東方東動"),
        ("丨丨丨丨", "南東", "南東南東"),
        ("丨", "南東", "南"),
        ("無代字", "南東", "無代字"),
        ("丨丨", "", "丨丨"),
        ("", "南東", ""),
    ])
    func expand(note: String, phrase: String, expected: String) {
        #expect(YunfuNote.expand(note, phrase: phrase) == expected)
    }

    @Test("摘句拆句")
    func splitQuotations() {
        #expect(PeiwenParser.splitQuotations("内庭秋燕玉池東半溪春水帶愁東", head: "東") == ["内庭秋燕玉池東", "半溪春水帶愁東"])
        #expect(PeiwenParser.splitQuotations("力障百川東", head: "東") == ["力障百川東"])
        #expect(PeiwenParser.splitQuotations("内庭秋燕玉池西半溪春水帶愁東", head: "東") == ["内庭秋燕玉池西半溪春水帶愁東"])
        #expect(PeiwenParser.splitQuotations("", head: "東").isEmpty)
        #expect(PeiwenParser.splitQuotations("某句", head: "").count == 1)
    }

    @Test("漢リポ文本清理")
    func kanripoText() {
        #expect(KanripoText.property("JUAN", in: "#+PROPERTY: JUAN 卷一\n正文") == "卷一")
        #expect(KanripoText.property("JUAN", in: "#+PROPERTY: JUAN \n") == nil)
        #expect(KanripoText.property("JUAN", in: "正文") == nil)
        #expect(KanripoText.bodyLines("#注\n<pb:X_001-1a>¶\n甲&KR0001;乙¶\r\n\n丙<pb:X_001-1b>丁¶") == ["甲〓乙", "", "丙丁"])
        #expect(KanripoText.trimmingSpaces("　 甲　乙 　") == "甲　乙")
        #expect(KanripoText.joinColumns("右行/左行") == "右行左行")
    }
}

@Suite("艺文类聚解析")
struct LeijuParserTests {
    @Test("部、子目、按版面宽度合并引文、文体沿用到子目结束")
    func parse() {
        let result = LeijuParser.parse(ClassicsFixtures.leiju, juan: 7)
        #expect(result.skipped == 0)
        #expect(result.entries.map(\.text) == [
            "春秋説題辭曰山之為言宣也含澤布氣調五神也",
            "國語曰禹封九山山者土之聚也",
            "論語曰仁者樂山",
            "春秋元命苞曰山者氣之包含所以含精藏雲故觸石而出",
            "鄧徳眀南康記曰平固縣覆笥山上有笥貯玉牒記故山因笥為名焉",
            "晉庾闡登楚山詩曰拂駕升西嶺寓目臨浚波想望七徳耀詠此九功歌龍駟釋陽林朝服集三河迴首盻宇宙一無濟邦家",
            "晉王凝之妻謝氏詩曰峩峩東嶽髙秀極冲清天巖中閒虚宇寂漠幽以玄非工復非匠雲構發自然噐象爾何物遂令我屢遷逝將宅斯宇可以盡天年",
            "南嶽記曰衡山者五嶽之南嶽也（其山）其來尚矣",
        ])
        #expect(result.entries.map(\.genre) == [nil, nil, nil, nil, nil, "詩", "詩", nil])
        #expect(result.entries.map(\.topic) == Array(repeating: "總載山", count: 7) + ["衡山"])
        #expect(result.entries.allSatisfy { $0.part == "山部上" && $0.juan == 7 })
    }

    @Test("出处与正文")
    func attribution() {
        let entry = LeijuEntry(juan: 7, part: "山部上", topic: "總載山", genre: nil, text: "論語曰仁者樂山")
        #expect(entry.attributionAndBody.attribution == "論語")
        #expect(entry.attributionAndBody.body == "仁者樂山")
        let noYue = LeijuEntry(juan: 1, part: "", topic: "", genre: nil, text: "孫康家貧常映雪讀書")
        #expect(noYue.attributionAndBody.attribution == nil)
        #expect(noYue.attributionAndBody.body == "孫康家貧常映雪讀書")
        let leading = LeijuEntry(juan: 1, part: "", topic: "", genre: nil, text: "曰某")
        #expect(leading.attributionAndBody.attribution == nil)
    }

    @Test("部名的几种版式", arguments: [
        ("山部上(總載山/衡山)　(崑崙山/廬山)", "山部上"),
        ("歳時下(社/臘)", "歳時下"),
        ("后妃部", "后妃部"),
        ("總載山", nil),
        ("某書曰(某)", nil),
        ("(總載山/衡山)", nil),
        ("一二三四五六七八九部", nil),
    ] as [(String, String?)])
    func partNames(line: String, expected: String?) {
        #expect(LeijuParser.partName(line) == expected)
    }

    @Test("版面宽度与文体名")
    func widthAndGenre() {
        #expect(LeijuParser.visualWidth("甲(乙丙/丁)戊") == 4)
        #expect(LeijuParser.visualWidth("甲(乙丙") == 3)
        #expect(LeijuParser.visualWidth("") == 0)
        #expect(LeijuParser.genreLabel(of: "詩晉庾闡登楚山詩曰")?.0 == "詩")
        #expect(LeijuParser.genreLabel(of: "哀策文梁簡文帝某曰")?.0 == "哀策文")
        #expect(LeijuParser.genreLabel(of: "賦楚宋玉高唐賦曰")?.1 == "楚宋玉高唐賦曰")
        #expect(LeijuParser.genreLabel(of: "書曰乃命羲和") == nil)
        #expect(LeijuParser.genreLabel(of: "東觀漢記曰") == nil)
        #expect(LeijuParser.genreLabel(of: "詩") == nil)
    }

    @Test("非正文卷不解析；子目之前的引文计入跳过")
    func edgeCases() {
        #expect(LeijuParser.parse(ClassicsFixtures.leijuPreface, juan: 0).entries.isEmpty)
        #expect(LeijuParser.parse("正文¶", juan: 1).entries.isEmpty)
        let orphan = LeijuParser.parse("#+PROPERTY: JUAN 卷一\n　天部上(天/)¶\n無子目之文¶\n", juan: 1)
        #expect(orphan.entries.isEmpty)
        #expect(orphan.skipped == 1)
        let indented = LeijuParser.parse("#+PROPERTY: JUAN 卷一\n　　天¶\n　某書曰此行縮進一格而不是子目或部名¶\n", juan: 1)
        #expect(indented.entries.map(\.text) == ["某書曰此行縮進一格而不是子目或部名"], "缩进的长行按引文处理")
    }
}

@Suite("典籍索引")
struct ClassicsIndexTests {
    private func makeIndex(_ directory: TemporaryDirectory) throws -> (ClassicsIndex, URL) {
        let texts = try ClassicsFixtures.makeDirectory(in: directory)
        return (try ClassicsIndex(url: directory.url.appendingPathComponent("classics.sqlite")), texts)
    }

    @Test("导入、查询（繁简不拘）、重新导入与删除")
    func roundTrip() async throws {
        let directory = try TemporaryDirectory()
        let (index, texts) = try makeIndex(directory)
        #expect(try await index.installed().isEmpty)
        let count = try await index.importWork(.peiwenYunfu, from: texts, groups: dictionary.groups)
        #expect(count == PeiwenParser.parse(ClassicsFixtures.peiwen, groups: dictionary.groups).entries.count)

        #expect(try await index.yunfuEntries(head: "东", kinds: [.gloss]).map(\.head) == ["東"])
        #expect(try await index.yunfuEntries(head: "東", kinds: [.yunzao]).map(\.phrase) == ["南東", "自東", "小東", "乃東", "首陽東"])
        #expect(try await index.yunfuEntries(head: "东", kinds: []).isEmpty)
        #expect(try await index.yunfuEntries(head: "东", limit: 0).isEmpty)
        #expect(try await index.yunzao(heads: ["东", "冰"], length: 2).map(\.phrase) == ["南東", "自東", "小東", "乃東", "增冰", "層冰", "瀆冰"])
        #expect(try await index.yunzao(heads: ["东"], length: 3).map(\.phrase) == ["首陽東"])
        #expect(try await index.yunzao(heads: ["东"], length: 5).map(\.phrase) == ["力障百川東", "光升必自東"], "五字取摘句")
        let stored = try await index.yunfuEntries(head: "东", kinds: [.yunzao])
        #expect(stored.first?.note == "詩南東其畝李孝先詩", "读出时还原「丨」")
        #expect(stored.first?.rawNote == "詩丨丨其畝李孝先詩")
        #expect(try await index.yunzao(heads: [], length: 2).isEmpty)
        #expect(try await index.yunzao(heads: ["东"], length: 0).isEmpty)
        #expect(try await index.duiyu(matching: "缊瑟").map(\.phrase) == ["吹東"])
        #expect(try await index.duiyu(matching: "半通东").map(\.counterpart) == ["千户劍"])
        #expect(try await index.duiyu(matching: "，").isEmpty)

        try await index.importWork(.yiwenLeiju, from: texts, groups: dictionary.groups)
        let topics = try await index.leijuTopics()
        #expect(topics.map(\.topic) == ["總載山", "衡山"])
        #expect(topics.first?.entryCount == 7)
        #expect(try await index.leijuEntries(in: topics[1]).map(\.text) == ["南嶽記曰衡山者五嶽之南嶽也（其山）其來尚矣"])
        #expect(try await index.searchLeiju("仁者乐山").map(\.text) == ["論語曰仁者樂山"])
        #expect(try await index.searchLeiju("  ").isEmpty)
        #expect(try await index.searchLeiju("山", limit: 2).count == 2)

        let reimported = try await index.importWork(.peiwenYunfu, from: texts, groups: dictionary.groups)
        #expect(reimported == count)
        #expect(try await index.yunfuEntries(head: "东", kinds: [.gloss]).count == 1, "重新导入不重复")
        let installed = try await index.installed()
        #expect(installed.map(\.work) == [.peiwenYunfu, .yiwenLeiju])
        #expect(installed.allSatisfy { !$0.needsReindex })

        try await index.delete(.peiwenYunfu)
        #expect(try await index.installed().map(\.work) == [.yiwenLeiju])
        #expect(try await index.yunfuEntries(head: "东").isEmpty)
        #expect(try await index.leijuTopics().count == 2, "删除一部不影响另一部")
    }

    @Test("没有文本或解析不出条目时报错，原索引保留")
    func errors() async throws {
        let directory = try TemporaryDirectory()
        let (index, texts) = try makeIndex(directory)
        try await index.importWork(.yiwenLeiju, from: texts, groups: dictionary.groups)
        let empty = directory.url.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await #expect(throws: ClassicsError.noTextFiles(empty.path)) {
            try await index.importWork(.yiwenLeiju, from: empty, groups: dictionary.groups)
        }
        try directory.write(ClassicsFixtures.leijuPreface, to: "prefaceOnly/KR3k0003_000.txt")
        await #expect(throws: ClassicsError.noEntries("艺文类聚")) {
            try await index.importWork(.yiwenLeiju, from: directory.url.appendingPathComponent("prefaceOnly"), groups: dictionary.groups)
        }
        #expect(try await index.leijuTopics().count == 2, "失败的导入整体回滚")
    }

    @Test("旧格式的索引需要重建")
    func format() {
        let old = ClassicInfo(work: .peiwenYunfu, entryCount: 1, importedAt: Date(), format: ClassicsIndex.format - 1)
        #expect(old.needsReindex)
        #expect(ClassicWork.peiwenYunfu.filePrefix == "KR3k0059_")
        #expect(ClassicWork.yiwenLeiju.archiveURL?.absoluteString == "https://codeload.github.com/kanripo/KR3k0003/zip/refs/heads/master")
    }
}

@Suite("典籍下载")
struct ClassicsDownloaderTests {
    /// 对所有请求返回固定状态码，不访问网络。
    final class StubProtocol: URLProtocol {
        nonisolated(unsafe) static var status = 404

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            let url = request.url ?? URL(fileURLWithPath: "/")
            let response = HTTPURLResponse(url: url, statusCode: StubProtocol.status, httpVersion: nil, headerFields: nil)
            if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
            client?.urlProtocol(self, didLoad: Data("x".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func zip(_ source: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", source.path, destination.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test("解压后找到「仓库名-master」下的文本目录")
    func extract() throws {
        let directory = try TemporaryDirectory()
        try directory.write(ClassicsFixtures.leiju, to: "KR3k0003-master/KR3k0003_007.txt")
        let archive = directory.url.appendingPathComponent("archive.zip")
        try zip(directory.url.appendingPathComponent("KR3k0003-master"), to: archive)
        let destination = directory.url.appendingPathComponent("out")
        try ClassicsDownloader.extract(zip: archive, to: destination)
        let texts = try ClassicsDownloader.textDirectory(of: .yiwenLeiju, in: destination)
        #expect(texts.lastPathComponent == "KR3k0003-master")
        #expect(throws: ClassicsError.noTextFiles(destination.path)) {
            try ClassicsDownloader.textDirectory(of: .peiwenYunfu, in: destination)
        }
    }

    @Test("不是 zip 时报解压失败")
    func badArchive() throws {
        let directory = try TemporaryDirectory()
        try directory.write("not a zip", to: "bad.zip")
        let error = #expect(throws: ClassicsDownloadError.self) {
            try ClassicsDownloader.extract(zip: directory.url.appendingPathComponent("bad.zip"),
                                           to: directory.url.appendingPathComponent("out"))
        }
        if case .extractionFailed(let detail) = error {
            #expect(!detail.isEmpty)
        } else {
            Issue.record("应为解压失败，实为 \(String(describing: error))")
        }
    }

    @Test("已下载则不再请求；HTTP 错误如实报告")
    func download() async throws {
        let directory = try TemporaryDirectory()
        try directory.write(ClassicsFixtures.leiju, to: "yiwen-leiju/KR3k0003-master/KR3k0003_007.txt")
        StubProtocol.status = 404
        let existing = try await ClassicsDownloader.download(.yiwenLeiju, into: directory.url, session: stubSession())
        #expect(existing.lastPathComponent == "KR3k0003-master")
        await #expect(throws: ClassicsDownloadError.badStatus(404)) {
            try await ClassicsDownloader.download(.peiwenYunfu, into: directory.url, session: stubSession())
        }
    }
}

@Suite("典籍服务")
struct ClassicsServiceTests {
    private func makeService(_ directory: TemporaryDirectory) throws -> PoetryService {
        try PoetryService(paths: AppPaths(root: directory.url.appendingPathComponent("data")))
    }

    private func placeTexts(_ service: PoetryService, _ directory: TemporaryDirectory) throws {
        try ClassicsFixtures.placeDownloadedTexts(for: service, in: directory)
    }

    @Test("待导入、导入与删除")
    func lifecycle() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        #expect(try await service.pendingClassics().isEmpty)
        try placeTexts(service, directory)
        #expect(try await service.pendingClassics() == [.peiwenYunfu, .yiwenLeiju])
        try await service.reimportClassic(.peiwenYunfu)
        #expect(try await service.pendingClassics() == [.yiwenLeiju])
        try await service.removeClassic(.peiwenYunfu)
        #expect(!FileManager.default.fileExists(atPath: service.paths.classics.appendingPathComponent("peiwen-yunfu").path))
        #expect(try await service.classics.installed().isEmpty)
        await #expect(throws: (any Error).self) { try await service.reimportClassic(.peiwenYunfu) }
    }

    @Test("对仗：对韵蒙书在前，佩文对语在后，去重")
    func couplets() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        let cloud = try await service.couplets(matching: "云")
        #expect(cloud.first?.counterpart == "雨")
        #expect(cloud.first?.source == .primer(.shengLvQiMeng, sectionIndex: 0))
        #expect(try await service.couplets(matching: "大陆").map(\.source) == [.primer(.liwengDuiyun, sectionIndex: 0)], "笠翁对韵")
        try placeTexts(service, directory)
        try await service.reimportClassic(.peiwenYunfu)
        let suggestions = try await service.couplets(matching: "缊瑟")
        #expect(suggestions.map(\.counterpart) == ["吹東"])
        #expect(suggestions.first?.source == .yunfu(head: "東", groupID: 0))
        #expect(try await service.couplets(matching: "").isEmpty)
    }

    @Test("韵藻候选：押韵时取同韵各字，按平仄过滤；不押韵时取以该字结尾的")
    func yunzao() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        try placeTexts(service, directory)
        try await service.reimportClassic(.peiwenYunfu)
        let dong = RhymeKey(book: .pingshui, id: 0)
        let rhymed = SlotConstraint(slots: [.ze, .ping], rhyme: RhymeRequirement(key: dong, tone: .ping), book: .pingshui)
        let phrases = try await service.yunzaoCandidates(for: rhymed, lastCharacter: "东").map(\.phrase)
        #expect(phrases.contains("自東"))
        #expect(!phrases.contains("南東"), "首字须仄")
        #expect(!phrases.contains("層冰"), "不同韵")
        let free = SlotConstraint(slots: [.any, .any], rhyme: nil, book: .pingshui)
        #expect(try await service.yunzaoCandidates(for: free, lastCharacter: "冰").map(\.phrase) == ["增冰", "層冰", "瀆冰"])
        #expect(try await service.yunzaoCandidates(for: free, lastCharacter: "冰", limit: 1).count == 1)
    }

    @Test("韵藻轮流排列：常用韵字在前，各取一条")
    func interleave() {
        func entry(_ head: String, _ phrase: String) -> YunfuEntry {
            YunfuEntry(groupID: 0, head: head, kind: .yunzao, phrase: phrase, juan: "卷一")
        }
        let entries = [entry("東", "南東"), entry("東", "自東"), entry("同", "會同"), entry("銅", "青銅"), entry("同", "大同")]
        let converter = dictionary.converter
        let ranked = YunzaoRanking.interleave(entries, converter: converter, frequencies: ["同": 5, "东": 9], limit: 10)
        #expect(ranked.map(\.phrase) == ["南東", "會同", "青銅", "自東", "大同"])
        #expect(YunzaoRanking.interleave(entries, converter: converter, frequencies: [:], limit: 2).map(\.phrase) == ["南東", "會同"])
        #expect(YunzaoRanking.interleave(entries, converter: converter, frequencies: [:], limit: 0).isEmpty)
        #expect(YunzaoRanking.interleave([], converter: converter, frequencies: [:], limit: 5).isEmpty)
    }
}
