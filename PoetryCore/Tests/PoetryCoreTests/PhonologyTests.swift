import Testing
@testable import PoetryCore

@Suite("拼音解析")
struct PinyinTests {
    @Test("声调与韵母", arguments: [
        ("zhī", 1, "-i"), ("shí", 2, "-i"), ("sì", 4, "-i"),
        ("lǜ", 4, "ü"), ("nǚ", 3, "ü"), ("lüè", 4, "üe"), ("lue4", 4, "üe"),
        ("yuán", 2, "üan"), ("yún", 2, "ün"), ("yǔ", 3, "ü"), ("xué", 2, "üe"), ("jūn", 1, "ün"),
        ("yā", 1, "ia"), ("yǒu", 3, "iu"), ("yī", 1, "i"), ("yīng", 1, "ing"), ("yōng", 1, "iong"),
        ("wēng", 1, "ueng"), ("wéi", 2, "ui"), ("wén", 2, "un"), ("wǔ", 3, "u"), ("wǒ", 3, "uo"),
        ("jiā", 1, "ia"), ("ér", 2, "er"), ("bō", 1, "o"), ("guī", 1, "ui"), ("liú", 2, "iu"),
        ("ê̄", 1, "ê"), ("de", 5, "e"),
    ])
    func parse(raw: String, tone: Int, final: String) throws {
        let syllable = try #require(PinyinSyllable(raw))
        #expect(syllable.tone == tone)
        #expect(syllable.final == final)
    }

    @Test("非法输入返回 nil", arguments: ["", "  ", "中", "a9", "x#"])
    func invalid(raw: String) {
        #expect(PinyinSyllable(raw) == nil)
    }

    @Test("中华通韵归部")
    func tongyun() {
        #expect(TongYun.rhymeID(forFinal: "-i") == 4)
        #expect(TongYun.rhymeID(forFinal: "üe") == 3)
        #expect(TongYun.rhymeID(forFinal: "ong") == 15)
        #expect(TongYun.rhymeID(forFinal: "ueng") == 14)
        #expect(TongYun.rhymeID(forFinal: "er") == 16)
        #expect(TongYun.rhymeID(forFinal: "ng") == nil)
        #expect(TongYun.tone(forPinyinTone: 2) == .ping)
        #expect(TongYun.tone(forPinyinTone: 3) == .ze)
        #expect(TongYun.tone(forPinyinTone: 5) == nil)
        #expect(TongYun.name(of: 1) == "一啊")
        #expect(TongYun.name(of: 0) == "未知韵")
        #expect(TongYun.name(of: 17) == "未知韵")
    }
}

@Suite("平水韵与词林正韵")
struct PingshuiTests {
    let dictionary = CharDictionary.shared

    @Test("中文数字", arguments: [("一", 1), ("十", 10), ("十三", 13), ("二十", 20), ("二十九", 29), ("三十", 30)])
    func numerals(text: String, value: Int) {
        #expect(PingshuiTitleParser.parseChineseNumeral(text) == value)
    }

    @Test("非法中文数字", arguments: ["", "零", "十十", "一二", "三十一十"])
    func badNumerals(text: String) {
        #expect(PingshuiTitleParser.parseChineseNumeral(text) == nil)
    }

    @Test("韵目标题")
    func titles() throws {
        let parsed = try #require(PingshuiTitleParser.parse("上平聲十三元"))
        #expect(parsed.section == .shangPing)
        #expect(parsed.number == 13)
        #expect(parsed.head == "元")
        #expect(PingshuiTitleParser.parse("平聲一東") == nil)
        #expect(PingshuiTitleParser.parse("上聲") == nil)
    }

    @Test("106 韵目且顺序正确")
    func groups() {
        #expect(dictionary.groups.count == 106)
        #expect(dictionary.groups[0].displayName == "上平·一东")
        #expect(dictionary.groups[15].displayName == "下平·一先")
        #expect(dictionary.groups.last?.displayName == "入声·十七洽")
        #expect(dictionary.groups.filter { $0.tone == .ping }.count == 30)
    }

