import Foundation
import Testing
@testable import PoetryCore

@Suite("用户库")
struct LibraryStoreTests {
    @Test("收藏增改删与标签")
    func phrases() throws {
        let directory = try TemporaryDirectory()
        let store = try LibraryStore(url: directory.url.appendingPathComponent("library.sqlite"))
        var phrase = Phrase(text: "明月", kind: .word,
                            provenance: Provenance(kind: .excerpt, source: SourceInfo(author: "李白", title: "静夜思")),
                            tags: [TagAssignment(path: "意象/月", addedBy: .user)], note: "备注")
        try store.save(phrase)
        var loaded = try #require(try store.phrase(id: phrase.id))
        #expect(loaded.text == "明月")
        #expect(loaded.provenance.source?.author == "李白")
        #expect(loaded.tagPaths == ["意象/月"])
        #expect(try store.tags() == ["意象", "意象/月"])

        phrase.tags = [TagAssignment(path: "季节/秋", addedBy: .agent)]
        phrase.text = "明月光"
        try store.save(phrase)
        loaded = try #require(try store.phrase(id: phrase.id))
        #expect(loaded.text == "明月光")
        #expect(loaded.tags == [TagAssignment(path: "季节/秋", addedBy: .agent)])
        #expect(try store.tagUsage() == ["季节/秋": 1])

        try store.setStatus(.inbox, for: [phrase.id])
        #expect(try store.phrase(id: phrase.id)?.status == .inbox)

        try store.deletePhrase(id: phrase.id)
        #expect(try store.phrases().isEmpty)
    }

    @Test("拒绝空文本与非法标签")
    func validation() throws {
        let directory = try TemporaryDirectory()
        let store = try LibraryStore(url: directory.url.appendingPathComponent("library.sqlite"))
        #expect(throws: LibraryError.emptyText) {
            try store.save(Phrase(text: "，。", kind: .word, provenance: .original))
        }
        #expect(throws: LibraryError.invalidTag(" / ")) {
            try store.save(Phrase(text: "明月", kind: .word, provenance: .original, tags: [TagAssignment(path: " / ", addedBy: .user)]))
        }
        #expect(try store.phrases().isEmpty, "失败的保存应整体回滚")
    }

    @Test("标签改名连同下级，并可合并")
    func renameTags() throws {
        let directory = try TemporaryDirectory()
        let store = try LibraryStore(url: directory.url.appendingPathComponent("library.sqlite"))
        let first = Phrase(text: "落叶", kind: .word, provenance: .original, tags: [TagAssignment(path: "秋/晚秋", addedBy: .user)])
        let second = Phrase(text: "西风", kind: .word, provenance: .original, tags: [TagAssignment(path: "季节/秋", addedBy: .user)])
        try store.save(first)
        try store.save(second)
        try store.renameTag("秋", to: "季节/秋")
        #expect(try store.phrase(id: first.id)?.tagPaths == ["季节/秋/晚秋"])
        #expect(try store.tags() == ["季节", "季节/秋", "季节/秋/晚秋"])
        #expect(throws: LibraryError.self) { try store.renameTag("季节", to: "季节/子") }
        #expect(throws: LibraryError.self) { try store.renameTag("不存在", to: "x") }
        try store.deleteTag("季节/秋")
        #expect(try store.phrase(id: second.id)?.tags.isEmpty == true)
        #expect(try store.phrases().count == 2, "删除标签不删收藏")
    }

    @Test("标签名中的通配符不误伤")
    func likeEscaping() throws {
        let directory = try TemporaryDirectory()
        let store = try LibraryStore(url: directory.url.appendingPathComponent("library.sqlite"))
        _ = try store.createTag("a_b/c")
        _ = try store.createTag("axb/c")
        try store.deleteTag("a_b")
        #expect(try store.tags() == ["axb", "axb/c"])
    }

    @Test("作品、智能收藏夹与设置")
    func poemsAndSettings() throws {
        let directory = try TemporaryDirectory()
        let store = try LibraryStore(url: directory.url.appendingPathComponent("library.sqlite"))
        var poem = Poem(title: "", body: "白日依山尽", form: .ci("huanxisha"), book: .cilin)
        try store.save(poem)
        poem.title = "试作"
        try store.save(poem)
        let loaded = try #require(try store.poems().first)
        #expect(loaded.title == "试作")
        #expect(loaded.form == .ci("huanxisha"))
        #expect(loaded.book == .cilin)
        #expect(Poem(body: "白日依山尽，黄河").displayTitle == "白日依山尽")
        #expect(Poem().displayTitle == "无题")
        try store.deletePoem(id: poem.id)
        #expect(try store.poems().isEmpty)

        try store.save(SmartCollection(name: "秋月", query: "秋 月"))
        #expect(try store.smartCollections().map(\.name) == ["秋月"])
        #expect(throws: FilterParseError.self) { try store.save(SmartCollection(name: "坏", query: "月|")) }

        #expect(try store.bool(.agentWritesToInbox) == true)
        #expect(try store.bool(.mcpReadOnly) == false)
        try store.setBool(.mcpReadOnly, true)
        #expect(try store.bool(.mcpReadOnly) == true)
    }

    @Test("数据目录解析")
    func paths() {
        let fromArgument = AppPaths.resolve(arguments: ["app", "-ShiCiDataDirectory", "/tmp/a"], environment: ["SHICI_DATA_DIR": "/tmp/b"])
        #expect(fromArgument.root.path == "/tmp/a")
        let fromEnvironment = AppPaths.resolve(arguments: ["app"], environment: ["SHICI_DATA_DIR": "/tmp/b"])
        #expect(fromEnvironment.library.path == "/tmp/b/library.sqlite")
        let dangling = AppPaths.resolve(arguments: ["app", "-ShiCiDataDirectory"], environment: [:])
        #expect(dangling.root.lastPathComponent == "ShiCi")
    }
}

