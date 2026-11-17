import Foundation
import Observation
import PoetryCore
import notify

enum SidebarItem: Hashable {
    case poem(UUID)
    case allPhrases
    case inbox
    case tag(String)
    case smart(UUID)
    case rhymeBook
    case packs
}

struct ImportStatus: Equatable {
    var title: String
    var phase: String
    var fraction: Double?
}

/// App 的状态与业务调用入口（主线程）。
@MainActor
@Observable
final class AppModel {
    let service: PoetryService
    var poems: [Poem] = []
    var phrases: [Phrase] = []
    var tags: [String] = []
    var tagUsage: [String: Int] = [:]
    var smartCollections: [SmartCollection] = []
    var packs: [PackInfo] = []
    var selection: SidebarItem?
    var importStatus: ImportStatus?
    var errorMessage: String?
    var notice: String?
    var agentWritesToInbox = true
    var mcpReadOnly = false
    var customReadings: [CustomReading] = []
    /// 随自定义读音更新；作为可观察属性，依赖它的视图会随之刷新。
    private(set) var dictionary: CharDictionary
    private(set) var analyzer: PoemAnalyzer

    @ObservationIgnored private var notifyToken: Int32 = NOTIFY_TOKEN_INVALID

    init(paths: AppPaths) throws {
        service = try PoetryService(paths: paths)
        dictionary = service.dictionary
        analyzer = service.analyzer
        reload()
        listenForExternalChanges()
    }

    var tunes: CiTuneLibrary { analyzer.tunes }
    var inboxCount: Int { phrases.filter { $0.status == .inbox }.count }

    // MARK: - 刷新

    func reload() {
        perform {
            poems = try service.library.poems()
            phrases = try service.library.phrases()
            tags = try service.library.tags()
            tagUsage = try service.library.tagUsage()
            smartCollections = try service.library.smartCollections()
            agentWritesToInbox = try service.library.bool(.agentWritesToInbox)
            mcpReadOnly = try service.library.bool(.mcpReadOnly)
            customReadings = try service.library.customReadings()
        }
    }

