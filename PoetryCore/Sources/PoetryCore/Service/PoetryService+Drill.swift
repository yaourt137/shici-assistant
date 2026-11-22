import Foundation

/// 律诗对仗中常与某字词相对的一边。
public struct ParallelCounterpart: Sendable, Hashable {
    public let text: String
    public let count: Int
}

/// 律诗对仗中的一个用例。
public struct ParallelExample: Sendable, Hashable, Identifiable {
    public let couplet: ParallelCouplet
    /// 出处说明，例如「〔唐〕王维《山居秋暝》」。
    public let source: String
    /// 所查字词在两句中同位相对的起始位置。
    public let positions: [Int]

    public var id: String { "\(couplet.workID)-\(couplet.lineIndex)" }
}

/// 某出题的参考。
public struct CoupletReferences: Sendable {
    /// 题库中与出题相对的各边（原书、原诗），按题库顺序。
    public let references: [DrillReference]
    /// 律诗对仗中常与出题相对的字词（出题为一两字时才有）。
    public let commonCounterparts: [ParallelCounterpart]
}

/// 一次对仗评分及其参考。
public struct CoupletEvaluation: Sendable {
    public let score: CoupletScore
    public let references: [DrillReference]
    public let commonCounterparts: [ParallelCounterpart]
}

extension PoetryService {
    /// 准备题库：对仗统计与当前语料不一致时先重建；语料、佩文韵府未变时沿用上次的题库。
    nonisolated(nonsending) public func prepareDrill(progress: @Sendable (ImportProgress) -> Void = { _ in }) async throws -> DrillPool {
        if !(try await corpus.isParallelIndexCurrent()) {
            try await corpus.buildParallelIndex(progress: progress)
        }
        let yunfu = try await classics.installed().first { $0.work == .peiwenYunfu }
        let signature = try await corpus.parallelSignature() + "|\(yunfu?.importedAt.timeIntervalSince1970 ?? 0)"
        if let cache = drillPoolCache, cache.signature == signature { return cache.pool }

        var items = primers.flatMap { primer in
            primer.couplets.map { DrillItem(left: $0.left, right: $0.right, source: .primer(primer.work, sectionIndex: $0.sectionIndex)) }
        }
        if yunfu != nil {
            items += try await classics.allDuiyu().compactMap { entry in
                entry.counterpart.map { DrillItem(left: $0, right: entry.phrase, source: .yunfu(head: entry.head, groupID: entry.groupID)) }
            }
        }
        items += try await corpus.parallelCouplets().map {
            DrillItem(left: $0.left, right: $0.right, source: .corpus(workID: $0.workID, lineIndex: $0.lineIndex))
        }
        let pool = DrillPool(items: items, converter: dictionary.converter)
        drillPoolCache = (signature, pool)
        return pool
    }

    /// 按选项随机抽题（「只出新题」「只出答过的」依练习记录）；没有符合条件的题时为 nil。
    nonisolated(nonsending) public func drawDrillQuestion(_ options: DrillOptions) async throws -> DrillQuestion? {
        let pool = try await prepareDrill()
        var generator = SystemRandomNumberGenerator()
        return pool.draw(options, answeredKeys: try library.answeredDrillKeys(), using: &generator)
    }

    /// 出题的参考：题库中的另一边，与律诗对仗中的常见对（出题为一两字时）。
    nonisolated(nonsending) public func coupletReferences(for prompt: String) async throws -> CoupletReferences {
        let promptNorm = dictionary.converter.simplified(TextSegmenter.hanOnly(prompt))
        guard !promptNorm.isEmpty else { throw CoupletScoreError.emptyPrompt }
        let references = try await prepareDrill().references(for: prompt)
        let common = promptNorm.count <= 2
            ? try await corpus.parallelCounterparts(of: promptNorm).map { ParallelCounterpart(text: $0.text, count: $0.count) }
            : []
        return CoupletReferences(references: references, commonCounterparts: common)
    }

