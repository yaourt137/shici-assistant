import Foundation
import Testing
@testable import PoetryCore

private let dictionary = CharDictionary.shared

@Suite("繁简判断")
struct ScriptKindTests {
    private let converter = dictionary.converter

    @Test("繁体专用字、简体专用字、两者都有、都没有")
    func kinds() {
        #expect(converter.scriptKind(of: "鳳凰臺上鳳凰遊") == .traditional)
        #expect(converter.scriptKind(of: "凤凰台上凤凰游") == .simplified)
        #expect(converter.scriptKind(of: "鳳凰台上凤凰遊") == .mixed)
        #expect(converter.scriptKind(of: "白日依山") == .neutral, "繁简同形")
        #expect(converter.scriptKind(of: "") == .neutral)
        #expect(converter.scriptKind(of: "，。abc 123") == .neutral, "没有汉字")
    }

    @Test("繁简共用的字（如「云」「台」「后」）不作为简体的依据")
    func sharedCharacters() {
        #expect(converter.scriptKind(of: "子曰詩云") == .traditional)
        #expect(converter.scriptKind(of: "云台后") == .neutral)
    }
}

@Suite("转繁体")
struct TraditionalConversionTests {
    private let converter = dictionary.converter

    @Test("逐字查表：已是繁体的不动，标点与空白原样，位置一一对应")
    func characterTable() {
        let result = TraditionalConversion.convert("凤凰台上凤凰游，\n凤去台空江自流。", converter: converter)
        #expect(result.text == "鳳凰臺上鳳凰遊，\n鳳去臺空江自流。")
        #expect(result.text.count == "凤凰台上凤凰游，\n凤去台空江自流。".count)
        #expect(result.choices.map { $0.offset } == [2, 6, 11], "「台」「游」有多种繁体")
        #expect(result.choices.first?.candidates.first == "臺")
        #expect(result.choices.first?.candidates.contains("台") == true)
        #expect(TraditionalConversion.convert("鳳凰臺", converter: converter).choices.isEmpty, "已是繁体")
    }

    @Test("句子见于繁体语料时照抄原书字形，不再列出待核对")
    func knownLines() {
        let known = ["白发三千丈": "白髮三千丈", "缘愁似个长": "緣愁似箇長"]
        let result = TraditionalConversion.convert("白发三千丈，缘愁似个长。不知明镜里", converter: converter, known: known)
        #expect(result.text == "白髮三千丈，緣愁似箇長。不知明鏡裏")
        #expect(result.choices.map { $0.offset } == [16], "只有未见于语料的句子要核对（「里」）")
        let mismatched = TraditionalConversion.convert("白发三千丈", converter: converter, known: ["白发三千丈": "白髮"])
        #expect(mismatched.text == "白發三千丈", "长度不符时改用字表")
    }

    @Test("没有汉字或空文本时原样返回")
    func empty() {
        #expect(TraditionalConversion.convert("", converter: converter) == TraditionalConversion(text: "", choices: []))
        #expect(TraditionalConversion.convert("，。\n", converter: converter).text == "，。\n")
    }

    @Test("换字：按位置替换，越界时原样")
    func replacing() {
        #expect(TraditionalConversion.replacing(at: 1, with: "髮", in: "白發") == "白髮")
        #expect(TraditionalConversion.replacing(at: 2, with: "髮", in: "白發") == "白發")
        #expect(TraditionalConversion.replacing(at: -1, with: "髮", in: "白發") == "白發")
    }
}

@Suite("转繁体借用语料")
struct TraditionalCorpusTests {
    private static func makePack(in directory: TemporaryDirectory, id: String, script: String, poems: String) throws -> URL {
        let pack = directory.url.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let manifest = """
        {"formatVersion":1,"kind":"corpus","id":"\(id)","name":"\(id)","script":"\(script)",
         "files":["poems.json"],"fieldMapping":{"lines":"paragraphs"}}
        """
        try manifest.write(to: pack.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try poems.write(to: pack.appendingPathComponent("poems.json"), atomically: true, encoding: .utf8)
        return pack
    }

    @Test("只取已启用的繁体语料包中的原句；简体包与停用的包不取")
    func corpusLines() async throws {
        let directory = try TemporaryDirectory()
        let service = try PoetryService(paths: AppPaths(root: directory.url.appendingPathComponent("data")))
        _ = try await service.installPack(from: try Self.makePack(in: directory, id: "trad", script: "traditional", poems: """
            [{"author":"李白","title":"秋浦歌","paragraphs":["白髮三千丈（一作尺），緣愁似箇長。","不知明鏡裏，何處得秋霜。"]}]
            """))
        _ = try await service.installPack(from: try Self.makePack(in: directory, id: "simp", script: "simplified", poems: """
            [{"author":"李白","title":"清平调","paragraphs":["云想衣裳花想容，春风拂槛露华浓。"]}]
            """))

        let lines = try await service.corpus.traditionalLines(for: ["白发三千丈", "何处得秋霜", "云想衣裳花想容", "白", ""])
        #expect(lines == ["白发三千丈": "白髮三千丈", "何处得秋霜": "何處得秋霜"], "校注已剥离；简体包、单字句不取")

        let result = try await service.traditionalConversion(of: "白发三千丈，缘愁似个长。\n云想衣裳花想容。")
        #expect(result.text == "白髮三千丈，緣愁似箇長。\n雲想衣裳花想容。")
        #expect(result.choices.map { $0.offset } == [13], "只有简体包里的那句要核对「云」")

        try await service.corpus.setEnabled(false, packID: "trad")
        #expect(try await service.corpus.traditionalLines(for: ["白发三千丈"]).isEmpty, "停用的包不取")
        #expect(try await service.traditionalConversion(of: "白发三千丈").text == "白發三千丈", "改用字表")
        #expect(try await service.traditionalConversion(of: "").text == "")
    }
}