@Suite("语料包")
struct CorpusTests {
    @Test("清单校验")
    func manifestValidation() throws {
        let directory = try TemporaryDirectory()
        #expect(throws: PackError.self) { try PackManifest.load(from: directory.url) }
        let cases: [String] = [
            #"{"formatVersion":2,"kind":"corpus","id":"a","name":"甲","files":["a.json"]}"#,
            #"{"formatVersion":1,"kind":"formbook","id":"a","name":"甲","files":["a.json"]}"#,
            #"{"formatVersion":1,"kind":"corpus","id":"a b","name":"甲","files":["a.json"]}"#,
            #"{"formatVersion":1,"kind":"corpus","id":"a","name":" ","files":["a.json"]}"#,
            #"{"formatVersion":1,"kind":"corpus","id":"a","name":"甲","files":[]}"#,
            #"{"formatVersion":1,"kind":"corpus","id":"a","name":"甲","files":["../a.json"]}"#,
            #"{"formatVersion":1,"kind":"corpus","id":"a","name":"甲","files":["a.txt"]}"#,
            #"{"formatVersion":1,"kind":"corpus","id":"a","name":"甲","files":["missing.json"]}"#,
            #"{"formatVersion":1,"kind":"corpus","id":"a","name":"甲","files":["a.json"],"fieldMapping":{"body":"x"}}"#,
            #"{"formatVersion":1,"kind":"corpus","id":"a","name":"甲","files":["a.json"],"script":"latin"}"#,
            #"{"formatVersion":1,"kind":"corpus"}"#,
        ]
        try directory.write("[]", to: "a.json")
        for manifest in cases {
            try directory.write(manifest, to: "manifest.json")
            #expect(throws: PackError.self, "\(manifest)") { try PackManifest.load(from: directory.url) }
        }
    }

    @Test("记录映射与跳过坏记录")
    func reader() throws {
        let directory = try TemporaryDirectory()
        let pack = try Fixtures.makePack(in: directory)
        let manifest = try PackManifest.load(from: pack)
        let result = try PackReader.read(manifest, in: pack)
        #expect(result.records.count == 4)
        #expect(result.skipped == 3)
        #expect(result.records[0].dynasty == "唐")
        #expect(result.records[0].lines.count == 2)
    }

