import PoetryCore
import SwiftUI

enum LibraryScope: Hashable {
    case all
    case inbox
    case tag(String)
    case smart(SmartCollection)

    var title: String {
        switch self {
        case .all: "全部收藏"
        case .inbox: "收件箱"
        case .tag(let path): "标签：\(path)"
        case .smart(let collection): collection.name
        }
    }
}

struct PhraseLibraryView: View {
    @Environment(AppModel.self) private var model
    let scope: LibraryScope

    @State private var searchText = ""
    @State private var filterText = ""
    @State private var selectedIDs = Set<UUID>()
    @State private var showingNew = false
    @State private var showDetail = true

    private var filterResult: (filter: PhraseFilter, error: String?) {
        do {
            return (try PhraseFilterParser.parse(filterText), nil)
        } catch {
            return (.all, error.message)
        }
    }

    private var visiblePhrases: [Phrase] {
        let scoped: [Phrase]
        switch scope {
        case .all:
            scoped = model.phrases.filter { $0.status == .accepted }
        case .inbox:
            scoped = model.phrases.filter { $0.status == .inbox }
        case .tag(let path):
            scoped = model.phrases.filter { PhraseFilter.tag(path).matches($0) }
        case .smart(let collection):
            let filter = (try? PhraseFilterParser.parse(collection.query)) ?? .all
            scoped = model.phrases.filter { $0.status == .accepted && filter.matches($0) }
        }
        let filtered = scoped.filter(filterResult.filter.matches)
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return filtered }
        let simplified = model.dictionary.converter.simplified(query)
        return filtered.filter { phrase in
            phrase.text.contains(query) || model.dictionary.converter.simplified(phrase.text).contains(simplified)
                || (phrase.note ?? "").contains(query) || (phrase.provenance.source?.summary ?? "").contains(query)
        }
    }

    private var selectedPhrase: Phrase? {
        guard selectedIDs.count == 1, let id = selectedIDs.first else { return nil }
        return model.phrases.first { $0.id == id }
    }

    var body: some View {
        let phrases = visiblePhrases
        VStack(spacing: 0) {
            HStack {
                TextField("筛选表达式（如 季节/秋 月|雁 -来源:agent）", text: $filterText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("filterField")
                Text("\(phrases.count) 条").foregroundStyle(.secondary).monospacedDigit()
                Button {
                    model.save(SmartCollection(name: filterText, query: filterText))
                } label: {
                    Label("存为智能收藏夹", systemImage: "folder.badge.gearshape")
                }
                .disabled(filterText.trimmingCharacters(in: .whitespaces).isEmpty || filterResult.error != nil)
            }
            .padding(10)
            if let error = filterResult.error {
                Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.bottom, 6)
            }
            Table(phrases, selection: $selectedIDs) {
                TableColumn("文本") { phrase in
                    Text(phrase.text).font(.system(.body, design: .serif))
                }
                .width(min: 140, ideal: 220)
                TableColumn("类型") { Text($0.kind.rawValue) }.width(36)
                TableColumn("平仄（平水）") { phrase in
                    Text(model.dictionary.tonePattern(of: phrase.text, in: .pingshui))
                        .font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                }
                .width(min: 80, ideal: 110)
                TableColumn("标签") { phrase in
                    Text(phrase.tagPaths.joined(separator: "  ")).foregroundStyle(.secondary).lineLimit(1)
                }
                TableColumn("来源") { phrase in
                    Text(sourceText(phrase)).foregroundStyle(.secondary).lineLimit(1)
                }
                .width(min: 80, ideal: 140)
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if scope == .inbox {
                    Button("接受") { model.accept(Array(ids)) }
                }
                Button("删除", role: .destructive) { model.deletePhrases(ids) }
            }
            .accessibilityIdentifier("phraseTable")
            .overlay {
                if phrases.isEmpty {
                    ContentUnavailableView(scope == .inbox ? "收件箱为空" : "没有收藏", systemImage: "tray",
                                           description: Text(scope == .inbox ? "agent 通过 MCP 写入的收藏会先放在这里。" : "在编辑器中选字后点「收藏所选」，或点工具栏的 +。"))
                }
            }
        }
        .navigationTitle(scope.title)
        .searchable(text: $searchText, prompt: "搜索文本、出处、备注")
        .toolbar {
            ToolbarItemGroup {
                if scope == .inbox {
                    Button("全部接受") { model.accept(phrases.map(\.id)) }
                        .disabled(phrases.isEmpty)
                }
                Button {
                    showingNew = true
                } label: {
                    Label("新建收藏", systemImage: "plus")
                }
                .accessibilityIdentifier("newPhraseButton")
                Button {
                    model.deletePhrases(selectedIDs)
                    selectedIDs = []
                } label: {
                    Label("删除", systemImage: "trash")
                }
                .disabled(selectedIDs.isEmpty)
                Button {
                    showDetail.toggle()
                } label: {
                    Label("详情", systemImage: "sidebar.right")
                }
            }
        }
        .inspector(isPresented: $showDetail) {
            Group {
                if let phrase = selectedPhrase {
                    PhraseDetailView(phrase: phrase)
                        .id(phrase.id)
                } else {
                    ContentUnavailableView("选择一条收藏", systemImage: "text.quote")
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
        }
        .sheet(isPresented: $showingNew) {
            PhraseEditorSheet(initialText: "", initialKind: .original, draftID: nil, initialTags: initialTags)
        }
    }

    private var initialTags: [String] {
        if case .tag(let path) = scope { return [path] }
        return []
    }

    private func sourceText(_ phrase: Phrase) -> String {
        switch phrase.provenance.kind {
        case .original:
            return "自撰"
        case .excerpt:
            let summary = phrase.provenance.source?.summary ?? ""
            return summary.isEmpty ? "摘录" : summary + (phrase.provenance.source?.isVerified == true ? " ✓" : "")
        case .agent:
            let client = phrase.provenance.agentClient ?? "agent"
            if let source = phrase.provenance.source, source.isVerified { return "\(client) · \(source.summary) ✓" }
            return client
        }
    }
}

// MARK: - 详情

struct PhraseDetailView: View {
    @Environment(AppModel.self) private var model
    @State var phrase: Phrase
    @State private var viewingWork: CorpusWork?

    var body: some View {
        Form {
            Section("文本") {
                TextField("文本", text: $phrase.text, axis: .vertical)
                    .font(.system(.title3, design: .serif))
                Picker("类型", selection: $phrase.kind) {
                    ForEach(PhraseKind.allCases) { Text($0.rawValue).tag($0) }
                }
                ForEach(RhymeBook.allCases) { book in
                    LabeledContent(book.displayName, value: model.dictionary.tonePattern(of: phrase.text, in: book))
                        .font(.system(.body, design: .monospaced))
                }
            }
            Section("标签") {
                TagEditor(paths: Binding(
                    get: { phrase.tagPaths },
                    set: { paths in
                        phrase.tags = paths.map { path in
                            phrase.tags.first { $0.path == path } ?? TagAssignment(path: path, addedBy: .user)
                        }
                    }))
            }
            Section("来源") {
                Picker("类型", selection: $phrase.provenance.kind) {
                    ForEach(ProvenanceKind.allCases) { Text($0.rawValue).tag($0) }
                }
                if phrase.provenance.kind != .original {
                    SourceFields(source: Binding(get: { phrase.provenance.source ?? SourceInfo() },
                                                 set: { phrase.provenance.source = $0.isEmpty ? nil : $0 }))
                    if phrase.provenance.source?.isVerified == true {
                        Label("出处经语料核实", systemImage: "checkmark.seal").foregroundStyle(.green)
                    }
                }
                ForEach(phrase.provenance.corpusLinks ?? [], id: \.self) { link in
                    LabeledContent("原诗") {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(link.summary)
                                if let excerpt = link.excerpt {
                                    Text(excerpt).font(.system(.callout, design: .serif)).foregroundStyle(.secondary)
                                }
                            }
                            Button("查看原诗") { Task { viewingWork = await model.corpusWork(link: link) } }
                                .controlSize(.small)
                        }
                    }
                }
                if phrase.provenance.kind == .agent {
                    LabeledContent("客户端", value: phrase.provenance.agentClient ?? "未知")
                    if let note = phrase.provenance.agentNote { LabeledContent("写入理由", value: note) }
                    if let claimed = phrase.provenance.claimedSource, !claimed.isEmpty {
                        LabeledContent("声称出处（未核实）", value: claimed.summary.isEmpty ? (claimed.url ?? "") : claimed.summary)
                    }
                }
            }
            Section("备注") {
                TextField("备注", text: Binding(get: { phrase.note ?? "" }, set: { phrase.note = $0.isEmpty ? nil : $0 }), axis: .vertical)
            }
            Section {
                HStack {
                    if phrase.status == .inbox {
                        Button("接受") {
                            phrase.status = .accepted
                            model.save(phrase)
                        }
                    }
                    Spacer()
                    Button("保存") { model.save(phrase) }
                        .keyboardShortcut("s")
                        .accessibilityIdentifier("savePhrase")
                }
            }
            Section("相关诗句") {
                RelatedPanel(phrase: phrase.hanText, line: phrase.hanText)
                    .frame(minHeight: 260)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $viewingWork) { CorpusWorkView(work: $0) }
    }
}

