import Foundation
import Testing
@testable import PoetryCore

private let dictionary = CharDictionary.shared

/// 可复现的随机数（SplitMix64）。
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

enum DrillFixtures {
    /// 两首五律（各有两联中间对仗）与一首古诗（中间各联不成律对，应被排除）。
    static func makePack(in directory: TemporaryDirectory, id: String = "drill-pack") throws -> URL {
        let pack = directory.url.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let manifest = """
        {"formatVersion":1,"kind":"corpus","id":"\(id)","name":"对仗测试","version":"1","era":"唐","script":"mixed",
         "files":["poems.json"],"fieldMapping":{"lines":"paragraphs"}}
        """
        try manifest.write(to: pack.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let poems = """
        [
          {"author":"杜甫","title":"春望","paragraphs":["國破山河在，城春草木深。","感時花濺淚，恨別鳥驚心。","烽火連三月，家書抵萬金。","白頭搔更短，渾欲不勝簪。"]},
          {"author":"王維","title":"山居秋暝","paragraphs":["空山新雨後，天氣晚來秋。","明月松間照，清泉石上流。","竹喧歸浣女，蓮動下漁舟。","隨意春芳歇，王孫自可留。"]},
          {"author":"佚名","title":"青青河畔草","paragraphs":["青青河畔草，鬱鬱園中柳。","盈盈樓上女，皎皎當窗牖。","娥娥紅粉妝，纖纖出素手。","昔為倡家女，今為蕩子婦。"]}
        ]
        """
        try poems.write(to: pack.appendingPathComponent("poems.json"), atomically: true, encoding: .utf8)
        return pack
    }
}

@Suite("对仗联统计")
struct ParallelCoupletsTests {
    @Test("中间各联：句数为偶数且不少于八、各句同为五言或七言")
    func middleCouplets() {
        let eight = Array(repeating: "甲乙丙丁戊", count: 8)
        #expect(ParallelCouplets.middleCouplets(of: eight).map(\.index) == [2, 4])
        #expect(ParallelCouplets.middleCouplets(of: Array(repeating: "甲乙丙丁戊己庚", count: 12)).map(\.index) == [2, 4, 6, 8])
        #expect(ParallelCouplets.middleCouplets(of: Array(repeating: "甲乙丙丁戊", count: 6)).isEmpty, "不足八句")
        #expect(ParallelCouplets.middleCouplets(of: Array(repeating: "甲乙丙丁戊", count: 9)).isEmpty, "奇数句")
        #expect(ParallelCouplets.middleCouplets(of: Array(repeating: "甲乙丙丁", count: 8)).isEmpty, "四言")
        #expect(ParallelCouplets.middleCouplets(of: eight.dropLast() + ["甲乙丙丁戊己庚"]).isEmpty, "长短不一")
        #expect(ParallelCouplets.middleCouplets(of: []).isEmpty)
    }

    @Test("须成律对，且出句仄收、对句平收")
    func regulatedPair() {
        #expect(ParallelCouplets.isRegulatedPair("感时花溅泪", "恨别鸟惊心", dictionary: dictionary))
        #expect(!ParallelCouplets.isRegulatedPair("恨别鸟惊心", "感时花溅泪", dictionary: dictionary), "出句平收")
        #expect(!ParallelCouplets.isRegulatedPair("盈盈楼上女", "皎皎当窗牖", dictionary: dictionary), "对句仄收")
        #expect(!ParallelCouplets.isRegulatedPair("感时花溅泪", "感时花溅泪", dictionary: dictionary), "不相对")
    }

    @Test("同位字对与双字词对计数：两边相同的位置不计，字数不同的联跳过")
    func countPairs() {
        let counts = ParallelCouplets.countPairs([(left: "明月松", right: "清风松"), (left: "风", right: "月"), (left: "甲乙", right: "丙")])
        #expect(counts[PairKey("月", "风")] == 2, "无序：月风与风月同计")
        #expect(counts[PairKey("明", "清")] == 1)
        #expect(counts[PairKey("松", "松")] == nil)
        #expect(counts[PairKey("明月", "清风")] == 1)
        #expect(counts[PairKey("月松", "风松")] == 1)
        #expect(counts[PairKey("甲", "丙")] == nil)
    }

