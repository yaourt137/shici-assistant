import AppKit
import PoetryCore
import SwiftUI

/// 《艺文类聚》浏览：左侧按部列子目，右侧为该子目的「事」与各体「文」；可全文检索。
struct LeijuBrowserView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ClassicScript.storageKey) private var showSimplified = false
    @State private var topics: [LeijuTopic] = []
    @State private var selection: LeijuTopic.ID?
    @State private var entries: [LeijuEntry] = []
    @State private var query = ""
    @State private var results: [LeijuEntry] = []

    static let searchLimit = 200

    private struct Part: Identifiable {
        let id: String
        let name: String
        let topics: [LeijuTopic]
    }

    /// 按原书顺序分部；同名部在不同卷（如「山部上」「山部下」）各自成组。
    private var parts: [Part] {
        var result: [Part] = []
        for topic in topics {
            let id = "\(topic.juan)|\(topic.part)"
            if result.last?.id == id {
                let last = result.removeLast()
                result.append(Part(id: id, name: last.name, topics: last.topics + [topic]))
            } else {
                result.append(Part(id: id, name: "卷\(topic.juan) · \(topic.part)", topics: [topic]))
            }
        }
        return result
    }

    private func display(_ text: String) -> String {
        showSimplified ? model.dictionary.converter.simplified(text) : text
    }

    var body: some View {
        Group {
            if model.classicInfo(.yiwenLeiju) == nil {
                ContentUnavailableView {
                    Label("尚未下载艺文类聚", systemImage: "books.vertical")
                } description: {
                    Text(ClassicWork.yiwenLeiju.summary + "。文本来自漢リポ（Kanseki Repository），许可为 \(ClassicWork.license)。")
                } actions: {
                    Button("下载并导入") { Task { await model.downloadClassic(.yiwenLeiju) } }
                        .disabled(model.importStatus != nil)
                }
            } else {
                HSplitView {
                    List(selection: $selection) {
                        ForEach(parts) { part in
                            Section(display(part.name)) {
                                ForEach(part.topics) { topic in
                                    Text(display(topic.topic)).badge(topic.entryCount).tag(topic.id)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 280)
                    detail
                        .padding(16)
                        .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .searchable(text: $query, prompt: "全文检索（繁简不拘）")
            }
        }
        .navigationTitle("艺文类聚")
        .toolbar {
            Toggle("简体", isOn: $showSimplified)
        }
        .task(id: model.classicInfo(.yiwenLeiju)?.importedAt) { await loadTopics() }
        .task(id: selection) { await loadEntries() }
        .task(id: query) { await search() }
        .task { await model.refreshClassics() }
    }

    @ViewBuilder
    private var detail: some View {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(results.count >= LeijuBrowserView.searchLimit ? "检索「\(query)」：前 \(LeijuBrowserView.searchLimit) 条"
                     : "检索「\(query)」：\(results.count) 条")
                    .font(.headline)
                List(Array(results.enumerated()), id: \.offset) { _, entry in
                    LeijuEntryRow(entry: entry, display: display, showsLocation: true)
                }
                .listStyle(.inset)
            }
        } else if let topic = topics.first(where: { $0.id == selection }) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(display(topic.part)) · \(display(topic.topic))").font(.title2)
                List {
                    ForEach(groups, id: \.title) { group in
                        Section(display(group.title)) {
                            ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                                LeijuEntryRow(entry: entry, display: display, showsLocation: false)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        } else {
            ContentUnavailableView("选择一个子目", systemImage: "list.bullet.indent",
                                   description: Text("原书每个子目先列经史子书中的「事」，后列诗赋等「文」。"))
        }
    }

    private struct EntryGroup {
        let title: String
        let entries: [LeijuEntry]
    }

    /// 「事」在前，各体「文」按原书出现顺序。
    private var groups: [EntryGroup] {
        var order: [String] = []
        var byTitle: [String: [LeijuEntry]] = [:]
        for entry in entries {
            let title = entry.genre ?? "事"
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(entry)
        }
        return order.map { EntryGroup(title: $0, entries: byTitle[$0] ?? []) }
    }

    private func loadTopics() async {
        guard model.classicInfo(.yiwenLeiju) != nil else {
            topics = []
            return
        }
        do {
            topics = try await model.service.classics.leijuTopics()
            if selection == nil { selection = topics.first?.id }
        } catch {
            model.errorMessage = String(describing: error)
        }
    }

    private func loadEntries() async {
        guard let topic = topics.first(where: { $0.id == selection }) else {
            entries = []
            return
        }
        do {
            entries = try await model.service.classics.leijuEntries(in: topic)
        } catch {
            model.errorMessage = String(describing: error)
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        // 输入停顿后再检索；继续输入会取消本次任务，此时不检索。
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch is CancellationError {
            return
        } catch {
            model.errorMessage = String(describing: error)
            return
        }
        do {
            results = try await model.service.classics.searchLeiju(trimmed, limit: LeijuBrowserView.searchLimit)
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

struct LeijuEntryRow: View {
    let entry: LeijuEntry
    let display: (String) -> String
    let showsLocation: Bool

    var body: some View {
        let parts = entry.attributionAndBody
        VStack(alignment: .leading, spacing: 3) {
            if showsLocation {
                Text(display("\(entry.part) · \(entry.topic) · \(entry.genre ?? "事")")).font(.caption).foregroundStyle(.secondary)
            }
            if let attribution = parts.attribution {
                Text(display(attribution)).font(.callout.weight(.semibold))
            }
            Text(display(parts.body))
                .font(.system(size: 15, design: .serif))
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("拷贝全文") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(display(entry.text), forType: .string)
            }
        }
    }
}