struct SourceFields: View {
    @Binding var source: SourceInfo

    var body: some View {
        TextField("作者", text: optional(\.author))
        TextField("篇名", text: optional(\.title))
        TextField("朝代", text: optional(\.dynasty))
        TextField("网址", text: optional(\.url))
    }

    private func optional(_ keyPath: WritableKeyPath<SourceInfo, String?>) -> Binding<String> {
        Binding(get: { source[keyPath: keyPath] ?? "" }, set: { value in
            source[keyPath: keyPath] = value.isEmpty ? nil : value
            source.isVerified = false
        })
    }
}

// MARK: - 标签编辑

struct TagEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var paths: [String]
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !paths.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(paths, id: \.self) { path in
                        HStack(spacing: 4) {
                            Text(path)
                            Button {
                                paths.removeAll { $0 == path }
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除标签 \(path)")
                        }
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    }
                }
            }
            HStack {
                TextField("添加标签（回车确认，可用 / 分级）", text: $input)
                    .onSubmit(add)
                    .accessibilityIdentifier("tagInput")
                Menu("已有") {
                    ForEach(model.tags.filter { !paths.contains($0) }, id: \.self) { path in
                        Button(path) { paths.append(path) }
                    }
                }
                .fixedSize()
                .disabled(model.tags.isEmpty)
            }
        }
    }

    private func add() {
        for raw in input.split(whereSeparator: { $0 == "," || $0 == "，" || $0 == "、" }) {
            if let path = TagPath.normalize(String(raw)), !paths.contains(path) { paths.append(path) }
        }
        input = ""
    }
}