    @Test("同位相对的位置：哪边在出句均可，与计数方式一致")
    func alignedPositions() {
        let aligned = { (text: String, counterpart: String, left: String, right: String) in
            ParallelCouplets.alignedPositions(of: text, with: counterpart, left: left, right: right)
        }
        #expect(aligned("月", "泉", "明月松间照", "清泉石上流") == [1])
        #expect(aligned("泉", "月", "明月松间照", "清泉石上流") == [1], "对句一边亦可")
        #expect(aligned("明月", "清泉", "明月松间照", "清泉石上流") == [0])
        #expect(aligned("间照", "上流", "明月松间照", "清泉石上流") == [3], "末两字")
        #expect(aligned("月", "流", "明月松间照", "清泉石上流").isEmpty, "不同位")
        #expect(aligned("风", "月", "风风", "月月") == [0, 1], "每个位置都算")
        #expect(aligned("月", "月", "明月", "清月").isEmpty, "两边相同不算")
        #expect(aligned("明月", "泉", "明月松间照", "清泉石上流").isEmpty, "不等长")
        #expect(aligned("", "", "明月", "清泉").isEmpty)
        #expect(aligned("月", "泉", "明月松", "清泉").isEmpty, "两句不等长")
        #expect(aligned("明月松", "清泉石", "明月", "清泉").isEmpty, "比句子长")
    }

    @Test("由语料重建统计；语料变动后需重建")
    func buildFromCorpus() async throws {
        let directory = try TemporaryDirectory()
        let index = try CorpusIndex(url: directory.url.appendingPathComponent("corpus.sqlite"))
        #expect(try await !index.isParallelIndexCurrent())
        #expect(try await index.buildParallelIndex() == 0, "没有语料")
        #expect(try await index.isParallelIndexCurrent())

        _ = try await index.importPack(at: try DrillFixtures.makePack(in: directory))
        #expect(try await !index.isParallelIndexCurrent())
        #expect(try await index.buildParallelIndex() == 4, "两首五律各两联；古诗不成律对")
        let couplets = try await index.parallelCouplets()
        #expect(couplets.map(\.left) == ["感时花溅泪", "烽火连三月", "明月松间照", "竹喧归浣女"])
        #expect(couplets.map(\.lineIndex) == [2, 4, 2, 4])
        let counts = try await index.pairCounts([PairKey("月", "泉"), PairKey("明月", "清泉"), PairKey("月", "雪")])
        #expect(counts[PairKey("月", "泉")] == 1)
        #expect(counts[PairKey("明月", "清泉")] == nil, "只出现一次的词对不保存")
        #expect(counts[PairKey("月", "雪")] == nil)
        #expect(try await index.parallelCounterparts(of: "月").map(\.text) == ["泉", "金"])
        #expect(try await index.parallelCounterparts(of: "").isEmpty)
        #expect(try await index.parallelCounterparts(of: "月", limit: 0).isEmpty)
        let moon = try await index.parallelExamples(of: "月", with: "泉")
        #expect(moon.total == 1)
        #expect(moon.couplets.map(\.left) == ["明月松间照"])
        #expect(try await index.parallelExamples(of: "金", with: "月").couplets.map(\.right) == ["家书抵万金"], "哪边在出句均可")
        #expect(try await index.parallelExamples(of: "月", with: "流").total == 0, "同在一联但不同位")
        let limited = try await index.parallelExamples(of: "月", with: "泉", limit: 0)
        #expect(limited.total == 1 && limited.couplets.isEmpty, "总数不受 limit 影响")
        #expect(try await index.parallelExamples(of: "月", with: "月").total == 0)
        #expect(try await index.parallelExamples(of: "", with: "").total == 0)
        #expect(try await index.parallelExamples(of: "明月", with: "泉").total == 0)

        try await index.setEnabled(false, packID: "drill-pack")
        #expect(try await !index.isParallelIndexCurrent(), "停用语料包后需重建")
        #expect(try await index.buildParallelIndex() == 0)
        #expect(try await index.parallelCouplets().isEmpty)
    }
}

@Suite("对仗评分")
struct CoupletScorerTests {
    private func score(_ prompt: String, _ answer: String, _ counts: [PairKey: Int] = [:],
                       known: String? = nil) throws -> CoupletScore {
        try CoupletScorer.score(prompt: prompt, answer: answer, dictionary: dictionary, pairCounts: counts, knownSource: known)
    }

