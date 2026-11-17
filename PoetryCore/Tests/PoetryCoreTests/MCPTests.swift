import Foundation
import Testing
@testable import PoetryCore

@Suite("MCP 服务")
struct MCPTests {
    final class ChangeCounter: @unchecked Sendable {
        var count = 0
    }

    func makeServer(_ directory: TemporaryDirectory, counter: ChangeCounter = ChangeCounter()) throws -> (MCPServer, PoetryService) {
        let service = try PoetryService(paths: AppPaths(root: directory.url.appendingPathComponent("data")))
        return (MCPServer(service: service, onLibraryChange: { counter.count += 1 }), service)
    }

    func call(_ server: MCPServer, _ request: JSONValue) async throws -> JSONValue {
        let line = try request.encodedString()
        let response = try #require(await server.handle(line: line))
        return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
    }

    func tool(_ server: MCPServer, _ name: String, _ arguments: JSONValue, id: Int = 1) async throws -> JSONValue {
        try await call(server, ["jsonrpc": "2.0", "id": .int(id), "method": "tools/call",
                                "params": ["name": .string(name), "arguments": arguments]])
    }

    @Test("握手、列工具与通知")
    func handshake() async throws {
        let directory = try TemporaryDirectory()
        let (server, _) = try makeServer(directory)
        let initialize = try await call(server, ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                 "params": ["protocolVersion": "2025-03-26", "clientInfo": ["name": "tester"]]])
        #expect(initialize["result"]?["protocolVersion"]?.stringValue == "2025-03-26")
        #expect(initialize["result"]?["serverInfo"]?["name"]?.stringValue == "shici-mcp")
        let fallback = try await call(server, ["jsonrpc": "2.0", "id": 2, "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        #expect(fallback["result"]?["protocolVersion"]?.stringValue == MCPServer.supportedProtocolVersions[0])

        #expect(await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let tools = try await call(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/list"])
        let names = tools["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("check_poem"))
        #expect(names.contains("add_phrase"))
        #expect(names.count == MCPTools.definitions.count)
        let ping = try await call(server, ["jsonrpc": "2.0", "id": "p", "method": "ping"])
        #expect(ping["id"]?.stringValue == "p")
    }

    @Test("协议错误")
    func protocolErrors() async throws {
        let directory = try TemporaryDirectory()
        let (server, _) = try makeServer(directory)
        let parse = try #require(await server.handle(line: "{oops"))
        #expect(parse.contains("-32700"))
        let missing = try await call(server, ["jsonrpc": "2.0", "id": 1])
        #expect(missing["error"]?["code"]?.intValue == -32600)
        let unknown = try await call(server, ["jsonrpc": "2.0", "id": 2, "method": "resources/list"])
        #expect(unknown["error"]?["code"]?.intValue == -32601)
        let unknownTool = try await tool(server, "nope", [:])
        #expect(unknownTool["error"]?["code"]?.intValue == -32601)
        let noName = try await call(server, ["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": [:]])
        #expect(noName["error"]?["code"]?.intValue == -32602)
    }

    @Test("格律与字音工具")
    func readTools() async throws {
        let directory = try TemporaryDirectory()
        let (server, _) = try makeServer(directory)
        let check = try await tool(server, "check_poem", ["text": "白日依山尽，黄河入海流。欲穷千里目，更上一层楼。"])
        #expect(check["result"]?["isError"]?.boolValue == false)
        #expect(check["result"]?["structuredContent"]?["form"]?.stringValue == "五绝")

        let ci = try await tool(server, "check_poem", ["text": "春风", "form": "望江南", "rhyme_book": "cilin"])
        #expect(ci["result"]?["structuredContent"]?["form"]?.stringValue == "词·忆江南")

        let badForm = try await tool(server, "check_poem", ["text": "春风", "form": "八绝"])
        #expect(badForm["result"]?["isError"]?.boolValue == true)
        let badBook = try await tool(server, "check_poem", ["text": "春风", "rhyme_book": "xx"])
        #expect(badBook["result"]?["isError"]?.boolValue == true)
        let noText = try await tool(server, "check_poem", [:])
        #expect(noText["result"]?["isError"]?.boolValue == true)

        let lookup = try await tool(server, "lookup_char", ["char": "看"])
        let text = lookup["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("上平·十四寒"))
        let badChar = try await tool(server, "lookup_char", ["char": "看见"])
        #expect(badChar["result"]?["isError"]?.boolValue == true)

        let forms = try await tool(server, "list_forms", [:])
        #expect(forms["result"]?["structuredContent"]?["ci"]?.arrayValue?.isEmpty == false)
    }

    @Test("候选、收藏写入与只读模式")
    func writeTools() async throws {
        let directory = try TemporaryDirectory()
        let counter = ChangeCounter()
        let (server, service) = try makeServer(directory, counter: counter)
        try await service.installPack(from: try Fixtures.makePack(in: directory))
        _ = try await call(server, ["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["clientInfo": ["name": "claude"]]])

        let added = try await tool(server, "add_phrase", [
            "text": "白日依山尽", "tags": ["景/山"], "claimed_source": ["author": "李白"], "reason": "测试",
        ])
        #expect(added["result"]?["isError"]?.boolValue == false)
        let structured = added["result"]?["structuredContent"]
        #expect(structured?["status"]?.stringValue == "收件箱")
        #expect(structured?["source_verified"]?.boolValue == true)
        #expect(counter.count == 1)
        let stored = try #require(try service.library.phrases().first)
        #expect(stored.provenance.agentClient == "claude")
        #expect(stored.tags.first?.addedBy == .agent)

        let tagged = try await tool(server, "tag_phrase", ["id": .string(stored.id.uuidString), "tags": ["季节/秋"]])
        #expect(tagged["result"]?["isError"]?.boolValue == false)
        let badID = try await tool(server, "tag_phrase", ["id": "x", "tags": ["a"]])
        #expect(badID["result"]?["isError"]?.boolValue == true)
        let noTags = try await tool(server, "tag_phrase", ["id": .string(stored.id.uuidString), "tags": []])
        #expect(noTags["result"]?["isError"]?.boolValue == true)

        let search = try await tool(server, "search_phrases", ["query": "秋", "include_inbox": true])
        #expect(search["result"]?["structuredContent"]?["phrases"]?.arrayValue?.count == 1)
        let badQuery = try await tool(server, "search_phrases", ["query": "月|"])
        #expect(badQuery["result"]?["isError"]?.boolValue == true)

        let candidates = try await tool(server, "find_candidates", ["pattern": "平平", "source": "corpus", "limit": 5])
        let items = candidates["result"]?["structuredContent"]?["candidates"]?.arrayValue ?? []
        #expect(!items.isEmpty && items.count <= 5)
        let rhymed = try await tool(server, "find_candidates", ["pattern": "中平", "rhyme_char": "楼"])
        let rhymedTexts = rhymed["result"]?["structuredContent"]?["candidates"]?.arrayValue?.compactMap { $0["text"]?.stringValue } ?? []
        #expect(rhymedTexts.contains("河流") || rhymedTexts.contains("层楼"))
        for bad: JSONValue in [["pattern": "平x"], ["pattern": "平中", "rhyme_char": "楼"], ["pattern": "平平", "source": "web"],
                               ["pattern": "平平", "limit": 0], ["pattern": "平平", "rhyme_char": "月"]] {
            let response = try await tool(server, "find_candidates", bad)
            #expect(response["result"]?["isError"]?.boolValue == true, "\(bad)")
        }

        let usages = try await tool(server, "find_usages", ["text": "明月"])
        #expect(usages["result"]?["structuredContent"]?["lines"]?.arrayValue?.count == 2, "同一作品只取一句")
        let related = try await tool(server, "related_lines", ["text": "低头望明月", "limit": 1])
        #expect(related["result"]?["structuredContent"]?["lines"]?.arrayValue?.count == 1)

        try service.library.setBool(.mcpReadOnly, true)
        let refused = try await tool(server, "add_phrase", ["text": "孤鸿"])
        #expect(refused["result"]?["isError"]?.boolValue == true)
        let refusedImport = try await tool(server, "import_pack", ["path": "/tmp"])
        #expect(refusedImport["result"]?["isError"]?.boolValue == true)
        #expect(try service.library.phrases().count == 1)
        #expect(counter.count == 2)
    }

    @Test("JSON 值编解码")
    func jsonValue() throws {
        let value: JSONValue = ["a": 1, "b": [true, "x", .null], "c": .number(1.5)]
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(try value.encodedString().utf8))
        #expect(decoded == value)
        #expect(try JSONValue.int(3).encodedString() == "3")
        #expect(JSONValue.number(1.5).intValue == nil)
        #expect(JSONValue.string("x")["k"] == nil)
    }
}
