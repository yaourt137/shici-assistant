import Foundation
import Testing
@testable import PoetryCore

enum DedupFixtures {
    struct Poem {
        let title: String
        let author: String
        let lines: [String]
    }

    static func pack(in directory: TemporaryDirectory, id: String, priority: Int? = nil, poems: [Poem]) throws -> URL {
        let pack = directory.url.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        var manifest: [String: Any] = ["formatVersion": 1, "kind": "corpus", "id": id, "name": id, "era": "唐",
                                       "files": ["poems.json"], "fieldMapping": ["lines": "paragraphs"]]
        if let priority { manifest["priority"] = priority }
        try JSONSerialization.data(withJSONObject: manifest).write(to: pack.appendingPathComponent("manifest.json"))
        let records = poems.map { ["title": $0.title, "author": $0.author, "paragraphs": $0.lines] as [String: Any] }
        try JSONSerialization.data(withJSONObject: records).write(to: pack.appendingPathComponent("poems.json"))
        return pack
    }

    static let packA: [Poem] = [
        Poem(title: "春望", author: "甲", lines: ["国破山河在，城春草木深。", "感时花溅泪，恨别鸟惊心。"]),
        Poem(title: "秋兴", author: "乙", lines: ["玉露凋伤枫树林，巫山巫峡气萧森。", "江间波浪兼天涌，塞上风云接地阴。"]),
        Poem(title: "重出", author: "丙", lines: ["国破山河在，城春草木深。", "感时花溅泪，恨别鸟惊心。"]),
        Poem(title: "怀人", author: "丁", lines: ["江南春水碧，塞北暮云黄。", "独坐思千里，长歌望一方。"]),
    ]

    static let packB: [Poem] = [
        // 繁体、标点不同，作者不同：全文相同即算重复。
        Poem(title: "春望（无名氏本）", author: "无名氏", lines: ["國破山河在，城春草木深；感時花濺淚，恨別鳥驚心。"]),
        // 同作者，四句中三句相同：异文。
        Poem(title: "秋兴异文", author: "乙", lines: ["玉露凋伤枫树林，巫山巫峡气萧森。", "江间波浪连天涌，塞上风云接地阴。"]),
        // 三句相同但作者不同：不算重复。
        Poem(title: "怀人", author: "戊", lines: ["江南春水碧，塞北暮云黄。", "独坐思千里，高歌望一方。"]),
        // 同作者但只有两句相同：不算重复。
        Poem(title: "秋兴又一首", author: "乙", lines: ["白露横秋水，青山入远空。", "江间波浪兼天涌，塞上风云接地阴。"]),
        Poem(title: "缺字", author: "己", lines: ["鬌□一窝绿，春风二月寒。"]),
    ]
}

@Suite("跨语料包去重")
struct CorpusDedupTests {
    private func makeIndex(_ directory: TemporaryDirectory) throws -> CorpusIndex {
        try CorpusIndex(url: directory.url.appendingPathComponent("corpus.sqlite"))
    }

    private func titles(_ lines: [CorpusLine]) -> [String] {
        lines.compactMap(\.title).sorted()
    }