    @Test("没有汉字时报错")
    func empty() {
        #expect(throws: CoupletScoreError.emptyPrompt) { try score("，", "风") }
        #expect(throws: CoupletScoreError.emptyAnswer) { try score("月", " ") }
        #expect(throws: CoupletScoreError.emptyAnswer) { try score("月", "") }
    }

    @Test("硬性条件：字数不同、出对重字、末字平仄不相对")
    func hardRules() throws {
        let length = try score("明月", "风")
        #expect(length.level == .fail)
        #expect(length.reasons == ["字数不同：出 2 字，对 1 字"])
        #expect(length.positions.isEmpty)

        let repeated = try score("青山", "青水", [PairKey("山", "水"): 9])
        #expect(repeated.level == .fail)
        #expect(repeated.reasons.first == "出对重字：「青」")

        let sameTone = try score("东", "西", [PairKey("东", "西"): 99])
        #expect(sameTone.level == .fail)
        #expect(sameTone.reasons == ["末字平仄不相对：「东」「西」同为平声"], "末字已报，不再重复列为要位")
        #expect(try score("風", "月").level != .fail, "繁体照常判断")
    }

    @Test("对词：要位平仄相对且字字常对为工；多数见过为可；否则为宽")
    func wordLevels() throws {
        let common: [PairKey: Int] = [PairKey("明", "清"): 3, PairKey("月", "风"): 300]
        let strict = try score("明月", "清风", common)
        #expect(strict.level == .strict)
        #expect(strict.mode == .word)
        #expect(strict.meter == nil)
        #expect(strict.positions.map(\.affinity) == [.common, .common])
        #expect(strict.positions.map(\.pairCount) == [3, 300])
        #expect(strict.positions.map(\.isKeyPosition) == [false, true])

        let fair = try score("明月", "清风", [PairKey("明", "清"): 2, PairKey("月", "风"): 300])
        #expect(fair.level == .fair, "一字只是见过")
        #expect(fair.positions.first?.affinity == .seen)

        let halfSeen = try score("明月", "清风", [PairKey("月", "风"): 1])
        #expect(halfSeen.level == .fair, "两字中一字见过，恰好一半")
        #expect(halfSeen.reasons.contains("律诗对仗中未见：「明—清」"))

        let loose = try score("明月", "清风")
        #expect(loose.level == .loose)
        #expect(loose.positions.allSatisfy { $0.affinity == .unseen })
    }

    @Test("门槛随对仗联总数换算，不低于基准")
    func thresholds() throws {
        #expect(CoupletScorer.Thresholds.scaled(coupletCount: 0) == .baseline)
        #expect(CoupletScorer.Thresholds.scaled(coupletCount: -5) == .baseline)
        #expect(CoupletScorer.Thresholds.scaled(coupletCount: 64_412) == .baseline)
        #expect(CoupletScorer.Thresholds.scaled(coupletCount: 1_008_742)
                == CoupletScorer.Thresholds(common: 48, commonWordPair: 31, seen: 4))

