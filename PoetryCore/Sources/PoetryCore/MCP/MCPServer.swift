import Foundation

/// MCP 服务（JSON-RPC 2.0，按行分隔，经 stdio 传输）。只提供数据读写与格律查询，不含任何 AI 逻辑。
public final class MCPServer {
    public static let serverName = "shici-mcp"
    public static let serverVersion = "0.1.0"
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    private let service: PoetryService
    private var clientName = "unknown"
    /// 写入后调用（默认发送跨进程通知，测试中可替换）。
    private let onLibraryChange: () -> Void

    public init(service: PoetryService, onLibraryChange: @escaping () -> Void = {
        if !LibraryChangeNotification.post() {
            FileHandle.standardError.write(Data("shici-mcp: 变更通知发送失败\n".utf8))
        }
    }) {
        self.service = service
        self.onLibraryChange = onLibraryChange
    }

    struct RPCError: Error {
        let code: Int
        let message: String

        static func invalidParams(_ message: String) -> RPCError { RPCError(code: -32602, message: message) }
    }

    /// 处理一行请求；通知（无 id）返回 nil。
    public func handle(line: String) async -> String? {
        let request: JSONValue
        do {
            request = try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
        } catch {
            return encode(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "JSON 解析失败"]])
        }
        guard case .object = request, let method = request["method"]?.stringValue else {
            return encode(["jsonrpc": "2.0", "id": request["id"] ?? .null,
                           "error": ["code": -32600, "message": "无效请求：缺少 method"]])
        }
        let id = request["id"]
        let params = request["params"] ?? [:]
        do {
            let result = try await dispatch(method: method, params: params)
            guard let id else { return nil }
            return encode(["jsonrpc": "2.0", "id": id, "result": result])
        } catch let error as RPCError {
            guard let id else { return nil }
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]])
        } catch {
            guard let id else { return nil }
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": .string(String(describing: error))]])
        }
    }

    private func encode(_ value: JSONValue) -> String {
        do {
            return try value.encodedString()
        } catch {
            return #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"响应编码失败"}}"#
        }
    }

    private func dispatch(method: String, params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            clientName = params["clientInfo"]?["name"]?.stringValue ?? "unknown"
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = MCPServer.supportedProtocolVersions.contains(requested) ? requested : MCPServer.supportedProtocolVersions[0]
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(MCPServer.serverName), "version": .string(MCPServer.serverVersion)],
                "instructions": "诗词助手：格律校验、字音查询、按平仄检索替换候选、收藏与标签。agent 写入的收藏会标记来源，默认进入收件箱等待用户确认。",
            ]
        case "notifications/initialized", "notifications/cancelled":
            return .null
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": .array(MCPTools.definitions)]
        case "tools/call":
            guard let name = params["name"]?.stringValue else { throw RPCError.invalidParams("缺少工具名 name") }
            let arguments = params["arguments"] ?? [:]
            do {
                let (text, structured) = try await callTool(name, arguments)
                return ["content": [["type": "text", "text": .string(text)]], "structuredContent": structured, "isError": false]
            } catch let error as RPCError where error.code == -32601 {
                throw error
            } catch {
                let message = (error as? RPCError)?.message ?? String(describing: error)
                return ["content": [["type": "text", "text": .string(message)]], "isError": true]
            }
        default:
            throw RPCError(code: -32601, message: "不支持的方法：\(method)")
        }
    }

    // MARK: - 工具

    private func requireWritable() throws {
        if try service.library.bool(.mcpReadOnly) {
            throw RPCError.invalidParams("诗词助手已开启 MCP 只读模式，拒绝写入")
        }
    }

    private func string(_ arguments: JSONValue, _ key: String, required: Bool = true) throws -> String? {
        let value = arguments[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        if required, (value ?? "").isEmpty { throw RPCError.invalidParams("缺少参数 \(key)") }
        return (value ?? "").isEmpty ? nil : value
    }

    private func book(_ arguments: JSONValue, default fallback: RhymeBook = .pingshui) throws -> RhymeBook {
        guard let raw = arguments["rhyme_book"]?.stringValue else { return fallback }
        guard let book = RhymeBook(rawValue: raw) ?? RhymeBook.allCases.first(where: { $0.displayName == raw }) else {
            throw RPCError.invalidParams("rhyme_book 应为 pingshui、cilin 或 tongyun")
        }
        return book
    }

    private func limit(_ arguments: JSONValue, default fallback: Int, max: Int = 200) throws -> Int {
        guard let value = arguments["limit"] else { return fallback }
        guard let number = value.intValue, number > 0 else { throw RPCError.invalidParams("limit 应为正整数") }
        return min(number, max)
    }

    func resolveForm(_ raw: String?) throws -> FormSelection {
        guard let raw, !raw.isEmpty, raw != "auto", raw != "自动" else { return .automatic }
        if raw == "free" || raw == "自由" { return .free }
        if let form = RegulatedForm(rawValue: raw) { return .regulated(form) }
        if let stored = FormSelection(storageValue: raw), case .ci(let id) = stored, service.analyzer.tunes.tune(id: id) != nil {
            return stored
        }
        if let tune = service.analyzer.tunes.tunes.first(where: { $0.id == raw || $0.name == raw || $0.aliases.contains(raw) }) {
            return .ci(tune.id)
        }
        throw RPCError.invalidParams("未知体裁「\(raw)」；可用 auto、free、五绝、七绝、五律、七律或词牌名")
    }

    private func phraseJSON(_ phrase: Phrase) -> JSONValue {
        [
            "id": .string(phrase.id.uuidString),
            "text": .string(phrase.text),
            "kind": .string(phrase.kind.rawValue),
            "status": .string(phrase.status.displayName),
            "source_kind": .string(phrase.provenance.kind.rawValue),
            "source": .optional(phrase.provenance.source.map(\.summary)),
            "source_verified": .bool(phrase.provenance.source?.isVerified ?? false),
            "tags": .array(phrase.tags.map { .string($0.path) }),
            "note": .optional(phrase.note),
        ]
    }

    private func lineJSON(_ line: CorpusLine) -> JSONValue {
        ["text": .string(line.text), "source": .string(line.sourceSummary), "pack": .string(line.packName)]
    }

    private func callTool(_ name: String, _ arguments: JSONValue) async throws -> (String, JSONValue) {
        let dictionary = service.dictionary
        switch name {
        case "check_poem":
            let text = try string(arguments, "text") ?? ""
            let analysis = service.analyze(text, form: try resolveForm(arguments["form"]?.stringValue), book: try book(arguments))
            let issues: [JSONValue] = analysis.issues.map {
                ["severity": .string($0.severity.displayName), "kind": .string($0.kind.rawValue), "message": .string($0.message)]
            }
            let lines: [JSONValue] = analysis.lines.map { line in
                ["text": .string(line.text), "pattern": .optional(line.patternText),
                 "tones": .string(String(line.characters.map { character -> Character in
                     character.tones.count == 1 ? Character(character.tones.first?.rawValue ?? "？") : (character.tones.isEmpty ? "？" : "中")
                 }))]
            }
            var summary = "\(analysis.formName)\(analysis.variantName.map { "（\($0)）" } ?? "")，\(analysis.book.displayName)："
            summary += "错误 \(analysis.errorCount)，警告 \(analysis.warningCount)"
            for issue in analysis.issues { summary += "\n[\(issue.severity.displayName)] \(issue.message)" }
            return (summary, ["form": .string(analysis.formName), "variant": .optional(analysis.variantName),
                              "rhyme_book": .string(analysis.book.rawValue), "issues": .array(issues), "lines": .array(lines)])

        case "lookup_char":
            let raw = try string(arguments, "char") ?? ""
            guard raw.count == 1, let character = raw.first, TextSegmenter.isHan(character) else {
                throw RPCError.invalidParams("char 应为单个汉字")
            }
            var books: [String: JSONValue] = [:]
            var lines: [String] = []
            for book in RhymeBook.allCases {
                let readings = dictionary.readings(of: character, in: book)
                books[book.rawValue] = .array(readings.map { ["tone": .string($0.tone.rawValue), "rhyme": .string(dictionary.displayName(of: $0.rhyme))] })
                let text = readings.isEmpty ? "未收录" : readings.map { "\($0.tone.rawValue)·\(dictionary.displayName(of: $0.rhyme))" }.joined(separator: "，")
                lines.append("\(book.displayName)：\(text)")
            }
            let pinyin = dictionary.syllables(of: character).map(\.plain)
            lines.insert("拼音：\(pinyin.joined(separator: "、"))", at: 0)
            return ("「\(character)」\n" + lines.joined(separator: "\n"),
                    ["char": .string(String(character)), "pinyin": .array(pinyin.map(JSONValue.string)), "readings": .object(books)])

        case "list_forms":
            let regulated: [JSONValue] = RegulatedForm.allCases.map { .string($0.rawValue) }
            let tunes: [JSONValue] = service.analyzer.tunes.tunes.map { tune in
                ["id": .string(tune.id), "name": .string(tune.name), "aliases": .array(tune.aliases.map(JSONValue.string)),
                 "summary": .string(tune.summary), "pattern": .array(tune.lines.map { .string($0.patternText + ($0.rhymeGroup ?? "")) })]
            }
            let text = "近体：" + RegulatedForm.allCases.map(\.rawValue).joined(separator: "、")
                + "\n词牌：" + service.analyzer.tunes.tunes.map { "\($0.name)（\($0.id)）" }.joined(separator: "、")
            return (text, ["regulated": .array(regulated), "ci": .array(tunes)])

        case "find_candidates":
            let pattern = try string(arguments, "pattern") ?? ""
            var slots: [ToneSlot] = []
            for character in pattern {
                guard let slot = ToneSlot(rawValue: character) else { throw RPCError.invalidParams("pattern 只能由平、仄、中组成") }
                slots.append(slot)
            }
            let rhymeBook = try book(arguments)
            var rhyme: RhymeRequirement?
            if let rhymeRaw = try string(arguments, "rhyme_char", required: false) {
                guard let rhymeCharacter = rhymeRaw.first, rhymeRaw.count == 1 else { throw RPCError.invalidParams("rhyme_char 应为单个汉字") }
                guard let tone = slots.last?.tone else { throw RPCError.invalidParams("指定 rhyme_char 时 pattern 末位须为平或仄") }
                guard let key = dictionary.readings(of: rhymeCharacter, in: rhymeBook).first(where: { $0.tone == tone })?.rhyme else {
                    throw RPCError.invalidParams("「\(rhymeCharacter)」在\(rhymeBook.displayName)中没有\(tone.rawValue)声读音")
                }
                rhyme = RhymeRequirement(key: key, tone: tone)
            }
            let filter = try PhraseFilterParser.parse(arguments["tags"]?.stringValue ?? "")
            let sourceRaw = arguments["source"]?.stringValue ?? "all"
            guard ["all", "collection", "corpus"].contains(sourceRaw) else { throw RPCError.invalidParams("source 应为 all、collection 或 corpus") }
            let options = CandidateOptions(includeCollection: sourceRaw != "corpus", includeCorpus: sourceRaw != "collection",
                                           filter: filter, limit: try limit(arguments, default: 30))
            let constraint = SlotConstraint(slots: slots, rhyme: rhyme, book: rhymeBook)
            let candidates = try await service.candidates(for: constraint, options: options)
            let items: [JSONValue] = candidates.map { candidate in
                let source: String
                if case .collection = candidate.source { source = "收藏" } else { source = "语料" }
                return ["text": .string(candidate.text), "source": .string(source), "frequency": .int(candidate.frequency),
                        "tags": .array(candidate.tags.map(JSONValue.string))]
            }
            let text = candidates.isEmpty ? "没有符合「\(pattern)」的候选"
                : candidates.map { candidate in
                    if case .collection = candidate.source { return "\(candidate.text)（收藏）" }
                    return "\(candidate.text)（语料 \(candidate.frequency)）"
                }.joined(separator: "、")
            return (text, ["pattern": .string(pattern), "candidates": .array(items)])

        case "search_phrases":
            let phrases = try service.searchPhrases(arguments["query"]?.stringValue ?? "",
                                                    includeInbox: arguments["include_inbox"]?.boolValue ?? false)
            let limited = Array(phrases.prefix(try limit(arguments, default: 50)))
            let text = limited.isEmpty ? "没有匹配的收藏"
                : limited.map { "\($0.text)\($0.tags.isEmpty ? "" : " #" + $0.tagPaths.joined(separator: " #"))" }.joined(separator: "\n")
            return (text, ["phrases": .array(limited.map(phraseJSON))])

        case "find_usages", "related_lines":
            let text = try string(arguments, "text") ?? ""
            let count = try limit(arguments, default: 20, max: 100)
            let lines = name == "find_usages" ? try await service.corpus.usages(of: text, limit: count)
                : try await service.corpus.related(to: text, limit: count)
            let summary = lines.isEmpty ? "语料中没有找到" : lines.map { "\($0.text)　\($0.sourceSummary)" }.joined(separator: "\n")
            return (summary, ["lines": .array(lines.map(lineJSON))])

        case "add_phrase":
            try requireWritable()
            let text = try string(arguments, "text") ?? ""
            var kind: PhraseKind?
            if let rawKind = try string(arguments, "kind", required: false) {
                guard let parsed = PhraseKind(rawValue: rawKind) else { throw RPCError.invalidParams("kind 应为字、词、句或联") }
                kind = parsed
            }
            var claimed: SourceInfo?
            if let source = arguments["claimed_source"], case .object = source {
                claimed = SourceInfo(author: source["author"]?.stringValue, title: source["title"]?.stringValue,
                                     dynasty: source["dynasty"]?.stringValue, url: source["url"]?.stringValue)
            }
            let tags = (arguments["tags"]?.arrayValue ?? []).compactMap(\.stringValue)
            let provenance = Provenance(kind: .agent, agentClient: clientName, agentNote: arguments["reason"]?.stringValue,
                                        claimedSource: claimed)
            let result = try await service.addPhrase(PhraseDraft(text: text, kind: kind, provenance: provenance, tags: tags,
                                                                 note: arguments["note"]?.stringValue), actor: .agent)
            onLibraryChange()
            var message = "已收藏「\(result.phrase.text)」（\(result.phrase.status.displayName)）"
            if let match = result.corpusMatch { message += "；语料反查出处：\(match.summary)" }
            return (message, phraseJSON(result.phrase))

        case "tag_phrase":
            try requireWritable()
            guard let rawID = try string(arguments, "id"), let id = UUID(uuidString: rawID) else {
                throw RPCError.invalidParams("id 应为收藏的 UUID")
            }
            let tags = (arguments["tags"]?.arrayValue ?? []).compactMap(\.stringValue)
            guard !tags.isEmpty else { throw RPCError.invalidParams("tags 不能为空") }
            let phrase = try service.addTags(tags, to: id, actor: .agent)
            onLibraryChange()
            return ("已为「\(phrase.text)」添加标签：\(tags.joined(separator: "、"))", phraseJSON(phrase))

        case "import_pack":
            try requireWritable()
            let path = try string(arguments, "path") ?? ""
            let report = try await service.installPack(from: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
            onLibraryChange()
            return ("已导入「\(report.name)」：\(report.workCount) 篇、\(report.lineCount) 句，跳过 \(report.skippedRecords) 条",
                    ["pack_id": .string(report.packID), "works": .int(report.workCount), "lines": .int(report.lineCount),
                     "skipped": .int(report.skippedRecords), "errors": .array(report.errors.map(JSONValue.string))])

        default:
            throw RPCError(code: -32601, message: "未知工具：\(name)")
        }
    }
}

/// 工具定义（JSON Schema）。
enum MCPTools {
    private static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map(JSONValue.string))]
    }

    private static let bookProperty: JSONValue = ["type": "string", "enum": ["pingshui", "cilin", "tongyun"],
                                                  "description": "韵书：平水韵、词林正韵、中华通韵，默认 pingshui"]
    private static let limitProperty: JSONValue = ["type": "integer", "minimum": 1, "description": "返回条数上限"]

    static let definitions: [JSONValue] = [
        ["name": "check_poem", "description": "检查诗词格律（近体诗平仄、粘对、押韵，或词谱）。",
         "inputSchema": schema([
            "text": ["type": "string", "description": "正文"],
            "form": ["type": "string", "description": "auto、free、五绝、七绝、五律、七律，或词牌名/id（见 list_forms）"],
            "rhyme_book": bookProperty,
         ], required: ["text"])],
        ["name": "lookup_char", "description": "查询单字在三套韵书中的平仄与韵部，以及今音拼音。",
         "inputSchema": schema(["char": ["type": "string", "description": "单个汉字"]], required: ["char"])],
        ["name": "list_forms", "description": "列出支持的近体诗体裁与内置词谱。", "inputSchema": schema([:])],
        ["name": "find_candidates", "description": "按平仄模式检索可替换的词句（收藏优先，其次语料）。",
         "inputSchema": schema([
            "pattern": ["type": "string", "description": "由平、仄、中组成，例如「平仄仄」"],
            "rhyme_char": ["type": "string", "description": "可选：末字须与此字同韵"],
            "rhyme_book": bookProperty,
            "tags": ["type": "string", "description": "可选：收藏筛选表达式，如「季节/秋 月|雁」"],
            "source": ["type": "string", "enum": ["all", "collection", "corpus"]],
            "limit": limitProperty,
         ], required: ["pattern"])],
        ["name": "search_phrases", "description": "按筛选表达式检索收藏。空格为且，| 为或，- 为非；支持 字数:N、类型:句、来源:摘录、含:月。",
         "inputSchema": schema([
            "query": ["type": "string"], "include_inbox": ["type": "boolean"], "limit": limitProperty,
         ])],
        ["name": "find_usages", "description": "前人用例：语料中包含该词句的诗句（同一作品只取一句）。",
         "inputSchema": schema(["text": ["type": "string"], "limit": limitProperty], required: ["text"])],
        ["name": "related_lines", "description": "相关诗句：按字词重合度检索语料（非 AI）。",
         "inputSchema": schema(["text": ["type": "string"], "limit": limitProperty], required: ["text"])],
        ["name": "add_phrase", "description": "写入一条收藏。来源记为 agent；声称的出处会经语料反查核实；默认进入收件箱待用户确认。",
         "inputSchema": schema([
            "text": ["type": "string"],
            "kind": ["type": "string", "enum": ["字", "词", "句", "联"]],
            "tags": ["type": "array", "items": ["type": "string"], "description": "层级标签，如「季节/秋」"],
            "claimed_source": ["type": "object", "properties": [
                "author": ["type": "string"], "title": ["type": "string"], "dynasty": ["type": "string"], "url": ["type": "string"],
            ]],
            "reason": ["type": "string", "description": "写入理由，供用户审阅"],
            "note": ["type": "string"],
         ], required: ["text"])],
        ["name": "tag_phrase", "description": "给已有收藏追加标签。",
         "inputSchema": schema([
            "id": ["type": "string", "description": "收藏 UUID"],
            "tags": ["type": "array", "items": ["type": "string"]],
         ], required: ["id", "tags"])],
        ["name": "import_pack", "description": "安装并导入语料包目录（含 manifest.json）。",
         "inputSchema": schema(["path": ["type": "string", "description": "语料包目录的绝对路径"]], required: ["path"])],
    ]
}