/// 简单的自动换行布局。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 新建收藏

struct PhraseEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var kind: PhraseKind?
    @State private var provenanceKind: ProvenanceKind
    @State private var source: SourceInfo
    @State private var tags: [String]
    @State private var note = ""
    @State private var isSaving = false
    private let draftID: UUID?

    init(initialText: String, initialKind: ProvenanceKind, draftID: UUID?, initialTags: [String] = [],
         initialSource: SourceInfo = SourceInfo()) {
        _text = State(initialValue: initialText)
        _provenanceKind = State(initialValue: initialKind)
        _source = State(initialValue: initialSource)
        _tags = State(initialValue: initialTags)
        self.draftID = draftID
    }

    var body: some View {
        Form {
            TextField("文本", text: $text, axis: .vertical)
                .font(.system(.title3, design: .serif))
                .accessibilityIdentifier("phraseText")
            Picker("类型", selection: $kind) {
                Text("自动（\(PhraseKind.infer(from: text)?.rawValue ?? "—")）").tag(PhraseKind?.none)
                ForEach(PhraseKind.allCases) { Text($0.rawValue).tag(PhraseKind?.some($0)) }
            }
            Picker("来源", selection: $provenanceKind) {
                Text(ProvenanceKind.original.rawValue).tag(ProvenanceKind.original)
                Text(ProvenanceKind.excerpt.rawValue).tag(ProvenanceKind.excerpt)
            }
            .pickerStyle(.segmented)
            if provenanceKind == .excerpt {
                SourceFields(source: $source)
                Text("保存时会在语料中反查；整句命中时自动填入并标记为已核实。").font(.caption).foregroundStyle(.secondary)
            }
            Section("标签") { TagEditor(paths: $tags) }
            TextField("备注", text: $note, axis: .vertical)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("收藏") {
                    isSaving = true
                    Task {
                        let provenance = Provenance(kind: provenanceKind, source: source.isEmpty ? nil : source,
                                                    draftID: provenanceKind == .original ? draftID : nil)
                        let saved = await model.addPhrase(PhraseDraft(text: text, kind: kind, provenance: provenance,
                                                                      tags: tags, note: note))
                        isSaving = false
                        if saved { dismiss() }
                    }
                }
                .disabled(PhraseKind.infer(from: text) == nil || isSaving)
                .accessibilityIdentifier("savePhraseSheet")
            }
        }
    }
}