        let large = CoupletScorer.Thresholds(common: 48, commonWordPair: 31, seen: 4)
        let counts: [PairKey: Int] = [PairKey("明", "清"): 47, PairKey("月", "风"): 3]
        let scored = try CoupletScorer.score(prompt: "明月", answer: "清风", dictionary: dictionary, pairCounts: counts,
                                             thresholds: large)
        #expect(scored.positions.map(\.affinity) == [.seen, .unseen], "47 次不到常对，3 次不到见过")
        var boosted = counts
        boosted[PairKey("明月", "清风")] = 31
        #expect(try CoupletScorer.score(prompt: "明月", answer: "清风", dictionary: dictionary, pairCounts: boosted,
                                        thresholds: large).level == .strict)
    }

    @Test("相邻两字的词对常见时，两字都算常对")
    func wordPairBoost() throws {
        let boosted = try score("明月", "清风", [PairKey("明月", "清风"): 2])
        #expect(boosted.positions.map(\.affinity) == [.common, .common])
        #expect(boosted.level == .strict)
        let once = try score("明月", "清风", [PairKey("明月", "清风"): 1])
        #expect(once.level == .loose, "只出现一次不算")
    }

    @Test("同类相对：数目、颜色、方位、干支、叠字")
    func categories() throws {
        let colors = try score("红花", "白草")
        #expect(colors.positions.first?.category == "颜色")
        #expect(colors.positions.first?.affinity == .common)
        #expect(colors.level == .fair, "草花未见，对词不到工")
        #expect(try score("三山", "五岳").positions.first?.category == "数目")
        #expect(try score("东", "北").positions.first?.category == "方位")
        #expect(try score("甲", "子").positions.first?.category == "干支")
        #expect(WordCategory.of("红") == .color)
        #expect(WordCategory.of("月") == nil)

        let doubled = try score("隐隐", "濛濛")
        #expect(doubled.positions.map(\.category) == ["叠字", "叠字"])
        #expect(doubled.level == .strict)
        let mismatch = try score("隐隐", "濛雾", [PairKey("隐", "濛"): 9, PairKey("隐", "雾"): 9])
        #expect(mismatch.reasons.contains("第 1、2 字叠字不相对"))
        #expect(mismatch.level != .strict, "叠字不对不能为工")
    }

    @Test("要位平仄：偶数位与末字；不相对的要位列出，不能为工")
    func keyPositions() throws {
        #expect(CoupletScorer.keyPositions(prompt: "月", length: 1) == [0])
        #expect(CoupletScorer.keyPositions(prompt: "三尺剑", length: 3) == [1, 2])
        #expect(CoupletScorer.keyPositions(prompt: "甲乙丙丁", length: 4) == [1, 3])
        #expect(CoupletScorer.keyPositions(prompt: "十月塞边，飒飒寒霜惊戍旅", length: 11) == [3, 10], "长对取各分句末字")
        #expect(CoupletScorer.keyPositions(prompt: "甲乙丙丁戊己庚辛", length: 8) == [1, 3, 5, 7], "长对没有分句时按偶数位")
        #expect(CoupletScorer.keyPositions(prompt: "", length: 0).isEmpty)

        let miss = try score("江东", "海西", [PairKey("江", "海"): 9, PairKey("东", "西"): 9])
        #expect(miss.level == .fail, "末字同为平声")
        let polyphonic = try score("天高", "日长", [PairKey("天", "日"): 9, PairKey("高", "长"): 9])
        #expect(polyphonic.positions.last?.tone == .opposed, "「长」有仄声一读，可与「高」相对")
        #expect(polyphonic.positions.last?.answerTones == [.ping, .ze])
        let middle = try score("三尺剑", "六钧弓", [PairKey("三", "六"): 9, PairKey("尺", "钧"): 9, PairKey("剑", "弓"): 9])
        #expect(middle.level == .strict)
        let middleMiss = try score("三尺剑", "六寸弓", [PairKey("三", "六"): 9, PairKey("尺", "寸"): 9, PairKey("剑", "弓"): 9])
        #expect(middleMiss.reasons.contains("要位平仄不相对：第 2 字"))
        #expect(middleMiss.level == .fair)
    }

    @Test("对句：五七言看律对；成律对且至多一字不是常对为工")
    func lines() throws {
        let all: [PairKey: Int] = [PairKey("明", "清"): 9, PairKey("月", "泉"): 9, PairKey("松", "石"): 9, PairKey("间", "上"): 9]
        let strict = try score("明月松间照", "清泉石上流", all)
        #expect(strict.mode == .line)
        #expect(strict.meter == .opposed)
        #expect(strict.level == .strict, "末字「照—流」未见也可为工")
        #expect(strict.reasons.first == "成律对，至多一字不是常对")

        var two = all
        two[PairKey("间", "上")] = 1
        #expect(try score("明月松间照", "清泉石上流", two).level == .fair, "两字不是常对")

        let notRegular = try score("明月松间照", "清泉石头流", all)
        #expect(notRegular.meter != .opposed)
        #expect(notRegular.reasons.contains("不成律对：对句不是律句"))
        #expect(notRegular.level == .loose)

        // 二四字相对但末字同为仄声：不算律对，也不重复说明。
        let sameEnd = try score("北固一何峭", "清风明月照")
        #expect(sameEnd.level == .fail)
        #expect(sameEnd.meter == .notOpposed)
        #expect(!sameEnd.reasons.contains { $0.hasPrefix("不成律对") })
        #expect(sameEnd.reasons.first == "末字平仄不相对：「峭」「照」同为仄声")
    }

    @Test("与典籍一致时注明出处：平仄合则为工，否则为可")
    func knownSource() throws {
        let known = try score("三尺剑", "六钧弓", known: "声律启蒙·一、東")
        #expect(known.level == .strict)
        #expect(known.reasons.first == "见于声律启蒙·一、東")
        #expect(known.knownSource == "声律启蒙·一、東")
        let weak = try score("三尺剑", "六寸弓", known: "某书")
        #expect(weak.level == .fair)
        #expect(try score("东", "西", known: "某书").level == .fail, "硬性条件优先")
    }

    @Test("统计键：各位置字对与相邻两字词对，繁简归一")
    func lookupKeys() {
        let converter = dictionary.converter
        #expect(CoupletScorer.lookupKeys(prompt: "明月", answer: "清風", converter: converter)
                == [PairKey("明", "清"), PairKey("月", "风"), PairKey("明月", "清风")])
        #expect(CoupletScorer.lookupKeys(prompt: "明月", answer: "风", converter: converter).isEmpty)
        #expect(CoupletScorer.lookupKeys(prompt: "", answer: "", converter: converter).isEmpty)
        #expect(PairKey("风", "月") == PairKey("月", "风"))
    }
}