    @Test("全文相同（不论作者）或同作者七成句同算重复；查询只用优先的一份")
    func detectAndHide() async throws {
        let directory = try TemporaryDirectory()
        let index = try makeIndex(directory)
        let first = try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-a", poems: DedupFixtures.packA))
        #expect(first.duplicateCount == 0, "包内重出不处理")
        let frequencyBefore = try await index.characterFrequencies()["破"]
        let second = try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-b", priority: 10,
                                                                           poems: DedupFixtures.packB))
        #expect(second.duplicateCount == 2)
        let packs = try await index.packs()
        #expect(packs.map(\.duplicateCount) == [0, 2])
        #expect(packs.map(\.priority) == [0, 10])

        #expect(titles(try await index.usages(of: "巫峡")) == ["秋兴"], "异文版本被隐藏")
        #expect(titles(try await index.usages(of: "江间波浪")) == ["秋兴", "秋兴又一首"])
        #expect(titles(try await index.usages(of: "塞北暮云")) == ["怀人", "怀人"], "作者不同的不算重复")
        #expect(try await index.related(to: "国破山河在").allSatisfy { $0.title != "春望（无名氏本）" })
        let source = try #require(try await index.findSource(of: "国破山河在"))
        #expect(source.title != "春望（无名氏本）")

        #expect(try await index.characterFrequencies()["破"] == frequencyBefore, "重复作品不计字频")
        let pair = try await index.candidates(for: SlotConstraint(slots: [.any, .any], rhyme: nil, book: .pingshui), limit: 500)
        #expect(pair.first { $0.text == "山河" }?.frequency == 2, "春望、重出各一次，无名氏本不计")
        let line = try await index.candidates(for: SlotConstraint(slots: Array(repeating: .any, count: 5), rhyme: nil, book: .pingshui),
                                              limit: 500)
        #expect(line.first { $0.text == "国破山河在" }?.frequency == 2)
    }

    @Test("其他版本：保留的那份在前；包内重出不互列")
    func versions() async throws {
        let directory = try TemporaryDirectory()
        let index = try makeIndex(directory)
        try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-a", poems: DedupFixtures.packA))
        try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-b", priority: 10, poems: DedupFixtures.packB))
        let spring = try #require(try await index.usages(of: "国破").first { $0.title == "春望" })
        let others = try await index.versions(of: spring.workID)
        #expect(others.map(\.title) == ["春望（无名氏本）"])
        #expect(others.map(\.isPrimary) == [false])
        #expect(others.first?.author == "无名氏")
        let hiddenID = try #require(others.first?.id)
        let fromHidden = try await index.versions(of: hiddenID)
        #expect(fromHidden.map(\.title) == ["春望"])
        #expect(fromHidden.first?.isPrimary == true)
        #expect(fromHidden.first?.packName == "dup-a")
        let repeated = try #require(try await index.usages(of: "国破").first { $0.title == "重出" })
        #expect(try await index.versions(of: repeated.workID).isEmpty)
        #expect(try await index.versions(of: 999_999).isEmpty)
    }

    @Test("停用或删除优先的语料包后，其余版本恢复；重新导入后再次隐藏")
    func enableAndDelete() async throws {
        let directory = try TemporaryDirectory()
        let index = try makeIndex(directory)
        let packA = try DedupFixtures.pack(in: directory, id: "dup-a", poems: DedupFixtures.packA)
        try await index.importPack(at: packA)
        try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-b", priority: 10, poems: DedupFixtures.packB))

        try await index.setEnabled(false, packID: "dup-a")
        #expect(try await index.packs().map(\.duplicateCount) == [0, 0])
        #expect(titles(try await index.usages(of: "巫峡")) == ["秋兴异文"])
        #expect(try await index.characterFrequencies()["破"] == 1)

        try await index.setEnabled(true, packID: "dup-a")
        #expect(titles(try await index.usages(of: "巫峡")) == ["秋兴"])

        try await index.deletePack(id: "dup-a")
        #expect(try await index.packs().map(\.duplicateCount) == [0])
        #expect(titles(try await index.usages(of: "巫峡")) == ["秋兴异文"])
        try await index.importPack(at: packA)
        #expect(try await index.packs().first { $0.id == "dup-b" }?.duplicateCount == 2, "后导入但优先级高，仍保留它的版本")
    }

    @Test("优先级相同时先导入的优先")
    func samePriority() async throws {
        let directory = try TemporaryDirectory()
        let index = try makeIndex(directory)
        try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-b", poems: DedupFixtures.packB))
        try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-a", poems: DedupFixtures.packA))
        let counts = Dictionary(uniqueKeysWithValues: try await index.packs().map { ($0.id, $0.duplicateCount) })
        #expect(counts == ["dup-b": 0, "dup-a": 3], "春望、重出与秋兴都让给先导入的包")
    }

    @Test("旧版作品没有全文哈希时补算后照常比对")
    func backfill() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("corpus.sqlite")
        let index = try CorpusIndex(url: url)
        try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-a", poems: DedupFixtures.packA))
        let raw = try SQLiteDatabase(path: url.path)
        try raw.execute("UPDATE works SET text_hash = NULL")
        let report = try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-b", priority: 10,
                                                                           poems: DedupFixtures.packB))
        #expect(report.duplicateCount == 2)
        #expect(try raw.query("SELECT COUNT(*) FROM works WHERE text_hash IS NULL") { $0.int(0) } == [0])
    }

    @Test("缺字符号占一个字位：保留在句中，不作候选、不计字频")
    func missingCharacter() async throws {
        let directory = try TemporaryDirectory()
        let index = try makeIndex(directory)
        try await index.importPack(at: try DedupFixtures.pack(in: directory, id: "dup-b", poems: DedupFixtures.packB))
        #expect(try await index.usages(of: "一窝").map(\.text) == ["鬌□一窝绿"])
        #expect(try await index.characterFrequencies()["□"] == nil)
        let lines = try await index.candidates(for: SlotConstraint(slots: Array(repeating: .any, count: 5), rhyme: nil, book: .pingshui),
                                               limit: 500)
        #expect(!lines.contains { $0.text.contains("□") })
        #expect(lines.contains { $0.text == "春风二月寒" })
        let grams = try await index.candidates(for: SlotConstraint(slots: [.any, .any], rhyme: nil, book: .pingshui), limit: 500)
        #expect(!grams.contains { $0.text.contains("□") })
        #expect(grams.contains { $0.text == "一窝" })
    }

    @Test("对仗统计只取保留的一份")
    func parallelSkipsDuplicates() async throws {
        let directory = try TemporaryDirectory()
        let index = try makeIndex(directory)
        try await index.importPack(at: try DrillFixtures.makePack(in: directory, id: "drill-a"))
        try await index.importPack(at: try DrillFixtures.makePack(in: directory, id: "drill-b"))
        #expect(try await index.packs().map(\.duplicateCount) == [0, 3])
        #expect(try await index.buildParallelIndex() == 4)
        #expect(try await index.pairCounts([PairKey("月", "泉")])[PairKey("月", "泉")] == 1)
    }

    @Test("取舍：组内最优先的包全保留，其余指向直接成对的保留作品")
    func chooseCanonical() {
        let order = ["A": 0, "B": 1, "C": 2]
        let result = CorpusIndex.chooseCanonical(
            pairs: [(1, "A", 10, "B"), (2, "A", 10, "B"), (10, "B", 20, "C"), (30, "C", 40, "B")]) {
            order[$0, default: 9] < order[$1, default: 9]
        }
        #expect(result == [10: 1, 20: 1, 30: 40])
        #expect(CorpusIndex.chooseCanonical(pairs: []) { $0 < $1 }.isEmpty)
    }

    @Test("异文判定：作者相同且相同句数不少于七成")
    func variant() {
        #expect(CorpusIndex.isVariant(sharedLines: 7, lineCounts: (10, 8), authors: ("甲", "甲")))
        #expect(!CorpusIndex.isVariant(sharedLines: 6, lineCounts: (10, 8), authors: ("甲", "甲")))
        #expect(!CorpusIndex.isVariant(sharedLines: 7, lineCounts: (10, 8), authors: ("甲", "乙")))
        #expect(!CorpusIndex.isVariant(sharedLines: 7, lineCounts: (10, 8), authors: (nil, "甲")))
        #expect(!CorpusIndex.isVariant(sharedLines: 7, lineCounts: (10, 8), authors: ("", "")))
        #expect(!CorpusIndex.isVariant(sharedLines: 0, lineCounts: (0, 0), authors: ("甲", "甲")))
    }

    @Test("全文哈希：只看各句连起来的文字")
    func textHash() {
        #expect(CorpusIndex.textHash(["国破", "山河"]) == CorpusIndex.textHash(["国破山河"]))
        #expect(CorpusIndex.textHash(["国破山河"]) != CorpusIndex.textHash(["山河国破"]))
        #expect(CorpusIndex.textHash([]) == CorpusIndex.textHash([""]))
    }

    @Test("切句时缺字符号可视同汉字")
    func segmenterPlaceholders() {
        #expect(TextSegmenter.segments(of: "鬌□一窝").map(\.count) == [1, 2], "缺省仍作分隔")
        #expect(TextSegmenter.segments(of: "鬌□一窝，绿", placeholders: ["□"]).map(\.count) == [4, 1])
        #expect(TextSegmenter.segments(of: "□□", placeholders: ["□"]).map(\.count) == [2])
    }

    @Test("清单的 priority 须在范围内")
    func manifestPriority() throws {
        let directory = try TemporaryDirectory()
        try directory.write("[]", to: "a.json")
        try PackManifest(id: "p", name: "p", files: ["a.json"], priority: 0).validate(in: directory.url)
        try PackManifest(id: "p", name: "p", files: ["a.json"], priority: 1_000).validate(in: directory.url)
        try PackManifest(id: "p", name: "p", files: ["a.json"]).validate(in: directory.url)
        #expect(throws: PackError.self) { try PackManifest(id: "p", name: "p", files: ["a.json"], priority: -1).validate(in: directory.url) }
        #expect(throws: PackError.self) { try PackManifest(id: "p", name: "p", files: ["a.json"], priority: 1_001).validate(in: directory.url) }
    }
}

