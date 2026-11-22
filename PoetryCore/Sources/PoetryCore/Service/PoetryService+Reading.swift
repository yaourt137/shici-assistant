import Foundation

extension PoetryService {
    /// 从语料打开一首读：已有题目、作者、正文都相同的圈点本则沿用（并记为刚读过），否则新建。正文用原书字形。
    nonisolated(nonsending) public func openMarkedPoem(corpusWorkID: Int64, now: Date = Date()) async throws -> MarkedPoem {
        guard let work = try await corpus.work(id: corpusWorkID), let original = try await corpus.originalBody(id: corpusWorkID) else {
            throw LibraryError.notFound("语料作品 \(corpusWorkID)")
        }
        let body = MarkedPoem.normalizedBody(original)
        guard !TextSegmenter.hanOnly(body).isEmpty else { throw LibraryError.emptyText }
        let title = work.title ?? ""
        if var existing = try library.markedPoem(title: title, author: work.author, body: body) {
            existing.updatedAt = now
            try library.save(existing)
            return existing
        }
        let poem = MarkedPoem(title: title, author: work.author, dynasty: work.dynasty,
                              origin: .corpus(packName: work.packName, workID: work.id), body: body, createdAt: now, updatedAt: now)
        try library.save(poem)
        return poem
    }

    /// 转为繁体：逐句先在已启用的繁体语料中找原句照抄字形，找不到的逐字查字表（多种繁体的列出待核对）。
    nonisolated(nonsending) public func traditionalConversion(of text: String) async throws -> TraditionalConversion {
        let converter = dictionary.converter
        let norms = TextSegmenter.segments(of: text).map { converter.simplified(String($0.map(\.character))) }
        let known = norms.isEmpty ? [:] : try await corpus.traditionalLines(for: norms)
        return TraditionalConversion.convert(text, converter: converter, known: known)
    }

    /// 新建粘入的圈点本：整理正文的空白与空行；正文没有汉字时报错。题目、作者、朝代可空。
    public func createMarkedPoem(title: String, author: String?, dynasty: String?, text: String,
                                 now: Date = Date()) throws -> MarkedPoem {
        let body = MarkedPoem.normalizedBody(text)
        guard !TextSegmenter.hanOnly(body).isEmpty else { throw LibraryError.emptyText }
        let clean = { (value: String?) -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        let poem = MarkedPoem(title: clean(title) ?? "", author: clean(author), dynasty: clean(dynasty), origin: .pasted,
                              body: body, createdAt: now, updatedAt: now)
        try library.save(poem)
        return poem
    }
}
