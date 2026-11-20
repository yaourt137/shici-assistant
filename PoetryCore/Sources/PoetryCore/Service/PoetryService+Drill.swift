import Foundation

/// 律诗对仗中常与某字词相对的一边。
public struct ParallelCounterpart: Sendable, Hashable {
    public let text: String
    public let count: Int
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
