import Foundation
import Testing
@testable import PoetryCore

extension MCPTests {
    @Test("典籍工具：未下载时提示，下载后查韵藻、对仗与类书")
    func classicsTools() async throws {
        let directory = try TemporaryDirectory()
        let (server, service) = try makeServer(directory)

        let notInstalled = try await tool(server, "find_yunzao", ["char": "东"])
        #expect(notInstalled["result"]?["isError"]?.boolValue == true)
        #expect(notInstalled["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("尚未下载《佩文韵府》") == true)
        let primerOnly = try await tool(server, "find_couplet", ["text": "云"])
        #expect(primerOnly["result"]?["structuredContent"]?["couplets"]?.arrayValue?.first?["counterpart"]?.stringValue == "雨")
        #expect(primerOnly["result"]?["structuredContent"]?["couplets"]?.arrayValue?.first?["source"]?.stringValue == "声律启蒙·一、東")

        try ClassicsFixtures.placeDownloadedTexts(for: service, in: directory)
        try await service.reimportClassic(.peiwenYunfu)
        try await service.reimportClassic(.yiwenLeiju)

        let ending = try await tool(server, "find_yunzao", ["char": "东", "pattern": "仄平"])
        let phrases = ending["result"]?["structuredContent"]?["entries"]?.arrayValue?.compactMap { $0["phrase"]?.stringValue }
        #expect(phrases == ["自東", "小東", "乃東"])
        let rhymed = try await tool(server, "find_yunzao", ["char": "东", "pattern": "仄平", "same_rhyme": true])
        let rhymedPhrases = rhymed["result"]?["structuredContent"]?["entries"]?.arrayValue?.compactMap { $0["phrase"]?.stringValue } ?? []
        #expect(rhymedPhrases.contains("會同"), "同韵的「同」字韵藻")
        let couplet = try await tool(server, "find_couplet", ["text": "缊瑟"])
        #expect(couplet["result"]?["structuredContent"]?["couplets"]?.arrayValue?.first?["source"]?.stringValue == "佩文韵府对语·東（上平·一东）")

        let byTopic = try await tool(server, "search_leiju", ["topic": "衡山"])
        #expect(byTopic["result"]?["structuredContent"]?["entries"]?.arrayValue?.count == 1)
        let filtered = try await tool(server, "search_leiju", ["topic": "总载山", "query": "仁者"])
        #expect(filtered["result"]?["structuredContent"]?["entries"]?.arrayValue?.first?["text"]?.stringValue == "論語曰仁者樂山")
        let byText = try await tool(server, "search_leiju", ["query": "庾阐"])
        #expect(byText["result"]?["structuredContent"]?["entries"]?.arrayValue?.first?["genre"]?.stringValue == "詩")
    }

    @Test("对仗评分工具")
    func scoreCoupletTool() async throws {
        let directory = try TemporaryDirectory()
        let (server, _) = try makeServer(directory)
        let response = try await tool(server, "score_couplet", ["text": "云", "answer": "雨"])
        let content = response["result"]?["structuredContent"]
        #expect(content?["level"]?.stringValue == "工")
        #expect(content?["mode"]?.stringValue == "对词")
        #expect(content?["reasons"]?.arrayValue?.first?.stringValue == "见于声律启蒙·一、東")
        #expect(content?["positions"]?.arrayValue?.first?["tone"]?.stringValue == "相对")
        #expect(content?["references"]?.arrayValue?.first?["source"]?.stringValue == "声律启蒙·一、東")
        #expect(response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.hasPrefix("工：") == true)

        let line = try await tool(server, "score_couplet", ["text": "风急天高猿啸哀", "answer": "渚清沙白鸟飞回"])
        #expect(line["result"]?["structuredContent"]?["meter"]?.stringValue == "律对")

        func message(_ arguments: JSONValue) async throws -> String {
            let response = try await tool(server, "score_couplet", arguments)
            #expect(response["result"]?["isError"]?.boolValue == true)
            return response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        }
        #expect(try await message(["text": "云"]).contains("缺少参数 answer"))
        #expect(try await message(["text": "，", "answer": "雨"]).contains("出题中没有汉字"))
        #expect(try await message(["text": "云", "answer": "。"]).contains("对句中没有汉字"))
    }

    @Test("典籍工具的参数校验")
    func classicsToolErrors() async throws {
        let directory = try TemporaryDirectory()
        let (server, service) = try makeServer(directory)
        try ClassicsFixtures.placeDownloadedTexts(for: service, in: directory)
        try await service.reimportClassic(.peiwenYunfu)
        try await service.reimportClassic(.yiwenLeiju)
        func message(_ name: String, _ arguments: JSONValue) async throws -> String {
            let response = try await tool(server, name, arguments)
            #expect(response["result"]?["isError"]?.boolValue == true)
            return response["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        }
        #expect(try await message("find_yunzao", ["char": "东风"]).contains("单个汉字"))
        #expect(try await message("find_yunzao", ["char": "东", "pattern": "平x"]).contains("平、仄、中"))
        #expect(try await message("find_yunzao", ["char": "看", "pattern": "中中", "same_rhyme": true]).contains("平仄两读"))
        #expect(try await message("find_couplet", [:]).contains("缺少参数 text"))
        #expect(try await message("search_leiju", [:]).contains("至少给出一个"))
        #expect(try await message("search_leiju", ["query": "山", "limit": 0]).contains("正整数"))
        let empty = try await tool(server, "find_yunzao", ["char": "冰", "pattern": "平平平平平"])
        #expect(empty["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("没有符合") == true)
    }
}
