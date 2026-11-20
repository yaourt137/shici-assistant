import PoetryCore
import SwiftUI

struct EditorInspector: View {
    @Environment(AppModel.self) private var model
    let analysis: PoemAnalysis
    let selection: GridSelection?
    let poemID: UUID
    let onReplace: (String) -> Void
    let onCollect: (String) -> Void
    let onChooseReading: (AnalyzedChar, Reading?) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case candidates = "候选"
        case related = "相关诗句"
        case classics = "典籍"
        case character = "字音"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .candidates

    private var selectedCharacters: [AnalyzedChar] {
        guard let selection, analysis.lines.indices.contains(selection.line) else { return [] }
        let characters = analysis.lines[selection.line].characters
        guard selection.range.upperBound < characters.count else { return [] }
        return Array(characters[selection.range])
    }

    private var selectedText: String { String(selectedCharacters.map(\.character)) }

    private var lineText: String? {
        guard let selection, analysis.lines.indices.contains(selection.line) else { return nil }
        return analysis.lines[selection.line].text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if selectedCharacters.isEmpty {
                ContentUnavailableView("未选中", systemImage: "hand.tap",
                                       description: Text("在格律网格中点选一个字，按住 Shift 再点扩选；点句首序号选整句。"))
                    .frame(maxHeight: .infinity)
            } else {
                HStack {
                    Text("「\(selectedText)」").font(.system(.title3, design: .serif))
                    Spacer()
                    Button("收藏所选…") { onCollect(selectedText) }
                        .accessibilityIdentifier("collectSelection")
                }
                switch tab {
                case .candidates:
                    CandidatesPanel(constraint: selection.flatMap { analysis.constraint(line: $0.line, range: $0.range) },
                                    currentText: selectedText, onReplace: onReplace)
                case .related:
                    RelatedPanel(phrase: selectedText, line: lineText ?? selectedText)
                case .classics:
                    ClassicsPanel(constraint: selection.flatMap { analysis.constraint(line: $0.line, range: $0.range) },
                                  currentText: selectedText, onReplace: onReplace)
                case .character:
                    CharacterPanel(characters: selectedCharacters, book: analysis.book, onChooseReading: onChooseReading)
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 候选

struct CandidatesPanel: View {
    @Environment(AppModel.self) private var model
    let constraint: SlotConstraint?
    let currentText: String
    let onReplace: (String) -> Void

    @State private var includeCollection = true
    @State private var includeCorpus = true
    @State private var filterText = ""
    @State private var candidates: [Candidate] = []
    @State private var isLoading = false
    @State private var filterError: String?
    @State private var usagesRequest: UsagesRequest?

    private struct LoadKey: Hashable {
        let constraint: SlotConstraint?
        let includeCollection: Bool
        let includeCorpus: Bool
        let filter: String
        let current: String
        let revision: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let constraint {
                Text(describe(constraint))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("constraintDescription")
            }
            HStack {
                Toggle("收藏", isOn: $includeCollection)
                Toggle("语料", isOn: $includeCorpus)
            }
            .toggleStyle(.checkbox)
            TextField("按标签筛选收藏（如 秋 月|雁）", text: $filterText)
                .textFieldStyle(.roundedBorder)
            if let filterError {
                Text(filterError).font(.caption).foregroundStyle(.red)
            }
            if includeCorpus, model.packs.isEmpty {
                HStack {
                    Text("尚未导入语料，候选只来自收藏。").font(.caption).foregroundStyle(.secondary)
                    Button("前往语料包") { model.selection = .packs }.controlSize(.small)
                }
            }
            if isLoading {
                ProgressView().controlSize(.small)
            }
            List(candidates) { candidate in
                CandidateRow(candidate: candidate, onReplace: { onReplace(candidate.text) },
                             onShowUsages: { usagesRequest = UsagesRequest(phrase: candidate.text) })
            }
            .listStyle(.inset)
            .overlay {
                if !isLoading, candidates.isEmpty {
                    Text(constraint == nil ? "无法生成约束" : "没有符合的候选").foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("candidateList")
        }
        .task(id: LoadKey(constraint: constraint, includeCollection: includeCollection, includeCorpus: includeCorpus,
                          filter: filterText, current: currentText, revision: model.phrases.count)) {
            await load()
        }
        .sheet(item: $usagesRequest) { request in
            UsagesSheet(phrase: request.phrase)
        }
    }

    private func describe(_ constraint: SlotConstraint) -> String {
        var text = "位置要求：\(constraint.patternText)"
        if let rhyme = constraint.rhyme {
            text += " · 押\(model.dictionary.displayName(of: rhyme.key))（\(rhyme.tone.rawValue)）"
        }
        return text
    }

    private func load() async {
        guard let constraint else {
            candidates = []
            return
        }
        let filter: PhraseFilter
        do {
            filter = try PhraseFilterParser.parse(filterText)
            filterError = nil
        } catch {
            filterError = error.message
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let options = CandidateOptions(includeCollection: includeCollection, includeCorpus: includeCorpus,
                                           filter: filter, limit: 80, excluding: currentText)
            let result = try await model.service.candidates(for: constraint, options: options)
            guard !Task.isCancelled else { return }
            candidates = result
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

private struct UsagesRequest: Identifiable {
    let phrase: String
    var id: String { phrase }
}

struct CandidateRow: View {
    let candidate: Candidate
    let onReplace: () -> Void
    let onShowUsages: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(candidate.text).font(.system(size: 17, design: .serif))
            switch candidate.source {
            case .collection:
                Text("收藏").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                if !candidate.tags.isEmpty {
                    Text(candidate.tags.joined(separator: " ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            case .corpus:
                Text("语料 \(candidate.frequency)").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onShowUsages) {
                Image(systemName: "text.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("查看前人用例")
            .accessibilityLabel("查看前人用例")
            Button("替换", action: onReplace)
                .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onReplace)
        .contextMenu {
            Button("替换", action: onReplace)
            Button("查看前人用例…", action: onShowUsages)
        }
    }
}

// MARK: - 相关诗句（不用 AI）

struct RelatedPanel: View {
    @Environment(AppModel.self) private var model
    let phrase: String
    let line: String

    @State private var usages: [CorpusLine] = []
    @State private var related: [CorpusLine] = []
    @State private var collectionMatches: [Phrase] = []
    @State private var viewingWork: CorpusWork?

    private struct LoadKey: Hashable {
        let phrase: String
        let line: String
        let packs: Int
    }

    var body: some View {
        List {
            if !collectionMatches.isEmpty {
                Section("收藏中含「\(phrase)」") {
                    ForEach(collectionMatches) { item in
                        VStack(alignment: .leading) {
                            Text(item.text).font(.system(.body, design: .serif))
                            if !item.tags.isEmpty {
                                Text(item.tagPaths.joined(separator: " ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("前人用例：含「\(phrase)」") {
                if usages.isEmpty { Text("语料中未见").foregroundStyle(.secondary) }
                ForEach(usages) { CorpusLineRow(item: $0, onOpen: open) }
            }
            Section("相关诗句：与「\(line)」字词相近") {
                if related.isEmpty { Text("语料中未见").foregroundStyle(.secondary) }
                ForEach(related) { CorpusLineRow(item: $0, onOpen: open) }
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("relatedList")
        .task(id: LoadKey(phrase: phrase, line: line, packs: model.packs.count)) { await load() }
        .sheet(item: $viewingWork) { work in
            CorpusWorkView(work: work)
        }
    }

    private func open(_ item: CorpusLine) async {
        viewingWork = await model.corpusWork(for: item)
    }

    private func load() async {
        let simplified = model.dictionary.converter.simplified(phrase)
        collectionMatches = model.phrases.filter { model.dictionary.converter.simplified($0.hanText).contains(simplified) }
        do {
            let corpus = model.service.corpus
            async let usageRows = corpus.usages(of: phrase, limit: 40)
            async let relatedRows = corpus.related(to: line, limit: 40)
            let (first, second) = try await (usageRows, relatedRows)
            guard !Task.isCancelled else { return }
            usages = first
            related = second
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

/// 语料中的一句：双击或右键「查看全文」，右键可收藏。
struct CorpusLineRow: View {
    @Environment(AppModel.self) private var model
    let item: CorpusLine
    let onOpen: (CorpusLine) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.text).font(.system(.body, design: .serif))
            Text(item.sourceSummary).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await onOpen(item) } }
        .contextMenu {
            Button("查看全文") { Task { await onOpen(item) } }
            Button("收藏此句（摘录）") {
                Task {
                    _ = await model.addPhrase(PhraseDraft(text: item.text, provenance: Provenance(kind: .excerpt)))
                }
            }
        }
    }
}

/// 候选的前人用例：语料中含该词句的句子。
struct UsagesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let phrase: String

    static let limit = 200

    @State private var usages: [CorpusLine] = []
    @State private var isLoading = true
    @State private var viewingWork: CorpusWork?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("「\(phrase)」的前人用例").font(.system(.title3, design: .serif))
                if !isLoading {
                    Text(usages.count >= UsagesSheet.limit ? "前 \(UsagesSheet.limit) 句" : "\(usages.count) 句")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            List(usages) { CorpusLineRow(item: $0, onOpen: open) }
                .listStyle(.inset)
                .overlay {
                    if isLoading {
                        ProgressView()
                    } else if usages.isEmpty {
                        Text(model.packs.isEmpty ? "尚未导入语料" : "语料中未见").foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("usagesList")
            HStack {
                Text("双击查看全文，右键可收藏").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 520)
        .task { await load() }
        .sheet(item: $viewingWork) { work in
            CorpusWorkView(work: work)
        }
    }

    private func open(_ item: CorpusLine) async {
        viewingWork = await model.corpusWork(for: item)
    }

    private func load() async {
        defer { isLoading = false }
        do {
            usages = try await model.service.corpus.usages(of: phrase, limit: UsagesSheet.limit)
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

struct CorpusWorkView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let work: CorpusWork

    @AppStorage("corpusShowTones") private var showTones = false
    @AppStorage("corpusShowRhymes") private var showRhymes = false
    @AppStorage("corpusRhymeBook") private var book: RhymeBook = .pingshui
    @State private var versions: [CorpusWorkVersion] = []
    @State private var viewingVersion: CorpusWork?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(work.title ?? "无题").font(.system(.title2, design: .serif))
            Text(SourceInfo(author: work.author, dynasty: work.dynasty).summary + " · " + work.packName)
                .foregroundStyle(.secondary)
            ForEach(versions) { version in
                HStack(spacing: 6) {
                    Text(version.isPrimary ? "保留版本" : "其他版本").font(.caption).foregroundStyle(.secondary)
                    Text(version.packName + " · " + SourceInfo(author: version.author, title: version.title,
                                                               dynasty: version.dynasty).summary)
                        .font(.caption)
                    if version.author != work.author, let author = version.author {
                        Text("（又作\(author)）").font(.caption).foregroundStyle(.orange)
                    }
                    Button("查看") { Task { await open(version) } }.controlSize(.mini)
                }
            }
            if let preface = work.preface {
                Text(preface).font(.callout).foregroundStyle(.secondary)
            }
            ScrollView {
                if showTones || showRhymes {
                    AnnotatedTextView(lines: TextAnnotator.annotate(work.body, book: book, dictionary: model.dictionary),
                                      showTones: showTones, showRhymes: showRhymes)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(work.body)
                        .font(.system(size: 17, design: .serif))
                        .lineSpacing(6)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                Toggle("平仄", isOn: $showTones)
                    .accessibilityIdentifier("corpusShowTones")
                Toggle("韵部", isOn: $showRhymes)
                    .accessibilityIdentifier("corpusShowRhymes")
                Picker("韵书", selection: $book) {
                    ForEach(RhymeBook.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!showTones && !showRhymes)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .toggleStyle(.checkbox)
        }
        .padding(20)
        .frame(width: 560, height: 520)
        .task(id: work.id) {
            do {
                versions = try await model.service.corpus.versions(of: work.id)
            } catch {
                model.errorMessage = String(describing: error)
            }
        }
        .sheet(item: $viewingVersion) { CorpusWorkView(work: $0) }
    }

    private func open(_ version: CorpusWorkVersion) async {
        do {
            viewingVersion = try await model.service.corpus.work(id: version.id)
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

/// 逐字标注的全文：汉字下标平仄，分句末字后标韵部；标点与换行照原文，过长自动折行。
struct AnnotatedTextView: View {
    let lines: [[AnnotatedCharacter]]
    let showTones: Bool
    let showRhymes: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.isEmpty {
                    Spacer().frame(height: 8)
                } else {
                    FlowLayout(spacing: 0) {
                        ForEach(Array(line.enumerated()), id: \.offset) { _, item in
                            cell(item)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: AnnotatedCharacter) -> some View {
        HStack(alignment: .top, spacing: 2) {
            VStack(spacing: 0) {
                Text(String(item.character))
                    .font(.system(size: 17, design: .serif))
                if showTones, item.isHan {
                    Text(item.tones.label)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(toneColor(item.tones))
                }
            }
            .frame(minWidth: item.isHan ? 22 : nil)
            if showRhymes, let labels = item.rhymeLabels {
                Text(labels.isEmpty ? "未收录" : labels.joined(separator: "／"))
                    .font(.system(size: 9))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                    .padding(.top, 4)
            }
        }
        // FlowLayout 横纵间距共用一个值（此处为 0），折行后的行距由这里撑开。
        .padding(.bottom, 6)
    }

    private func toneColor(_ tones: Set<Tone>) -> Color {
        switch tones.count {
        case 1: tones.contains(.ping) ? .secondary : .primary
        case 0: .gray
        default: .blue
        }
    }
}

// MARK: - 字音

struct CharacterPanel: View {
    @Environment(AppModel.self) private var model
    let characters: [AnalyzedChar]
    /// 当前作品所用韵书，指定读音只在此韵书下生效。
    let book: RhymeBook
    let onChooseReading: (AnalyzedChar, Reading?) -> Void

    var body: some View {
        List {
            ForEach(Array(characters.enumerated()), id: \.offset) { _, analyzed in
                let character = analyzed.character
                Section(String("「\(character)」 \(model.dictionary.syllables(of: character).map(\.plain).joined(separator: "、"))")) {
                    ReadingPicker(character: analyzed, book: book, onChoose: onChooseReading)
                    ForEach(RhymeBook.allCases) { book in
                        let readings = model.dictionary.readings(of: character, in: book)
                        HStack(alignment: .firstTextBaseline) {
                            Text(book.displayName).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            Text(readings.isEmpty ? "未收录"
                                 : readings.map { "\($0.tone.rawValue)·\(model.dictionary.displayName(of: $0.rhyme))" }.joined(separator: "　"))
                                .textSelection(.enabled)
                        }
                    }
                    CustomReadingRows(character: character)
                    YunfuGlossRows(character: character)
                    HStack {
                        SouYunButtons(character: character)
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .listStyle(.inset)
    }
}

/// 为多音字在当前韵书下指定读音（声调 + 韵部）；只有一种读音或未收录的字不显示。
struct ReadingPicker: View {
    @Environment(AppModel.self) private var model
    let character: AnalyzedChar
    let book: RhymeBook
    let onChoose: (AnalyzedChar, Reading?) -> Void

    var body: some View {
        let readings = model.dictionary.readings(of: character.character, in: book)
        if readings.count > 1 {
            Picker("指定读音（\(book.displayName)）", selection: Binding(
                get: { character.chosenReading },
                set: { onChoose(character, $0) })) {
                Text("自动").tag(Reading?.none)
                ForEach(readings, id: \.self) { reading in
                    Text(title(of: reading)).tag(Optional(reading))
                }
            }
            .accessibilityIdentifier("readingPicker")
        }
    }

    /// 平水韵韵目不含「平／仄」字样，前面补上；其余韵书的简称已含平仄。
    private func title(of reading: Reading) -> String {
        let label = model.dictionary.label(of: reading)
        return reading.rhyme.book == .pingshui ? "\(reading.tone.rawValue)·\(label)" : label
    }
}