@Suite("对仗题库")
struct DrillPoolTests {
    private let converter = dictionary.converter

    private var pool: DrillPool {
        DrillPool(items: [
            DrillItem(left: "雲", right: "雨", source: .primer(.shengLvQiMeng, sectionIndex: 0)),
            DrillItem(left: "來鴻", right: "去燕", source: .primer(.shengLvQiMeng, sectionIndex: 0)),
            DrillItem(left: "天", right: "地", source: .primer(.liwengDuiyun, sectionIndex: 0)),
            DrillItem(left: "云", right: "风", source: .yunfu(head: "風", groupID: 0)),
            DrillItem(left: "明月松间照", right: "清泉石上流", source: .corpus(workID: 1, lineIndex: 2)),
            DrillItem(left: "十月塞邊，颯颯寒霜驚戍旅", right: "三冬江上，漫漫朔雪冷漁翁", source: .primer(.liwengDuiyun, sectionIndex: 0)),
            DrillItem(left: "甲", right: "乙丙", source: .corpus(workID: 2, lineIndex: 0)),
            DrillItem(left: "，", right: "。", source: .corpus(workID: 2, lineIndex: 0)),
            DrillItem(left: "雲", right: "云", source: .corpus(workID: 2, lineIndex: 0)),
        ], converter: converter)
    }

    @Test("字数不同、没有汉字或两边相同的不入题库")
    func filtering() {
        #expect(pool.count == 6)
        #expect(pool.count(of: .shengLv) == 2)
        #expect(pool.count(of: .liweng) == 2)
        #expect(pool.count(of: .corpus) == 1)
        #expect(pool.count(of: .liweng, mode: .word) == 1)
        #expect(pool.count(of: .liweng, mode: .line) == 1)
        #expect(pool.count(of: .yunfu, mode: .line) == 0)
    }