@Suite("CSV 与 Werneror 语料")
struct WernerorTests {
    @Test("CSV：引号内的逗号、换行与双引号，CRLF、BOM、空行")
    func csv() throws {
        let text = "\u{FEFF}a,b,c\r\n\"x,1\",\"多\n行\",\"说\"\"话\"\"\"\n\n,,\nlast,row,end"
        #expect(try CSVReader.rows(Data(text.utf8)) == [["a", "b", "c"], ["x,1", "多\n行", "说\"话\""], ["", "", ""], ["last", "row", "end"]])
        #expect(try CSVReader.rows(Data()).isEmpty)
        #expect(try CSVReader.rows(Data("a\n".utf8)) == [["a"]])
        #expect(throws: CSVError.unterminatedQuote(row: 2)) { try CSVReader.rows(Data("a\n\"b,c\n".utf8)) }
        #expect(throws: CSVError.notUTF8) { try CSVReader.rows(Data([0xFF, 0xFE, 0x00])) }
    }

    @Test("缺字：? 与 ■ 及部件描述换为 □；不像部件描述的花括号原样保留")
    func restoreMissing() {
        #expect(WernerorConverter.restoreMissing("鬌?一窝■") == "鬌□一窝□")
        #expect(WernerorConverter.restoreMissing("瞻{日阝}路，红{艹/撲}簌") == "瞻□路，红□簌")
        #expect(WernerorConverter.restoreMissing("{这是一段很长的说明文字}") == "{这是一段很长的说明文字}")
        #expect(WernerorConverter.restoreMissing("未闭合{日阝") == "未闭合{日阝")
        #expect(WernerorConverter.restoreMissing("{{日阝}") == "{□")
        #expect(WernerorConverter.restoreMissing("  空白  ") == "空白")
    }