    /// 律诗对仗中 `text` 与 `counterpart` 同位相对的联（繁简不论），附出处：返回总联数与前 `limit` 联。
    nonisolated(nonsending) public func parallelExamples(of text: String, with counterpart: String,
                                                         limit: Int = 100) async throws -> (total: Int, examples: [ParallelExample]) {
        let converter = dictionary.converter
        let word = converter.simplified(TextSegmenter.hanOnly(text))
        let other = converter.simplified(TextSegmenter.hanOnly(counterpart))
        let found = try await corpus.parallelExamples(of: word, with: other, limit: limit)
        var sources: [Int64: String] = [:]
        var examples: [ParallelExample] = []
        for couplet in found.couplets {
            let source: String
            if let known = sources[couplet.workID] {
                source = known
            } else {
                source = try await describe(.corpus(workID: couplet.workID, lineIndex: couplet.lineIndex))
                sources[couplet.workID] = source
            }
            examples.append(ParallelExample(couplet: couplet, source: source, positions: ParallelCouplets.alignedPositions(
                of: word, with: other, left: couplet.left, right: couplet.right)))
        }
        return (found.total, examples)
    }

    /// 评分：对句与题库中某一边相同即注明出处；附参考。
    nonisolated(nonsending) public func evaluateCouplet(prompt: String, answer: String) async throws -> CoupletEvaluation {
        let converter = dictionary.converter
        let references = try await coupletReferences(for: prompt)
        let counts = try await corpus.pairCounts(CoupletScorer.lookupKeys(prompt: prompt, answer: answer, converter: converter))
        let answerNorm = converter.simplified(TextSegmenter.hanOnly(answer))
        var knownSource: String?
        if !answerNorm.isEmpty,
           let match = references.references.first(where: { converter.simplified(TextSegmenter.hanOnly($0.counterpart)) == answerNorm }) {
            knownSource = try await describe(match.source)
        }
        let thresholds = CoupletScorer.Thresholds.scaled(coupletCount: try await corpus.parallelCoupletCount())
        let score = try CoupletScorer.score(prompt: prompt, answer: answer, dictionary: dictionary, pairCounts: counts,
                                            knownSource: knownSource, thresholds: thresholds)
        return CoupletEvaluation(score: score, references: references.references, commonCounterparts: references.commonCounterparts)
    }

    /// 记下一次作答。
    @discardableResult
    nonisolated(nonsending) public func recordDrill(_ question: DrillQuestion, answer: String,
                                                    level: CoupletScore.Level) async throws -> DrillAttempt {
        let attempt = DrillAttempt(mode: question.mode, questionKey: question.key, prompt: question.prompt, answer: answer,
                                   level: level, source: try await describe(question.source))
        try library.save(attempt)
        return attempt
    }

    /// 收藏原书或原诗中的一对（练习的原文或参考）：出处记为摘录，语料作品记作者、题目与朝代，典籍记书名；
    /// 标签按出的字数为「对仗/对词」或「对仗/对句」。语料中找不到该作品时不记出处。
    nonisolated(nonsending) public func referencePhraseDraft(prompt: String, counterpart: String, isPromptLeft: Bool,
                                                             source: DrillItemSource) async throws -> PhraseDraft {
        let promptLength = TextSegmenter.hanOnly(prompt).count
        guard promptLength > 0 else { throw CoupletScoreError.emptyPrompt }
        guard !TextSegmenter.hanOnly(counterpart).isEmpty,
              let text = DrillCouplet.text(prompt: prompt, counterpart: counterpart, isPromptLeft: isPromptLeft) else {
            throw CoupletScoreError.emptyAnswer
        }
        var info: SourceInfo?
        var links: [CorpusWorkLink]?
        switch source {
        case .primer(let work, _): info = SourceInfo(title: work.name)
        case .yunfu: info = SourceInfo(title: "佩文韵府")
        case .corpus(let workID, let lineIndex):
            info = try await corpus.work(id: workID).map { SourceInfo(author: $0.author, title: $0.title, dynasty: $0.dynasty) }
            links = try await corpusLink(workID: workID, lineIndex: lineIndex).map { [$0] }
        }
        return PhraseDraft(text: text, kind: .couplet, provenance: Provenance(kind: .excerpt, source: info, corpusLinks: links),
                           tags: ["对仗/\(DrillMode(length: promptLength).displayName)"])
    }