    @Test("题目标识：按字数分模式，繁简归一，只取汉字")
    func keys() {
        #expect(DrillPool.key(for: "來鴻", converter: converter) == "word|来鸿")
        #expect(DrillPool.key(for: "来鸿，", converter: converter) == "word|来鸿")
        #expect(DrillPool.key(for: "明月松间照", converter: converter) == "line|明月松间照")
        #expect(DrillPool.key(for: "，。", converter: converter) == nil)
        #expect(DrillMode(length: 4) == .word)
        #expect(DrillMode(length: 5) == .line)
    }

    @Test("只有出自语料的才有作品 id，只有出自佩文对语的才有韵字")
    func sourceAccessors() {
        #expect(DrillItemSource.yunfu(head: "愁", groupID: 3).yunfuHead == "愁")
        #expect(DrillItemSource.corpus(workID: 1, lineIndex: 2).yunfuHead == nil)
        #expect(DrillItemSource.primer(.shengLvQiMeng, sectionIndex: 0).yunfuHead == nil)
        #expect(DrillItemSource.corpus(workID: 42, lineIndex: 2).corpusWorkID == 42)
        #expect(DrillItemSource.corpus(workID: 0, lineIndex: 0).corpusWorkID == 0)
        #expect(DrillItemSource.primer(.shengLvQiMeng, sectionIndex: 0).corpusWorkID == nil)
        #expect(DrillItemSource.primer(.liwengDuiyun, sectionIndex: 3).corpusWorkID == nil)
        #expect(DrillItemSource.yunfu(head: "東", groupID: 0).corpusWorkID == nil)
    }

    @Test("按模式、来源、字数抽题；对句只以出句出题")
    func draw() {
        var generator = SeededGenerator(state: 7)
        for _ in 0..<30 {
            let question = pool.draw(DrillOptions(mode: .line), answeredKeys: [], using: &generator)
            #expect(question.map { ["明月松间照", "十月塞邊，颯颯寒霜驚戍旅"].contains($0.prompt) } == true)
        }
        var prompts = Set<String>()
        for _ in 0..<60 {
            if let question = pool.draw(DrillOptions(mode: .word, sources: [.shengLv]), answeredKeys: [], using: &generator) {
                prompts.insert(question.prompt)
                #expect(question.mode == .word)
                #expect(question.source.kind == .shengLv)
            }
        }
        #expect(prompts == ["雲", "雨", "來鴻", "去燕"], "对词两边都会出")
        let two = pool.draw(DrillOptions(mode: .word, length: .exactly(2)), answeredKeys: [], using: &generator)
        #expect(["來鴻", "去燕"].contains(two?.prompt ?? ""))
        let long = pool.draw(DrillOptions(mode: .line, length: .long), answeredKeys: [], using: &generator)
        #expect(long?.reference == "三冬江上，漫漫朔雪冷漁翁")
        #expect(long?.key == "line|十月塞边飒飒寒霜惊戍旅")
        #expect(pool.draw(DrillOptions(mode: .word, length: .exactly(3)), answeredKeys: [], using: &generator) == nil)
        #expect(pool.draw(DrillOptions(mode: .word, sources: []), answeredKeys: [], using: &generator) == nil)
    }

    @Test("按练习记录筛选：只出新题、只出答过的")
    func history() {
        var generator = SeededGenerator(state: 11)
        let options = DrillOptions(mode: .word, sources: [.liweng])
        let answered: Set<String> = ["word|天"]
        for _ in 0..<20 {
            var unanswered = options
            unanswered.history = .unanswered
            #expect(pool.draw(unanswered, answeredKeys: answered, using: &generator)?.prompt == "地")
            var only = options
            only.history = .answered
            #expect(pool.draw(only, answeredKeys: answered, using: &generator)?.prompt == "天")
        }
        var none = options
        none.history = .unanswered
        #expect(pool.draw(none, answeredKeys: ["word|天", "word|地"], using: &generator) == nil)
        none.history = .answered
        #expect(pool.draw(none, answeredKeys: [], using: &generator) == nil)
    }