    @Test("全部记录无效时报错")
    func noRecords() throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{"formatVersion":1,"kind":"corpus","id":"empty","name":"空","files":["a.json"]}"#, to: "manifest.json")
        try directory.write(#"[{"title":"无正文"}]"#, to: "a.json")
        let manifest = try PackManifest.load(from: directory.url)
        #expect(throws: PackError.self) { try PackReader.read(manifest, in: directory.url) }
        try directory.write(#"{"not":"array"}"#, to: "a.json")
        #expect(throws: PackError.self) { try PackReader.read(manifest, in: directory.url) }
    }

    @Test("导入、检索、停用与删除")
    func importAndQuery() async throws {
        let directory = try TemporaryDirectory()
        let pack = try Fixtures.makePack(in: directory)
        let index = try CorpusIndex(url: directory.url.appendingPathComponent("corpus.sqlite"))
        let report = try await index.importPack(at: pack)
        #expect(report.workCount == 4)
        #expect(report.lineCount == 12)
        #expect(report.skippedRecords == 3)

        let usages = try await index.usages(of: "明月")
        #expect(Set(usages.map(\.text)) == ["床前明月光", "明月松间照"], "《静夜思》两句都含「明月」，只取首句")
        #expect(usages.first { $0.text == "床前明月光" }?.author == "李白")
        let single = try await index.usages(of: "霜")
        #expect(single.map(\.text) == ["疑是地上霜"])
        #expect(try await index.usages(of: "，").isEmpty)

        let related = try await index.related(to: "低头望明月")
        #expect(related.first?.text == "举头望明月")
        #expect(!related.map(\.text).contains("低头望明月"))

        let source = try #require(try await index.findSource(of: "白日依山盡"))
        #expect(source.author == "王之涣")
        #expect(source.title == "登鹳雀楼")
        #expect(source.isVerified)
        #expect(try await index.findSource(of: "欲穷千里目，更上一层楼")?.author == "王之涣")
        #expect(try await index.findSource(of: "欲穷千里目，黄河入海流") == nil)
        #expect(try await index.findSource(of: "明月") == nil, "短词不作出处")

        let constraint = SlotConstraint(slots: [.ping, .ping], rhyme: nil, book: .pingshui)
        let candidates = try await index.candidates(for: constraint)
        #expect(candidates.map(\.text).contains("黄河"))
        #expect(!candidates.map(\.text).contains("白日"))
        let lineConstraint = SlotConstraint(slots: [.ze, .ze, .ping, .ping, .ze], rhyme: nil, book: .pingshui)
        #expect(try await index.candidates(for: lineConstraint).map(\.text).contains("白日依山尽"))
        let single1 = SlotConstraint(slots: [.ping], rhyme: RhymeRequirement(key: RhymeKey(book: .pingshui, id: 25), tone: .ping), book: .pingshui)
        let rhymeCharacters = try await index.candidates(for: single1).map(\.text)
        #expect(rhymeCharacters.contains("流"))
        #expect(rhymeCharacters.allSatisfy { CharDictionary.shared.rhymeKeys(of: Character($0), in: .pingshui, tone: .ping).contains(RhymeKey(book: .pingshui, id: 25)) })

        let work = try #require(try await index.work(id: usages[0].workID))
        #expect(work.body.contains("明月"))

        try await index.setEnabled(false, packID: "test-pack")
        #expect(try await index.usages(of: "明月").isEmpty)
        #expect(try await index.candidates(for: constraint).isEmpty)
        try await index.setEnabled(true, packID: "test-pack")

        let frequencies = try await index.characterFrequencies()
        #expect(frequencies["明"] == 3)

        // 重新导入同一 id 会先清除旧数据。
        try await index.importPack(at: pack)
        #expect(try await index.usages(of: "明月").count == 2)
        #expect(try await index.packs().count == 1)

        try await index.deletePack(id: "test-pack")
        #expect(try await index.packs().isEmpty)
        #expect(try await index.usages(of: "明月").isEmpty)
        #expect(try await index.related(to: "低头望明月").isEmpty)
    }

    @Test("节奏位判断")
    func rhythm() {
        #expect(CorpusIndex.isRhythmAligned(start: 0, length: 2, lineLength: 5))
        #expect(CorpusIndex.isRhythmAligned(start: 3, length: 2, lineLength: 5))
        #expect(!CorpusIndex.isRhythmAligned(start: 1, length: 2, lineLength: 5))
        #expect(CorpusIndex.isRhythmAligned(start: 4, length: 3, lineLength: 7))
        #expect(!CorpusIndex.isRhythmAligned(start: 0, length: 3, lineLength: 7))
        #expect(!CorpusIndex.isRhythmAligned(start: 0, length: 4, lineLength: 5))
        #expect(CorpusIndex.isRhythmAligned(start: 3, length: 2, lineLength: 9), "未列出的句长视为对齐")
    }

    @Test("相似度：长句优先于短片段")
    func similarity() {
        let query = "孤舟蓑笠翁"
        #expect(CorpusIndex.similarity(query, "孤舟蓑笠钓烟沙") > CorpusIndex.similarity(query, "蓑笠渔翁"))
        #expect(CorpusIndex.similarity(query, query) > 1.29)
        #expect(CorpusIndex.similarity("月", "月") == 0.3)
        #expect(CorpusIndex.similarity("", "明月") == 0)
    }

    @Test("FTS 词元")
    func tokens() {
        #expect(CorpusIndex.ftsTokens("明月光") == "明月 月光")
        #expect(CorpusIndex.ftsTokens("月") == "月")
        #expect(CorpusIndex.ftsTokens("") == "")
    }

    @Test("括号校注剥离")
    func stripAnnotations() {
        #expect(CorpusIndex.stripAnnotations("床前看月光（一作明月光），疑是地上霜。") == "床前看月光，疑是地上霜。")
        #expect(CorpusIndex.stripAnnotations("白日(一作…)依山尽") == "白日依山尽", "句中夹注删去后两段相连")
        #expect(CorpusIndex.stripAnnotations("春风（京本作「东风（又作西风）」）起") == "春风起", "嵌套")
        #expect(CorpusIndex.stripAnnotations("〔原注〕江南好，［一作］风景【缺】旧曾谙") == "江南好，风景旧曾谙")
        #expect(CorpusIndex.stripAnnotations("红豆生南国（一作)") == "红豆生南国", "全角、半角混用")
        #expect(CorpusIndex.stripAnnotations("（京本作「占委任第一」）") == "", "整段都是注")
        #expect(CorpusIndex.stripAnnotations("春眠不觉晓（下缺") == "春眠不觉晓（下缺", "未闭合时原样保留")
        #expect(CorpusIndex.stripAnnotations("春眠（甲（乙）不觉晓") == "春眠（甲（乙）不觉晓", "外层未闭合时整段原样保留")
        #expect(CorpusIndex.stripAnnotations("处处闻啼鸟）夜来风雨声") == "处处闻啼鸟）夜来风雨声", "多余右括号保留")
        #expect(CorpusIndex.stripAnnotations("") == "")
        #expect(CorpusIndex.stripAnnotations("花落知多少") == "花落知多少")
    }

    @Test("同一作品的用例只取首句")
    func usagesOncePerWork() async throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{"formatVersion":1,"kind":"corpus","id":"dup","name":"重复","files":["a.json"]}"#, to: "dup/manifest.json")
        try directory.write(#"""
            [{"title":"行路难","author":"李白","lines":["多歧路，今安在。","行路难，行路难。"]},
             {"title":"从军中行路难","author":"骆宾王","lines":["行路难，行路难，岐路几千端。"]},
             {"title":"无关","author":"某","lines":["明月松间照。"]}]
            """#, to: "dup/a.json")
        let index = try CorpusIndex(url: directory.url.appendingPathComponent("corpus.sqlite"))
        try await index.importPack(at: directory.url.appendingPathComponent("dup"))

        let usages = try await index.usages(of: "行路难")
        #expect(usages.count == 2)
        #expect(Set(usages.map(\.workID)).count == 2)
        #expect(usages.map(\.lineIndex) == [2, 0], "取作品中最先出现的一句，按导入顺序排列")
        #expect(try await index.usages(of: "难").count == 2, "单字查询同样按作品去重")
        #expect(try await index.usages(of: "行路难", limit: 1).count == 1)
        #expect(try await index.usages(of: "岐路").count == 1)
    }

    @Test("导入时校注不成句，全文保留校注")
    func importStripsAnnotations() async throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{"formatVersion":1,"kind":"corpus","id":"notes","name":"校注","files":["a.json"]}"#, to: "notes/manifest.json")
        try directory.write(#"""
            [{"title":"望江南","author":"某","lines":["委任须知事，（京本作「占委任第一」）临机莫失时。","江南好(一作佳)。",
              "暗有贼兵欺（京本作「来」。","又防火。）","一作云峰别，三看花柳朝。"]}]
            """#, to: "notes/a.json")
        let index = try CorpusIndex(url: directory.url.appendingPathComponent("corpus.sqlite"))
        let report = try await index.importPack(at: directory.url.appendingPathComponent("notes"))
        #expect(report.lineCount == 6)
        #expect(try await index.usages(of: "本作").isEmpty)
        #expect(try await index.usages(of: "防火").isEmpty, "跨段的校注也去掉")
        #expect(try await index.usages(of: "贼兵").map(\.text) == ["暗有贼兵欺"])
        #expect(try await index.usages(of: "云峰").map(\.text) == ["一作云峰别"], "括号外的「一作」是正文，保留")
        #expect(try await index.findSource(of: "暗有贼兵欺，一作云峰别")?.title == "望江南", "去掉校注后句序仍连续")
        let usages = try await index.usages(of: "江南")
        #expect(usages.map(\.text) == ["江南好"])
        let gram = SlotConstraint(slots: [.any, .any, .any], rhyme: nil, book: .pingshui)
        #expect(!(try await index.candidates(for: gram).map(\.text).contains("京本作")))
        let work = try #require(try await index.work(id: usages[0].workID))
        #expect(work.body.contains("京本作"), "查看全文时校注仍在")
        #expect(try await index.packs().first?.needsReindex == false)
    }
}

@Suite("业务服务")
struct ServiceTests {
    func makeService(_ directory: TemporaryDirectory) throws -> PoetryService {
        try PoetryService(paths: AppPaths(root: directory.url.appendingPathComponent("data")))
    }

    @Test("新增收藏：推断类型、反查出处、agent 进收件箱")
    func addPhrase() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        try await service.installPack(from: try Fixtures.makePack(in: directory))

        let excerpt = try await service.addPhrase(PhraseDraft(text: "床前明月光", provenance: Provenance(kind: .excerpt), tags: ["意象/月", "意象/月"]))
        #expect(excerpt.phrase.kind == .line)
        #expect(excerpt.phrase.provenance.source?.author == "李白")
        #expect(excerpt.phrase.provenance.source?.isVerified == true)
        #expect(excerpt.phrase.tagPaths == ["意象/月"])
        #expect(excerpt.phrase.status == .accepted)

        let claimed = Provenance(kind: .agent, agentClient: "test", claimedSource: SourceInfo(author: "杜甫", url: "https://example.org"))
        let agent = try await service.addPhrase(PhraseDraft(text: "白日依山尽", provenance: claimed), actor: .agent)
        #expect(agent.phrase.status == .inbox)
        #expect(agent.phrase.provenance.source?.author == "王之涣")
        #expect(agent.phrase.provenance.source?.url == "https://example.org")
        #expect(agent.phrase.provenance.claimedSource?.author == "杜甫", "声称的出处原样保留，供用户比对")

        let manual = try await service.addPhrase(PhraseDraft(text: "万里悲秋", provenance: Provenance(kind: .excerpt, source: SourceInfo(author: "杜甫", isVerified: true))))
        #expect(manual.phrase.provenance.source?.isVerified == false, "未命中语料时不能标为已核实")

        let original = try await service.addPhrase(PhraseDraft(text: "明月松间照"))
        #expect(original.corpusMatch != nil)
        #expect(original.phrase.provenance.kind == .original)
        #expect(original.phrase.provenance.source == nil)

        try service.library.setBool(.agentWritesToInbox, false)
        let direct = try await service.addPhrase(PhraseDraft(text: "孤鸿", provenance: Provenance(kind: .agent)), actor: .agent)
        #expect(direct.phrase.status == .accepted)

        await #expect(throws: LibraryError.emptyText) { try await service.addPhrase(PhraseDraft(text: " ，")) }
        await #expect(throws: LibraryError.self) { try await service.addPhrase(PhraseDraft(text: "明月", tags: ["/"])) }

        let tagged = try service.addTags(["季节/秋"], to: direct.phrase.id, actor: .agent)
        #expect(tagged.tags.contains(TagAssignment(path: "季节/秋", addedBy: .agent)))
        #expect(throws: LibraryError.self) { try service.addTags(["x"], to: UUID(), actor: .user) }

        #expect(try service.searchPhrases("意象").map(\.text) == ["床前明月光"])
        #expect(try service.searchPhrases("", includeInbox: false).count == 4)
        #expect(try service.searchPhrases("", includeInbox: true).count == 5)
    }

    @Test("候选：收藏在前、去重、排除原文")
    func candidates() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        try await service.installPack(from: try Fixtures.makePack(in: directory))
        try await service.addPhrase(PhraseDraft(text: "黄河", tags: ["地理"]))
        try await service.addPhrase(PhraseDraft(text: "春风", tags: ["季节/春"]))
        let inbox = try await service.addPhrase(PhraseDraft(text: "清泉", provenance: Provenance(kind: .agent)), actor: .agent)
        #expect(inbox.phrase.status == .inbox)

        let constraint = SlotConstraint(slots: [.ping, .ping], rhyme: nil, book: .pingshui)
        let all = try await service.candidates(for: constraint)
        #expect(all.prefix(2).allSatisfy { if case .collection = $0.source { true } else { false } })
        #expect(all.filter { $0.text == "黄河" }.count == 1, "语料中与收藏重复的只保留收藏")
        #expect(!all.contains { $0.text == "清泉" && $0.source != .corpus }, "收件箱中的收藏不作候选")

        let filtered = try await service.candidates(for: constraint, options: CandidateOptions(includeCorpus: false, filter: .tag("季节")))
        #expect(filtered.map(\.text) == ["春风"])
        let excluding = try await service.candidates(for: constraint, options: CandidateOptions(excluding: "黄河"))
        #expect(!excluding.contains { $0.text == "黄河" })
        let limited = try await service.candidates(for: constraint, options: CandidateOptions(limit: 1))
        #expect(limited.count == 1)
    }

    @Test("Packs 目录中的待导入语料包")
    func pendingPacks() async throws {
        let directory = try TemporaryDirectory()
        let service = try makeService(directory)
        let source = try Fixtures.makePack(in: directory)
        try FileManager.default.copyItem(at: source, to: service.paths.packs.appendingPathComponent("test-pack"))
        try FileManager.default.createDirectory(at: service.paths.packs.appendingPathComponent("not-a-pack"), withIntermediateDirectories: true)
        #expect(try await service.pendingPackDirectories().map(\.lastPathComponent) == ["test-pack"])
        try await service.installPack(from: service.paths.packs.appendingPathComponent("test-pack"))
        #expect(try await service.pendingPackDirectories().isEmpty)
        try await service.removePack(id: "test-pack")
        #expect(!FileManager.default.fileExists(atPath: service.paths.packs.appendingPathComponent("test-pack").path))
        #expect(try await service.corpus.packs().isEmpty)
    }

    @Test("作品保存读音指定；旧版作品表自动补列")
    func poemReadingChoices() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("library.sqlite")
        // 模拟旧版数据库：poems 表没有 reading_choices 列。
        let legacy = try SQLiteDatabase(path: url.path)
        try legacy.execute("""
            CREATE TABLE poems (
                id TEXT PRIMARY KEY, title TEXT NOT NULL, body TEXT NOT NULL, form TEXT NOT NULL, book TEXT NOT NULL,
                created_at REAL NOT NULL, updated_at REAL NOT NULL
            );
            INSERT INTO poems VALUES ('\(UUID().uuidString)', '旧作', '春山独自看', 'free', 'pingshui', 0, 0);
            """)
        let store = try LibraryStore(url: url)
        let old = try #require(try store.poems().first)
        #expect(old.title == "旧作")
        #expect(old.readingChoices.isEmpty)

        let dictionary = CharDictionary.shared
        let reading = try #require(dictionary.readings(of: "看", in: .pingshui).first { $0.tone == .ping })
        var poem = old
        poem.readingChoices = [ReadingChoice(offset: 4, character: "看", reading: reading)]
        try store.save(poem)
        #expect(try store.poems().first?.readingChoices == poem.readingChoices)
    }

    @Test("旧版索引自动迁移并标记重新导入")
    func reindexOutdatedPacks() async throws {
        let directory = try TemporaryDirectory()
        let paths = AppPaths(root: directory.url.appendingPathComponent("data"))
        try paths.createDirectories()
        // 模拟旧版数据库：packs 表没有 index_format 列。
        let legacy = try SQLiteDatabase(path: paths.corpus.path)
        try legacy.execute("""
            CREATE TABLE packs (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT, era TEXT, script TEXT, license TEXT, source TEXT,
                enabled INTEGER NOT NULL DEFAULT 1, work_count INTEGER NOT NULL, line_count INTEGER NOT NULL, imported_at REAL NOT NULL
            );
            INSERT INTO packs (id, name, version, work_count, line_count, imported_at) VALUES ('test-pack', '测试语料', '1', 0, 0, 0);
            """)
        try FileManager.default.copyItem(at: try Fixtures.makePack(in: directory), to: paths.packs.appendingPathComponent("test-pack"))

        let service = try PoetryService(paths: paths)
        let migrated = try #require(try await service.corpus.packs().first)
        #expect(migrated.indexFormat == 1)
        #expect(migrated.needsReindex)
        #expect(try await service.pendingPackDirectories().map(\.lastPathComponent) == ["test-pack"], "版本相同但索引格式过旧")

        try await service.installPack(from: paths.packs.appendingPathComponent("test-pack"))
        #expect(try await service.corpus.packs().first?.indexFormat == CorpusIndex.indexFormat)
        #expect(try await service.pendingPackDirectories().isEmpty)

        // 再次打开不会重复迁移。
        let reopened = try CorpusIndex(url: paths.corpus)
        #expect(try await reopened.packs().first?.needsReindex == false)
    }
}

@Suite("语料下载")
struct CorpusDownloaderTests {
    @Test("文件名、地址与清单")
    func manifest() throws {
        let source = CorpusSource.chinesePoetrySongCi
        #expect(source.fileName(index: 0) == "ci.song.0.json")
        #expect(source.fileName(index: 3) == "ci.song.3000.json")
        let url = try #require(source.remoteURL(for: "ci.song.0.json"))
        #expect(url.absoluteString.hasSuffix("/%E5%AE%8B%E8%AF%8D/ci.song.0.json"))
        let manifest = source.manifest(files: ["ci.song.0.json"])
        #expect(manifest.fieldMapping?["tune"] == "rhythmic")
        let directory = try TemporaryDirectory()
        try directory.write("[]", to: "ci.song.0.json")
        try manifest.validate(in: directory.url)
    }

    @Test("已存在的文件不重复下载")
    func resume() async throws {
        let directory = try TemporaryDirectory()
        let source = CorpusSource(id: "local", name: "本地", era: "唐", script: "mixed", remoteDirectory: "x",
                                  filePrefix: "p", fieldMapping: [:])
        let pack = directory.url.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        for index in 0..<CorpusSource.maximumFiles {
            try "[]".write(to: pack.appendingPathComponent(source.fileName(index: index)), atomically: true, encoding: .utf8)
        }
        let result = try await CorpusDownloader.download(source, into: directory.url)
        let manifest = try PackManifest.load(from: result)
        #expect(manifest.files.count == CorpusSource.maximumFiles)
    }
}