    @Test("韵目代表字必属本韵：数据源漏列的「先」补回下平一先")
    func headCharacterInGroup() {
        for group in dictionary.groups {
            #expect(dictionary.groupCharacters[group.id].contains(group.headCharacter), "\(group.displayName)")
        }
        #expect(dictionary.groupCharacters[15].first == "先")
        #expect(dictionary.tones(of: "先", in: .pingshui) == [.ping, .ze], "平声先韵，另有去声霰韵一读")
        #expect(dictionary.readings(of: "先", in: .pingshui).map(dictionary.label(of:)).contains("下平·一先"))
        #expect(dictionary.readings(of: "先", in: .cilin).contains { $0.tone == .ping && $0.rhyme.id == 7 })
        #expect(dictionary.characters(in: RhymeKey(book: .pingshui, id: 15)).first == "先")
    }

    @Test("繁体候选缺收时，改查简体字形本身（「幷」数据源作「并」）")
    func ownFormLookup() {
        func labels(_ character: Character) -> Set<String> {
            Set(dictionary.readings(of: character, in: .pingshui).map(dictionary.label(of:)))
        }
        #expect(dictionary.converter.traditionalCandidates("并").contains("幷"))
        #expect(!dictionary.groupCharacters.joined().contains("幷"), "前提：韵书字表未收「幷」")
        #expect(labels("幷") == labels("并"), "查「幷」经简体回退，结果一致")
        #expect(labels("并").contains("下平·八庚"), "并州之并，平声")
        #expect(labels("并").isSuperset(of: labels("併")), "繁体「併」的读音仍保留")
        #expect(dictionary.tones(of: "并", in: .pingshui) == [.ping, .ze])
        #expect(labels("听") == labels("聽"), "繁体候选均已收录时，不取罕用字「听」的读音")
        #expect(labels("坏") == labels("壞"))
        #expect(labels("天") == ["下平·一先"])
    }

    @Test("每个韵目都能映射到词林正韵")
    func cilinCoverage() {
        for group in dictionary.groups {
            #expect(!CilinMapping.possibleSections(forGroupHead: group.headCharacter).isEmpty, "\(group.displayName)")
        }
        #expect(CilinMapping.name(of: 1) == "第一部")
        #expect(CilinMapping.name(of: 19) == "第十九部")
        #expect(CilinMapping.name(of: 20) == "未知部")
    }

    @Test("拆分韵目按今音韵母归部")
    func cilinSplits() {
        func section(_ character: Character) -> Set<Int> {
            Set(dictionary.readings(of: character, in: .cilin).filter { $0.tone == .ping }.map(\.rhyme.id))
        }
        #expect(section("回") == [3])
        #expect(section("来") == [5])
        #expect(section("门") == [6])
        #expect(section("园") == [7])
        #expect(section("涯").contains(10))
        #expect(section("东") == [1])
    }

    @Test("入声字在古韵为仄、在通韵依今音")
    func enteringTone() {
        #expect(dictionary.tones(of: "白", in: .pingshui) == [.ze])
        #expect(dictionary.tones(of: "白", in: .tongyun) == [.ping])
        #expect(dictionary.tones(of: "国", in: .pingshui) == [.ze])
        #expect(dictionary.tones(of: "国", in: .tongyun) == [.ping])
        let ru = dictionary.readings(of: "月", in: .cilin)
        #expect(ru.allSatisfy { (15...19).contains($0.rhyme.id) })
    }

    @Test("简体字通过繁体查表")
    func simplifiedLookup() {
        // 「听」作简体时对应「聽」（青、径），不应取罕用字「听」（yǐn）的读音。
        let names = Set(dictionary.readings(of: "听", in: .pingshui).map { dictionary.displayName(of: $0.rhyme) })
        #expect(names.contains("下平·九青"))
        #expect(!names.contains("上平·十二文"))
        #expect(dictionary.tones(of: "聽", in: .pingshui) == dictionary.tones(of: "听", in: .pingshui))
        #expect(dictionary.tones(of: "长", in: .pingshui) == [.ping, .ze])
    }