    @Test("参考答案：两边都查，繁简不拘，同一对文字只取一次")
    func references() {
        let cloud = pool.references(for: "云")
        #expect(cloud.map(\.counterpart) == ["雨", "风"])
        #expect(cloud.first?.source == .primer(.shengLvQiMeng, sectionIndex: 0))
        #expect(pool.references(for: "去燕").map(\.counterpart) == ["來鴻"])
        #expect(pool.references(for: "无此词").isEmpty)
        #expect(pool.references(for: "").isEmpty)
    }
}

@Suite("练习记录")
struct DrillRecordTests {
    @Test("保存、按模式与题目查询、答过的题、删除")
    func records() throws {
        let directory = try TemporaryDirectory()
        let store = try LibraryStore(url: directory.url.appendingPathComponent("library.sqlite"))
        #expect(try store.drillAttempts().isEmpty)
        #expect(try store.answeredDrillKeys().isEmpty)
        let first = DrillAttempt(mode: .word, questionKey: "word|云", prompt: "雲", answer: "雨", level: .strict,
                                 source: "声律启蒙·一、東", createdAt: Date(timeIntervalSince1970: 100))
        let second = DrillAttempt(mode: .word, questionKey: "word|云", prompt: "云", answer: "风", level: .fair,
                                  source: "佩文", createdAt: Date(timeIntervalSince1970: 200))
        let line = DrillAttempt(mode: .line, questionKey: "line|明月松间照", prompt: "明月松间照", answer: "清泉石上流",
                                level: .loose, source: "王维", createdAt: Date(timeIntervalSince1970: 150))
        for attempt in [first, second, line] { try store.save(attempt) }

        #expect(try store.drillAttempts().map(\.id) == [second.id, line.id, first.id], "新的在前")
        #expect(try store.drillAttempts(mode: .word).map(\.id) == [second.id, first.id])
        #expect(try store.drillAttempts(questionKey: "word|云").map(\.answer) == ["风", "雨"])
        #expect(try store.drillAttempts(questionKey: "word|无").isEmpty)
        #expect(try store.answeredDrillKeys() == ["word|云", "line|明月松间照"])
        let loaded = try #require(try store.drillAttempts(mode: .line).first)
        #expect(loaded == line, "各字段原样读回")

        try store.deleteDrillAttempt(id: second.id)
        #expect(try store.drillAttempts(questionKey: "word|云").map(\.id) == [first.id])
        try store.deleteDrillAttempt(id: UUID())
        #expect(try store.drillAttempts().count == 2, "删除不存在的记录不报错")
    }
}

@Suite("对仗训练服务")
struct DrillServiceTests {
    private func makeService(_ directory: TemporaryDirectory) throws -> PoetryService {
        try PoetryService(paths: AppPaths(root: directory.url.appendingPathComponent("data")))
    }

    @Test("没有语料时题库只有对韵蒙书；导入语料后自动统计并加入律诗")
    func prepare() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        let primerOnly = try await service.prepareDrill()
        #expect(primerOnly.count(of: .shengLv) > 500)
        #expect(primerOnly.count(of: .liweng) > 500)
        #expect(primerOnly.count(of: .corpus) == 0)
        #expect(primerOnly.count(of: .yunfu) == 0, "未下载佩文韵府")
        #expect(try await service.drawDrillQuestion(DrillOptions(mode: .line, sources: [.corpus])) == nil)

        _ = try await service.installPack(from: try DrillFixtures.makePack(in: directory))
        let withCorpus = try await service.prepareDrill()
        #expect(withCorpus.count(of: .corpus) == 4)
        let question = try #require(try await service.drawDrillQuestion(DrillOptions(mode: .line, sources: [.corpus])))
        #expect(["感时花溅泪", "烽火连三月", "明月松间照", "竹喧归浣女"].contains(question.prompt))
        let source = try await service.describe(question.source)
        #expect(source.contains("《春望》") || source.contains("《山居秋暝》"))
        #expect(try await service.describe(.corpus(workID: 9_999, lineIndex: 0)) == "语料")
        #expect(try await service.describe(.primer(.liwengDuiyun, sectionIndex: 0)) == "笠翁对韵·一、東")
        #expect(try await service.describe(.primer(.liwengDuiyun, sectionIndex: 99)) == "笠翁对韵·?")
        #expect(try await service.describe(.yunfu(head: "東", groupID: 0)) == "佩文韵府对语·東（上平·一东）")