    @Test("按句末标点与换行分段")
    func paragraphs() {
        #expect(WernerorConverter.paragraphs(of: "春眠不觉晓，处处闻啼鸟。夜来风雨声？花落知多少！")
                == ["春眠不觉晓，处处闻啼鸟。", "夜来风雨声？", "花落知多少！"])
        #expect(WernerorConverter.paragraphs(of: "无句末标点，到此为止") == ["无句末标点，到此为止"])
        #expect(WernerorConverter.paragraphs(of: "一行\n 二行。") == ["一行", "二行。"])
        #expect(WernerorConverter.paragraphs(of: "").isEmpty)
    }

    @Test("CSV 转换：校验表头，跳过列数不对或没有汉字的行")
    func convert() throws {
        let csv = """
        "题目","朝代","作者","内容"
        "春晓","唐","孟浩然","春眠不觉晓，处处闻啼鸟。"
        "坏行","唐"
        "空","唐","某","，。"
        "缺字","清","某?","鬌?一窝绿。"
        """
        let result = try WernerorConverter.poems(fromCSV: Data(csv.utf8), file: "t.csv")
        #expect(result.skipped == 2)
        #expect(result.poems == [
            WernerorPoem(title: "春晓", author: "孟浩然", dynasty: "唐", paragraphs: ["春眠不觉晓，处处闻啼鸟。"]),
            WernerorPoem(title: "缺字", author: "某□", dynasty: "清", paragraphs: ["鬌□一窝绿。"]),
        ])
        #expect(throws: WernerorError.unexpectedHeader("t.csv")) {
            try WernerorConverter.poems(fromCSV: Data("title,author\n".utf8), file: "t.csv")
        }
        #expect(throws: WernerorError.noPoems("t.csv")) {
            try WernerorConverter.poems(fromCSV: Data("题目,朝代,作者,内容\n空,唐,某,。\n".utf8), file: "t.csv")
        }
    }

    @Test("分包：34 个文件各属一包，合计 853,385 首；地址固定到提交")
    func sources() throws {
        let files = WernerorSource.all.flatMap(\.files)
        #expect(files.count == 34)
        #expect(Set(files).count == files.count)
        #expect(WernerorSource.all.map(\.workCount).reduce(0, +) == 853_385)
        #expect(Set(WernerorSource.all.map(\.id)).count == WernerorSource.all.count)
        let source = try #require(WernerorSource.all.first { $0.id == "werneror-qing" })
        let url = try #require(source.remoteURL(for: "明末清初"))
        #expect(url.absoluteString.contains("/\(WernerorSource.commit)/"))
        #expect(url.absoluteString.hasSuffix(".csv"))
        let manifest = source.manifest(files: ["明末清初.json"])
        #expect(manifest.priority == WernerorSource.priority)
        #expect(manifest.fieldMapping == ["lines": "paragraphs"])
        let directory = try TemporaryDirectory()
        try directory.write("[]", to: "明末清初.json")
        try manifest.validate(in: directory.url)
    }

    @Test("已转换的文件不重复下载")
    func resume() async throws {
        let directory = try TemporaryDirectory()
        let source = try #require(WernerorSource.all.first)
        let pack = directory.url.appendingPathComponent(source.id)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        for file in source.files {
            try "[]".write(to: pack.appendingPathComponent("\(file).json"), atomically: true, encoding: .utf8)
        }
        let result = try await WernerorDownloader.download(source, into: directory.url)
        let manifest = try PackManifest.load(from: result)
        #expect(manifest.files == source.files.map { "\($0).json" })
        #expect(manifest.priority == 10)
    }
}