    @Test("简转繁字表只列一个异体时，用繁转简字表反查")
    func variantLookup() {
        // 简转繁「为」只给「爲」，平水韵收的是「為」（支韵平声、寘韵去声）。
        #expect(dictionary.tones(of: "为", in: .pingshui) == [.ping, .ze])
        #expect(dictionary.tones(of: "爲", in: .pingshui) == [.ping, .ze])
        #expect(dictionary.tones(of: "為", in: .pingshui) == [.ping, .ze])
        #expect(dictionary.tones(of: "为", in: .cilin) == [.ping, .ze])
        #expect(dictionary.tonePattern(of: "亲为梁王", in: .pingshui) == "中中平中")
    }

    @Test("通韵剔除「一、不」的变调读音")
    func sandhi() {
        #expect(dictionary.tones(of: "一", in: .tongyun) == [.ping])
        #expect(dictionary.syllables(of: "不").map(\.plain).contains("bu"))
        #expect(!dictionary.syllables(of: "不").contains { $0.plain == "bu" && $0.tone == 2 })
        #expect(CharDictionary.parsePinyin("U+4E00: yí,yì  # 一\nbad line\nU+ZZZZ: a").isEmpty)
    }

    @Test("多音字两读")
    func polyphones() {
        #expect(dictionary.tones(of: "看", in: .pingshui) == [.ping, .ze])
        #expect(dictionary.tones(of: "思", in: .pingshui) == [.ping, .ze])
        #expect(dictionary.tones(of: "东", in: .pingshui) == [.ping])
    }

    @Test("平仄串")
    func tonePattern() {
        #expect(dictionary.tonePattern(of: "春，看月𠀋", in: .pingshui) == "平中仄？")
        #expect(dictionary.tonePattern(of: "白", in: .tongyun) == "平")
        #expect(dictionary.tonePattern(of: "", in: .cilin) == "")
    }

    @Test("未收录字返回空")
    func unknown() {
        #expect(dictionary.readings(of: "a", in: .pingshui).isEmpty)
        #expect(dictionary.readings(of: "😀", in: .tongyun).isEmpty)
        #expect(dictionary.tones(of: "，", in: .cilin).isEmpty)
    }

    @Test("韵部字表")
    func rhymeCharacters() {
        let dong = dictionary.characters(in: RhymeKey(book: .pingshui, id: 0))
        #expect(dong.first == "东")
        #expect(dong.contains("风"))
        let tongyunA = dictionary.characters(in: RhymeKey(book: .tongyun, id: 1), tone: .ping)
        #expect(tongyunA.contains("花"))
        #expect(!tongyunA.contains("马"))
        #expect(dictionary.characters(in: RhymeKey(book: .pingshui, id: 999)).isEmpty)
        #expect(dictionary.allKeys(in: .cilin).count == 19)
        #expect(dictionary.allKeys(in: .tongyun).count == 16)
    }
}

@Suite("繁简转换")
struct ScriptConverterTests {
    let converter = CharDictionary.shared.converter

    @Test func conversion() {
        #expect(converter.simplified("風") == "风")
        #expect(converter.simplified("秦川雄帝宅") == "秦川雄帝宅")
        #expect(converter.simplified("綺殿千尋起") == "绮殿千寻起")
        #expect(converter.traditionalCandidates("听") == ["聽"])
        #expect(converter.traditionalCandidates("中") == ["中"])
    }

    @Test("解析时忽略注释与坏行")
    func malformed() {
        let converter = ScriptConverter(traditionalToSimplified: "# c\n風\t风\n壞行\nab\tc\n", simplifiedToTraditional: "风\t風 颩\n")
        #expect(converter.simplified("風") == "风")
        #expect(converter.simplified("壞") == "壞")
        #expect(converter.traditionalCandidates("风") == ["風", "颩"])
    }

    @Test("繁转简字表反查异体")
    func variants() {
        let converter = ScriptConverter(traditionalToSimplified: "為\t为\n爲\t为\n為\t为\n風\t风\n", simplifiedToTraditional: "为\t爲\n")
        #expect(converter.traditionalCandidates("为") == ["爲"])
        #expect(converter.traditionalVariants("为") == ["為", "爲"])
        #expect(converter.traditionalVariants("风") == ["風"])
        #expect(converter.traditionalVariants("中").isEmpty)
        #expect(converter.traditionalVariants("為").isEmpty)
    }
}