    /// 收藏律诗对仗中的一对字词（如「魚塍」对「雉媒」）：用第一联的原书字形，按其上下排列，出处记第一首；
    /// 附到各首原诗的链接（至多 `linkLimit` 首），备注相对的联数。两者繁简不论，须等长且不同；律诗中没有这样相对的联时报错。
    nonisolated(nonsending) public func pairPhraseDraft(of text: String, with counterpart: String,
                                                        linkLimit: Int = 20) async throws -> PhraseDraft {
        let converter = dictionary.converter
        let word = converter.simplified(TextSegmenter.hanOnly(text))
        let other = converter.simplified(TextSegmenter.hanOnly(counterpart))
        guard !word.isEmpty else { throw CoupletScoreError.emptyPrompt }
        guard !other.isEmpty else { throw CoupletScoreError.emptyAnswer }
        let found = try await corpus.parallelExamples(of: word, with: other, limit: 1_000)
        guard let first = found.couplets.first,
              let start = ParallelCouplets.alignedPositions(of: word, with: other, left: first.left, right: first.right).first else {
            throw LibraryError.notFound("律诗对仗中「\(word)」与「\(other)」相对的联")
        }
        let range = start..<start + word.count
        let wordOnLeft = String(Array(first.left)[range]) == word
        // 取原书字形；原句与简体句对不上时退回简体。
        var (shownWord, shownOther) = (word, other)
        if let lines = try await corpus.originalLines(id: first.workID), lines.indices.contains(first.lineIndex + 1) {
            let (left, right) = (Array(lines[first.lineIndex]), Array(lines[first.lineIndex + 1]))
            if left.count == first.left.count, right.count == first.right.count {
                let (wordSide, otherSide) = wordOnLeft ? (left, right) : (right, left)
                let (originalWord, originalOther) = (String(wordSide[range]), String(otherSide[range]))
                if converter.simplified(originalWord) == word, converter.simplified(originalOther) == other {
                    (shownWord, shownOther) = (originalWord, originalOther)
                }
            }
        }
        guard let phrase = DrillCouplet.text(prompt: shownWord, counterpart: shownOther, isPromptLeft: wordOnLeft) else {
            throw CoupletScoreError.emptyAnswer
        }
        var links: [CorpusWorkLink] = []
        var linkedWorks = Set<Int64>()
        let allWorks = Set(found.couplets.map(\.workID))
        for couplet in found.couplets where links.count < max(0, linkLimit) && !linkedWorks.contains(couplet.workID) {
            linkedWorks.insert(couplet.workID)
            if let link = try await corpusLink(workID: couplet.workID, lineIndex: couplet.lineIndex) { links.append(link) }
        }
        let info = try await corpus.work(id: first.workID).map { SourceInfo(author: $0.author, title: $0.title, dynasty: $0.dynasty) }
        let note = "律诗对仗中相对 \(found.total) 联" + (linkedWorks.count < allWorks.count ? "，只链接前 \(links.count) 首" : "")
        return PhraseDraft(text: phrase, kind: .couplet,
                           provenance: Provenance(kind: .excerpt, source: info, corpusLinks: links.isEmpty ? nil : links),
                           tags: ["对仗/\(DrillMode(length: word.count).displayName)"], note: note)
    }

    /// 到语料作品的链接，附出处与原书字形的一联（第 `lineIndex` 句及其下一句）。作品不存在或没有全文哈希时为 nil。
    nonisolated(nonsending) public func corpusLink(workID: Int64, lineIndex: Int?) async throws -> CorpusWorkLink? {
        guard let hash = try await corpus.textHash(ofWork: workID), let work = try await corpus.work(id: workID) else { return nil }
        let summary = SourceInfo(author: work.author, title: work.title, dynasty: work.dynasty).summary
        var excerpt: String?
        if let lineIndex, let lines = try await corpus.originalLines(id: workID), lines.indices.contains(lineIndex) {
            excerpt = lines.indices.contains(lineIndex + 1) ? lines[lineIndex] + "，" + lines[lineIndex + 1] : lines[lineIndex]
        }
        return CorpusWorkLink(textHash: hash, summary: summary.isEmpty ? work.packName : summary, excerpt: excerpt)
    }

    /// 出处说明，例如「声律启蒙·一、東」「佩文韵府对语·東（上平·一东）」「〔唐〕杜甫《登高》」。
    nonisolated(nonsending) public func describe(_ source: DrillItemSource) async throws -> String {
        switch source {
        case .primer(let work, let index):
            let sections = primer(work).sections
            return "\(work.name)·" + (sections.indices.contains(index) ? sections[index].title : "?")
        case .yunfu(let head, let groupID):
            let groups = dictionary.groups
            return "佩文韵府对语·\(head)" + (groups.indices.contains(groupID) ? "（\(groups[groupID].displayName)）" : "")
        case .corpus(let workID, _):
            guard let work = try await corpus.work(id: workID) else { return "语料" }
            let summary = SourceInfo(author: work.author, title: work.title, dynasty: work.dynasty).summary
            return summary.isEmpty ? work.packName : summary
        }
    }
}