        try await service.corpus.setEnabled(false, packID: "drill-pack")
        #expect(try await service.prepareDrill().count(of: .corpus) == 0, "语料变动后题库随之更新")
    }

    @Test("评分：与原书一致时注明出处；附参考与律诗常对")
    func evaluate() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        _ = try await service.installPack(from: try DrillFixtures.makePack(in: directory))

        let cloud = try await service.evaluateCouplet(prompt: "云", answer: "雨")
        #expect(cloud.score.level == .strict)
        #expect(cloud.score.knownSource == "声律启蒙·一、東")
        #expect(cloud.references.first?.counterpart == "雨")

        let moon = try await service.evaluateCouplet(prompt: "月", answer: "泉")
        #expect(moon.score.knownSource == nil)
        #expect(moon.score.positions.first?.pairCount == 1)
        #expect(moon.commonCounterparts.map(\.text) == ["泉", "金"])

        let line = try await service.evaluateCouplet(prompt: "明月松间照", answer: "清泉石上流")
        #expect(line.score.knownSource == "〔唐〕王维《山居秋暝》")
        #expect(line.commonCounterparts.isEmpty, "三字以上不附常对")

        await #expect(throws: CoupletScoreError.emptyAnswer) { try await service.evaluateCouplet(prompt: "云", answer: "，") }
        await #expect(throws: CoupletScoreError.emptyPrompt) { try await service.evaluateCouplet(prompt: "", answer: "雨") }

        let cloudOnly = try await service.coupletReferences(for: "雲")
        #expect(cloudOnly.references.first?.counterpart == "雨", "繁体出题也能查到")
        let moonOnly = try await service.coupletReferences(for: "月")
        #expect(moonOnly.commonCounterparts.map(\.text) == ["泉", "金"])
        await #expect(throws: CoupletScoreError.emptyPrompt) { try await service.coupletReferences(for: "。") }
    }

    @Test("常对的用例：附出处与位置，繁简不论")
    func examples() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        _ = try await service.installPack(from: try DrillFixtures.makePack(in: directory))
        _ = try await service.prepareDrill()

        let moon = try await service.parallelExamples(of: "月", with: "泉")
        #expect(moon.total == 1)
        #expect(moon.examples.first?.source == "〔唐〕王维《山居秋暝》")
        #expect(moon.examples.first?.positions == [1])
        let words = try await service.parallelExamples(of: "松間", with: "石上")
        #expect(words.examples.map(\.couplet.left) == ["明月松间照"], "繁体输入")
        #expect(words.examples.first?.positions == [2])
        #expect(try await service.parallelExamples(of: "月", with: "雪").total == 0)
        #expect(try await service.parallelExamples(of: "，", with: "。").total == 0, "没有汉字")
    }

    @Test("记录作答后，「只出新题」不再出，「只出答过的」只出它")
    func recordAndFilter() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        _ = try await service.installPack(from: try DrillFixtures.makePack(in: directory))
        var options = DrillOptions(mode: .line, sources: [.corpus], history: .unanswered)
        var seen = Set<String>()
        while let question = try await service.drawDrillQuestion(options) {
            #expect(seen.insert(question.key).inserted, "答过的不再出")
            let attempt = try await service.recordDrill(question, answer: "某句", level: .loose)
            #expect(attempt.source.contains("《"))
            #expect(attempt.questionKey == question.key)
        }
        #expect(seen.count == 4)
        options.history = .answered
        #expect(try await service.drawDrillQuestion(options) != nil)
        #expect(try service.library.drillAttempts(mode: .line).count == 4)
    }
}
