import AppKit
import PoetryCore
import SwiftUI

/// 对仗训练：对词、对句随机出题并记录；自由对自己出题、不记录；记录页查看与删除练习记录。
struct DrillView: View {
    @Environment(AppModel.self) private var model
    @State private var tab: Tab = .word
    @State private var pool: DrillPool?

    enum Tab: String, CaseIterable, Identifiable {
        case word = "对词"
        case line = "对句"
        case free = "自由对"
        case records = "记录"

        var id: String { rawValue }
    }

    /// 语料包或佩文韵府变动时重新准备题库。
    private var sourceKey: String {
        let packs = model.packs.map { "\($0.id)\($0.isEnabled)\($0.importedAt.timeIntervalSince1970)" }.joined(separator: ",")
        return packs + "|\(model.classicInfo(.peiwenYunfu)?.importedAt.timeIntervalSince1970 ?? 0)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(16)
            .accessibilityIdentifier("drillTab")
            Divider()
            if let pool {
                switch tab {
                case .word: DrillPracticeView(mode: .word, pool: pool).id(Tab.word)
                case .line: DrillPracticeView(mode: .line, pool: pool).id(Tab.line)
                case .free: FreeCoupletView()
                case .records: DrillRecordsView()
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text("正在准备题库…").foregroundStyle(.secondary)
                    Text("首次使用或语料变动后，需统计语料中律诗的对仗联；语料较多时可能需要一两分钟。").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("对仗训练（Beta）")
        .task(id: sourceKey) { await prepare() }
    }

    private func prepare() async {
        do {
            pool = try await model.service.prepareDrill()
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

/// 汉字个数。
private func hanCount(_ text: String) -> Int {
    TextSegmenter.hanOnly(text).count
}

// MARK: - 出题练习

struct DrillPracticeView: View {
    @Environment(AppModel.self) private var model
    let mode: DrillMode
    let pool: DrillPool

    @AppStorage(ClassicScript.storageKey) private var showSimplified = false
    @State private var sources: Set<DrillSourceKind> = Set(DrillSourceKind.allCases)
    @State private var length: DrillLength = .any
    @State private var history: DrillHistoryFilter = .all
    @State private var question: DrillQuestion?
    @State private var previous: [DrillAttempt] = []
    @State private var answer = ""
    @State private var result: CoupletResult?
    @State private var isExhausted = false
    @State private var isSubmitting = false
    @FocusState private var answerFocused: Bool

    private var options: DrillOptions {
        DrillOptions(mode: mode, sources: sources, length: length, history: history)
    }

    private var lengthChoices: [(String, DrillLength)] {
        switch mode {
        case .word: [("全部", .any), ("一字", .exactly(1)), ("二字", .exactly(2)), ("三字", .exactly(3)), ("四字", .exactly(4))]
        case .line: [("全部", .any), ("五言", .exactly(5)), ("七言", .exactly(7)), ("长对", .long)]
        }
    }

    private func display(_ text: String) -> String {
        showSimplified ? model.dictionary.converter.simplified(text) : text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                optionsBar
                if isExhausted {
                    ContentUnavailableView("没有符合条件的题", systemImage: "checkmark.circle",
                                           description: Text(history == .unanswered ? "这些题都练过了。可改选来源、字数，或把范围改为「全部」。"
                                                             : "请改选来源、字数或范围。"))
                } else if let question {
                    questionCard(question)
                    if let result {
                        CoupletResultView(result: result, display: display)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await next() }
        .onChange(of: options) { Task { await next() } }
    }

    private var optionsBar: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(DrillSourceKind.allCases) { kind in
                    let count = pool.count(of: kind, mode: mode)
                    Toggle(isOn: Binding(get: { sources.contains(kind) },
                                         set: { if $0 { sources.insert(kind) } else { sources.remove(kind) } })) {
                        Text(count > 0 ? "\(kind.displayName)（\(count) 组）"
                             : "\(kind.displayName)（\(kind == .yunfu ? "未下载" : kind == .corpus ? "未导入语料" : "无")）")
                    }
                    .disabled(count == 0)
                }
            } label: {
                Text("来源：" + (sources.count == DrillSourceKind.allCases.count ? "全部"
                                 : DrillSourceKind.allCases.filter(sources.contains).map(\.displayName).joined(separator: "、")))
            }
            .fixedSize()
            Picker("字数", selection: $length) {
                ForEach(lengthChoices, id: \.0) { Text($0.0).tag($0.1) }
            }
            .fixedSize()
            Picker("范围", selection: $history) {
                ForEach(DrillHistoryFilter.allCases) { Text($0.displayName).tag($0) }
            }
            .fixedSize()
            Toggle("简体", isOn: $showSimplified).toggleStyle(.checkbox)
            Spacer()
            Button("换一题") { Task { await next() } }
                .accessibilityIdentifier("drillNext")
        }
    }

    private func questionCard(_ question: DrillQuestion) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(mode == .word ? "出词" : "出句").font(.caption).foregroundStyle(.secondary)
                if let last = previous.first {
                    Text("已练 \(previous.count) 次 · 上次：\(last.level.displayName) · \(last.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .accessibilityIdentifier("drillPreviousBadge")
                }
            }
            Text(display(question.prompt))
                .font(.system(size: mode == .word ? 40 : 30, design: .serif))
                .textSelection(.enabled)
                .accessibilityIdentifier("drillPrompt")
            HStack(spacing: 10) {
                TextField(mode == .word ? "对词" : "对句", text: $answer)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 20, design: .serif))
                    .frame(maxWidth: 460)
                    .focused($answerFocused)
                    .disabled(result != nil)
                    .onSubmit { Task { await submit() } }
                    .accessibilityIdentifier("drillAnswer")
                Text("\(hanCount(answer))/\(hanCount(question.prompt)) 字").monospacedDigit().foregroundStyle(.secondary)
                if result == nil {
                    Button("提交") { Task { await submit() } }
                        .disabled(hanCount(answer) == 0 || isSubmitting)
                        .accessibilityIdentifier("drillSubmit")
                } else {
                    Button("下一题") { Task { await next() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func next() async {
        result = nil
        answer = ""
        do {
            question = try await model.service.drawDrillQuestion(options)
            isExhausted = question == nil
            previous = try question.map { try model.service.library.drillAttempts(questionKey: $0.key) } ?? []
            answerFocused = true
        } catch {
            model.errorMessage = String(describing: error)
        }
    }

    private func submit() async {
        guard let question, result == nil, !isSubmitting, hanCount(answer) > 0 else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            let service = model.service
            let evaluation = try await service.evaluateCouplet(prompt: question.prompt, answer: answer)
            let origin = try await service.describe(question.source)
            let converter = model.dictionary.converter
            let ownReference = converter.simplified(TextSegmenter.hanOnly(question.reference))
            var references: [CoupletResult.Reference] = []
            for reference in evaluation.references.prefix(12)
            where converter.simplified(TextSegmenter.hanOnly(reference.counterpart)) != ownReference {
                references.append(.init(text: reference.counterpart, source: try await service.describe(reference.source)))
            }
            try await service.recordDrill(question, answer: answer, level: evaluation.score.level)
            var workID: Int64?
            if case .corpus(let id, _) = question.source { workID = id }
            result = CoupletResult(prompt: question.prompt, answer: answer, score: evaluation.score,
                                   commonCounterparts: evaluation.commonCounterparts,
                                   original: .init(text: question.reference, source: origin), originalWorkID: workID,
                                   references: references, previous: previous)
        } catch let error as CoupletScoreError {
            model.errorMessage = error.description
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

// MARK: - 自由对

/// 自己出题、自己对，只评分，不记入练习记录。
struct FreeCoupletView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(ClassicScript.storageKey) private var showSimplified = false
    @State private var prompt = ""
    @State private var answer = ""
    @State private var result: CoupletResult?

    private func display(_ text: String) -> String {
        showSimplified ? model.dictionary.converter.simplified(text) : text
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("自己出题、自己对，给出评分与参考；不记入练习记录。只填出词时，参考中会列出典籍里的对与律诗常对。")
                    .font(.callout).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        Text("出").foregroundStyle(.secondary)
                        TextField("出词或出句", text: $prompt)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 20, design: .serif))
                            .frame(maxWidth: 460)
                            .accessibilityIdentifier("freePrompt")
                    }
                    GridRow {
                        Text("对").foregroundStyle(.secondary)
                        TextField("对词或对句（可空）", text: $answer)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 20, design: .serif))
                            .frame(maxWidth: 460)
                            .onSubmit { Task { await evaluate() } }
                            .accessibilityIdentifier("freeAnswer")
                    }
                }
                HStack {
                    Button("评分") { Task { await evaluate() } }
                        .disabled(hanCount(prompt) == 0)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("freeEvaluate")
                    Toggle("简体", isOn: $showSimplified).toggleStyle(.checkbox)
                }
                if let result {
                    CoupletResultView(result: result, display: display)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: prompt) { result = nil }
    }