    /// shici-mcp 写入后会发送通知，收到后刷新。
    private func listenForExternalChanges() {
        let status = notify_register_dispatch(LibraryChangeNotification.name, &notifyToken, .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        if status != NOTIFY_STATUS_OK {
            errorMessage = "无法监听 MCP 写入通知（状态 \(status)），可在菜单中手动刷新"
        }
    }

    func perform(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    // MARK: - 作品

    @discardableResult
    func newPoem() -> Poem {
        let poem = Poem()
        perform {
            try service.library.save(poem)
            poems.insert(poem, at: 0)
        }
        selection = .poem(poem.id)
        return poem
    }

    func save(_ poem: Poem) {
        var updated = poem
        updated.updatedAt = Date()
        perform {
            try service.library.save(updated)
            if let index = poems.firstIndex(where: { $0.id == poem.id }) { poems[index] = updated }
        }
    }

    func deletePoem(_ id: UUID) {
        perform {
            try service.library.deletePoem(id: id)
            poems.removeAll { $0.id == id }
        }
        if selection == .poem(id) { selection = poems.first.map { .poem($0.id) } }
    }

    func poem(_ id: UUID) -> Poem? { poems.first { $0.id == id } }

    // MARK: - 自定义读音

    func addCustomReading(_ text: String, groupID: Int) {
        perform { try service.addCustomReading(text, groupID: groupID) }
        syncCustomReadings()
    }

    func removeCustomReading(_ reading: CustomReading) {
        perform { try service.removeCustomReading(reading) }
        syncCustomReadings()
    }

    private func syncCustomReadings() {
        perform { customReadings = try service.library.customReadings() }
        dictionary = service.dictionary
        analyzer = service.analyzer
    }

    // MARK: - 收藏

    func addPhrase(_ draft: PhraseDraft) async -> Bool {
        do {
            let result = try await service.addPhrase(draft, actor: .user)
            reload()
            if let match = result.corpusMatch {
                notice = result.phrase.provenance.kind == .original
                    ? "已收藏。注意：与\(match.summary)中的句子相同。"
                    : "已收藏，出处经语料核实：\(match.summary)"
            }
            return true
        } catch {
            errorMessage = String(describing: error)
            return false
        }
    }

    func save(_ phrase: Phrase) {
        var updated = phrase
        updated.updatedAt = Date()
        perform { try service.library.save(updated) }
        reload()
    }

    func deletePhrases(_ ids: Set<UUID>) {
        perform {
            for id in ids { try service.library.deletePhrase(id: id) }
        }
        reload()
    }

    func accept(_ ids: [UUID]) {
        perform { try service.library.setStatus(.accepted, for: ids) }
        reload()
    }

    // MARK: - 标签与智能收藏夹

    func renameTag(_ old: String, to new: String) {
        perform { try service.library.renameTag(old, to: new) }
        if case .tag(let current) = selection, current == old, let normalized = TagPath.normalize(new) {
            selection = .tag(normalized)
        }
        reload()
    }

    func deleteTag(_ path: String) {
        perform { try service.library.deleteTag(path) }
        if case .tag(let current) = selection, TagPath.lineage(of: current).contains(path) { selection = .allPhrases }
        reload()
    }

    func save(_ collection: SmartCollection) {
        perform { try service.library.save(collection) }
        reload()
    }

    func deleteSmartCollection(_ id: UUID) {
        perform { try service.library.deleteSmartCollection(id: id) }
        if selection == .smart(id) { selection = .allPhrases }
        reload()
    }

    func setSetting(_ key: SettingKey, _ value: Bool) {
        perform { try service.library.setBool(key, value) }
        reload()
    }

    // MARK: - 语料包

    func refreshPacks() async {
        do {
            packs = try await service.corpus.packs()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// 语料句所在作品的全文；出错时提示并返回 nil。
    func corpusWork(for line: CorpusLine) async -> CorpusWork? {
        do {
            return try await service.corpus.work(id: line.workID)
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// 启动时导入 Packs 目录中尚未导入的语料包。
    func importPendingPacks() async {
        do {
            for directory in try await service.pendingPackDirectories() {
                try await importPack(at: directory)
            }
        } catch {
            errorMessage = String(describing: error)
        }
        await refreshPacks()
    }

    func installPack(from url: URL) async {
        do {
            try await importPack(at: url)
        } catch {
            errorMessage = String(describing: error)
        }
        await refreshPacks()
    }

    private func importPack(at url: URL) async throws {
        let title = (try? PackManifest.load(from: url).name) ?? url.lastPathComponent
        importStatus = ImportStatus(title: title, phase: "准备", fraction: 0)
        defer { importStatus = nil }
        let report = try await service.installPack(from: url) { progress in
            Task { @MainActor [weak self] in
                self?.importStatus = ImportStatus(title: title, phase: progress.phase, fraction: progress.fraction)
            }
        }
        notice = "已导入「\(report.name)」：\(report.workCount) 篇、\(report.lineCount) 句"
            + (report.skippedRecords > 0 ? "，跳过 \(report.skippedRecords) 条无效记录" : "")
    }

    /// 下载 chinese-poetry 唐诗与宋词并导入。
    func downloadPublicCorpus() async {
        do {
            for source in CorpusSource.all {
                importStatus = ImportStatus(title: source.name, phase: "下载", fraction: nil)
                let directory = try await CorpusDownloader.download(source, into: service.paths.packs) { message in
                    Task { @MainActor [weak self] in
                        self?.importStatus = ImportStatus(title: source.name, phase: message, fraction: nil)
                    }
                }
                try await importPack(at: directory)
            }
        } catch {
            importStatus = nil
            errorMessage = String(describing: error)
        }
        await refreshPacks()
    }

    func setPackEnabled(_ enabled: Bool, id: String) async {
        do {
            try await service.corpus.setEnabled(enabled, packID: id)
        } catch {
            errorMessage = String(describing: error)
        }
        await refreshPacks()
    }

    func removePack(_ id: String) async {
        do {
            try await service.removePack(id: id)
        } catch {
            errorMessage = String(describing: error)
        }
        await refreshPacks()
    }
}