    /// 对句为空时只查参考。
    private func evaluate() async {
        guard hanCount(prompt) > 0 else { return }
        do {
            let service = model.service
            let lookup = try await service.coupletReferences(for: prompt)
            let score = hanCount(answer) > 0 ? try await service.evaluateCouplet(prompt: prompt, answer: answer).score : nil
            var references: [CoupletResult.Reference] = []
            for reference in lookup.references.prefix(20) {
                references.append(.init(text: reference.counterpart, source: try await service.describe(reference.source)))
            }
            result = CoupletResult(prompt: prompt, answer: score == nil ? nil : answer, score: score,
                                   commonCounterparts: lookup.commonCounterparts,
                                   original: nil, originalWorkID: nil, references: references, previous: [])
        } catch let error as CoupletScoreError {
            model.errorMessage = error.description
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

// MARK: - 评分结果

/// 评分结果与参考，供练习与自由对共用。
struct CoupletResult {
    struct Reference: Hashable {
        let text: String
        let source: String
    }

    let prompt: String
    /// 与 `score` 同时为 nil 时只显示参考（自由对未填对句）。
    let answer: String?
    let score: CoupletScore?
    let commonCounterparts: [ParallelCounterpart]
    /// 原书或原诗的另一边。
    let original: Reference?
    let originalWorkID: Int64?
    let references: [Reference]
    /// 此题以往的作答（不含本次），新的在前。
    let previous: [DrillAttempt]
}

struct CoupletResultView: View {
    @Environment(AppModel.self) private var model
    let result: CoupletResult
    let display: (String) -> String

    @State private var viewingWork: CorpusWork?


    static func color(_ level: CoupletScore.Level) -> Color {
        switch level {
        case .strict: .green
        case .fair: .blue
        case .loose: .orange
        case .fail: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let answer = result.answer, let score = result.score {
                HStack(alignment: .top, spacing: 14) {
                    Text(score.level.displayName)
                        .font(.system(size: 40, weight: .bold, design: .serif))
                        .foregroundStyle(CoupletResultView.color(score.level))
                        .accessibilityIdentifier("drillLevel")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(score.reasons, id: \.self) { Text($0) }
                        if let meter = score.meter {
                            Text("律对判定：\(meter.rawValue)").foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 6)
                }
                if !score.positions.isEmpty { positionGrid(score) }
                collectButton(answer, mode: score.mode)
            }
            if let original = result.original {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("原文").foregroundStyle(.secondary)
                    Text(display(original.text)).font(.system(size: 20, design: .serif)).textSelection(.enabled)
                    Text(original.source).font(.caption).foregroundStyle(.secondary)
                    if result.originalWorkID != nil {
                        Button("查看全文") { Task { await openWork() } }.controlSize(.small)
                    }
                }
            }
            if !result.references.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.original == nil ? "典籍与律诗中的对" : "其他参考").font(.headline)
                    ForEach(result.references, id: \.self) { reference in
                        HStack(alignment: .firstTextBaseline) {
                            Text(display(reference.text)).font(.system(.body, design: .serif)).textSelection(.enabled)
                            Text(reference.source).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !result.commonCounterparts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("律诗对仗中常与「\(model.dictionary.converter.simplified(TextSegmenter.hanOnly(result.prompt)))」相对").font(.headline)
                    Text(result.commonCounterparts.map { "\($0.text) \($0.count)" }.joined(separator: "　"))
                        .font(.system(.body, design: .serif))
                        .textSelection(.enabled)
                }
            }
            if !result.previous.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("以往作答").font(.headline)
                    ForEach(result.previous) { attempt in
                        HStack(alignment: .firstTextBaseline) {
                            Text(attempt.createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary).monospacedDigit()
                            Text(display(attempt.answer)).font(.system(.body, design: .serif))
                            Text(attempt.level.displayName).foregroundStyle(CoupletResultView.color(attempt.level))
                        }
                    }
                }
            }
            Text("评分依据：字数、出对重字、平仄（多音字任一读音相对即可），以及语料中律诗中间各联的同位字统计。不判断词性与句法，只作参考。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .sheet(item: $viewingWork) { CorpusWorkView(work: $0) }
    }

    private func positionGrid(_ score: CoupletScore) -> some View {
        Grid(alignment: .center, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("出").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                ForEach(Array(score.positions.enumerated()), id: \.offset) { _, position in
                    Text(display(String(position.promptCharacter))).font(.system(size: 20, design: .serif))
                }
            }
            GridRow {
                Text("")
                ForEach(Array(score.positions.enumerated()), id: \.offset) { _, position in
                    Text(toneLabel(position.promptTones)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("对").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(score.positions.enumerated()), id: \.offset) { _, position in
                    Text(display(String(position.answerCharacter))).font(.system(size: 20, design: .serif))
                }
            }
            GridRow {
                Text("")
                ForEach(Array(score.positions.enumerated()), id: \.offset) { _, position in
                    Text(toneLabel(position.answerTones)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text("平仄").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(score.positions.enumerated()), id: \.offset) { _, position in
                    toneMark(position)
                }
            }
            GridRow {
                Text("对仗").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(score.positions.enumerated()), id: \.offset) { _, position in
                    Text(position.category ?? position.affinity.displayName)
                        .font(.caption)
                        .foregroundStyle(position.affinity == .common ? Color.green : position.affinity == .seen ? Color.primary : Color.orange)
                        .help("律诗对仗联中同位相对 \(position.pairCount) 次")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func toneLabel(_ tones: Set<Tone>) -> String {
        switch (tones.contains(.ping), tones.contains(.ze)) {
        case (true, true): "平仄"
        case (true, false): "平"
        case (false, true): "仄"
        case (false, false): "？"
        }
    }

    @ViewBuilder
    private func toneMark(_ position: CoupletScore.Position) -> some View {
        let text: String = switch position.tone {
        case .opposed: "相对"
        case .same: "相同"
        case .unknown: "未判"
        }
        Text(text)
            .font(.caption.weight(position.isKeyPosition ? .semibold : .regular))
            .foregroundStyle(position.tone == .same && position.isKeyPosition ? Color.red : position.isKeyPosition ? Color.primary : Color.secondary)
            .help(position.isKeyPosition ? "要位：平仄须相对" : "非要位：可平可仄")
    }

    private func collectButton(_ answer: String, mode: DrillMode) -> some View {
        Button("收藏此对") {
            Task {
                _ = await model.addPhrase(PhraseDraft(text: "\(result.prompt)，\(answer)", kind: .couplet,
                                                      tags: ["对仗/\(mode.displayName)"]))
            }
        }
        .controlSize(.small)
        .help("收进收藏，标签「对仗/\(mode.displayName)」")
    }

    private func openWork() async {
        guard let id = result.originalWorkID else { return }
        do {
            viewingWork = try await model.service.corpus.work(id: id)
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

// MARK: - 练习记录

struct DrillRecordsView: View {
    @Environment(AppModel.self) private var model
    @State private var attempts: [DrillAttempt] = []
    @State private var modeFilter: DrillMode?
    @State private var levelFilter: CoupletScore.Level?
    @State private var selection = Set<DrillAttempt.ID>()
    @State private var pendingDeletion = Set<DrillAttempt.ID>()

    private var filtered: [DrillAttempt] {
        attempts.filter { levelFilter == nil || $0.level == levelFilter }
    }

    private var summary: String {
        guard !attempts.isEmpty else { return "还没有练习记录" }
        let questions = Set(attempts.map(\.questionKey)).count
        let levels = CoupletScore.Level.allCases.reversed().map { level in
            "\(level.displayName) \(attempts.filter { $0.level == level }.count)"
        }
        return "共 \(attempts.count) 次作答、\(questions) 道题：" + levels.joined(separator: "，")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("模式", selection: $modeFilter) {
                    Text("全部").tag(DrillMode?.none)
                    ForEach(DrillMode.allCases) { Text($0.displayName).tag(DrillMode?.some($0)) }
                }
                .fixedSize()
                Picker("评级", selection: $levelFilter) {
                    Text("全部").tag(CoupletScore.Level?.none)
                    ForEach(CoupletScore.Level.allCases.reversed()) { Text($0.displayName).tag(CoupletScore.Level?.some($0)) }
                }
                .fixedSize()
                Spacer()
                Text(summary).foregroundStyle(.secondary).lineLimit(1)
            }
            Table(filtered, selection: $selection) {
                TableColumn("时间") { Text($0.createdAt.formatted(date: .numeric, time: .shortened)).monospacedDigit() }
                    .width(min: 110, ideal: 130)
                TableColumn("模式") { Text($0.mode.displayName) }.width(40)
                TableColumn("出") { Text($0.prompt).font(.system(.body, design: .serif)) }
                TableColumn("对") { Text($0.answer).font(.system(.body, design: .serif)) }
                TableColumn("评级") { attempt in
                    Text(attempt.level.displayName).foregroundStyle(CoupletResultView.color(attempt.level))
                }
                .width(40)
                TableColumn("出处") { Text($0.source).foregroundStyle(.secondary) }
            }
            .contextMenu(forSelectionType: DrillAttempt.ID.self) { ids in
                Button("删除\(ids.count > 1 ? " \(ids.count) 条记录" : "这条记录")…", role: .destructive) { pendingDeletion = ids }
                    .disabled(ids.isEmpty)
            }
            .onDeleteCommand { pendingDeletion = selection }
            .accessibilityIdentifier("drillRecords")
        }
        .padding(16)
        .task(id: modeFilter) { load() }
        .confirmationDialog("删除 \(pendingDeletion.count) 条练习记录？", isPresented: Binding(
            get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })) {
            Button("删除", role: .destructive) { delete(pendingDeletion) }
        } message: {
            Text("删除后，这些题在「只出新题」时可能重新出现。")
        }
    }

    private func load() {
        do {
            attempts = try model.service.library.drillAttempts(mode: modeFilter)
        } catch {
            model.errorMessage = String(describing: error)
        }
    }

    private func delete(_ ids: Set<DrillAttempt.ID>) {
        do {
            for id in ids { try model.service.library.deleteDrillAttempt(id: id) }
        } catch {
            model.errorMessage = String(describing: error)
        }
        pendingDeletion = []
        selection.subtract(ids)
        load()
    }
}
