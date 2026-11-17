import PoetryCore
import SwiftUI

/// 格律网格中的选区：同一句内的连续若干字。
struct GridSelection: Equatable, Hashable {
    var line: Int
    var anchor: Int
    var head: Int

    var range: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }
}

struct PoemEditorView: View {
    @Environment(AppModel.self) private var model
    let poemID: UUID

    @State private var poem = Poem()
    @State private var loaded = false
    @State private var selection: GridSelection?
    @State private var showInspector = true
    @State private var collectingText: String?
    @AppStorage("showMeter") private var showMeter = true
    @AppStorage("showLineEndRhyme") private var showLineEndRhyme = true

    var body: some View {
        let analysis = model.analyzer.analyze(poem.body, form: poem.form, book: poem.book, choices: poem.readingChoices)
        // 不用 VSplitView：它会把子视图的理想宽度累加为最小宽度，把整个窗口撑宽。
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("题目", text: $poem.title)
                        .textFieldStyle(.plain)
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .accessibilityIdentifier("poemTitle")
                    // 放在编辑区而非工具栏：工具栏右侧位于检查器上方，宽度不足时会越界。
                    FormPicker(form: $poem.form, tunes: model.tunes)
                    Picker("韵书", selection: $poem.book) {
                        ForEach(RhymeBook.allCases) { Text($0.displayName).tag($0) }
                    }
                    .accessibilityIdentifier("bookPicker")
                }
                .labelsHidden()
                TextEditor(text: $poem.body)
                    .font(.system(size: 20, design: .serif))
                    .scrollContentBackground(.hidden)
                    .accessibilityIdentifier("poemBody")
            }
            .padding(16)
            .frame(minHeight: 140, maxHeight: 240)

            Divider()

            AnalysisPane(analysis: analysis, showMeter: showMeter,
                         lineEndRhymes: showLineEndRhyme ? analysis.lineEndRhymeLabels(dictionary: model.dictionary) : nil,
                         selection: $selection, onChooseReading: chooseReading)
                .frame(minHeight: 240)
        }
        .frame(minWidth: 380)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Toggle("律句律对（律绝不显示）", isOn: $showMeter)
                        .accessibilityIdentifier("meterToggle")
                    Toggle("句末韵部", isOn: $showLineEndRhyme)
                        .accessibilityIdentifier("rhymeToggle")
                } label: {
                    Label("显示", systemImage: showMeter || showLineEndRhyme ? "eye" : "eye.slash")
                }
                .help("分析面板中显示的标注：律句律对（用于长庆体、梅村体等律化歌行）、句末字韵部")
                .accessibilityIdentifier("displayMenu")
                Button {
                    showInspector.toggle()
                } label: {
                    Label("检查器", systemImage: "sidebar.right")
                }
            }
        }
        .inspector(isPresented: $showInspector) {
            EditorInspector(analysis: analysis, selection: selection, poemID: poemID,
                            onReplace: replace(with:), onCollect: { collectingText = $0 }, onChooseReading: chooseReading)
                .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
        .sheet(item: Binding(get: { collectingText.map(CollectRequest.init) }, set: { collectingText = $0?.text })) { request in
            PhraseEditorSheet(initialText: request.text, initialKind: .original, draftID: poemID)
        }
        .onAppear {
            guard !loaded, let stored = model.poem(poemID) else { return }
            poem = stored
            loaded = true
        }
        .onChange(of: poem) { _, newValue in
            guard loaded else { return }
            model.save(newValue)
        }
        .onChange(of: poem.form) { selection = nil }
        .navigationTitle(poem.displayTitle)
    }

    private func replace(with candidate: String) {
        guard let selection else { return }
        let analysis = model.analyzer.analyze(poem.body, form: poem.form, book: poem.book, choices: poem.readingChoices)
        guard analysis.lines.indices.contains(selection.line) else { return }
        let characters = analysis.lines[selection.line].characters
        guard selection.range.upperBound < characters.count else { return }
        let offsets = selection.range.map { characters[$0].offset }
        guard let replaced = TextReplacement.replace(in: poem.body, offsets: offsets, with: candidate) else {
            model.errorMessage = "候选「\(candidate)」与所选 \(offsets.count) 字长度不符"
            return
        }
        poem.body = replaced
    }

    /// 在当前韵书下为该位置的字指定读音；nil 恢复自动判断。
    private func chooseReading(_ character: AnalyzedChar, _ reading: Reading?) {
        poem.readingChoices = ReadingChoice.updating(poem.readingChoices, character: character.character, at: character.offset,
                                                     book: poem.book, to: reading)
    }
}

private struct CollectRequest: Identifiable {
    let text: String
    var id: String { text }
}

struct FormPicker: View {
    @Binding var form: FormSelection
    let tunes: CiTuneLibrary

    var body: some View {
        Picker("体裁", selection: baseForm) {
            Text("自动识别").tag(FormSelection.automatic)
            Divider()
            ForEach(RegulatedForm.allCases, id: \.self) { Text($0.rawValue).tag(FormSelection.regulated($0)) }
            Divider()
            ForEach(tunes.tunes) { tune in
                Text("词·\(tune.name)").tag(FormSelection.ci(tune.id))
            }
            Divider()
            Text("自由（只标平仄）").tag(FormSelection.free)
        }
        .accessibilityIdentifier("formPicker")
        if case .regulated = form {
            Picker("起收", selection: opening) {
                Text("自动起收").tag(RegulatedOpening?.none)
                Divider()
                ForEach(RegulatedOpening.allCases, id: \.self) { Text($0.rawValue).tag(RegulatedOpening?.some($0)) }
            }
            .help("起看首句第二字，收看首句末字（平收即首句入韵）")
            .accessibilityIdentifier("openingPicker")
        }
    }

    private var currentOpening: RegulatedOpening? {
        if case .regulated(_, let opening) = form { return opening }
        return nil
    }

    /// 体裁菜单只按体裁本身选择，不受起收影响；在律绝之间切换时保留已指定的起收。
    private var baseForm: Binding<FormSelection> {
        Binding(
            get: {
                if case .regulated(let regulated, _) = form { return .regulated(regulated) }
                return form
            },
            set: { newValue in
                if case .regulated(let regulated, _) = newValue {
                    form = .regulated(regulated, opening: currentOpening)
                } else {
                    form = newValue
                }
            }
        )
    }

    private var opening: Binding<RegulatedOpening?> {
        Binding(
            get: { currentOpening },
            set: { newValue in
                guard case .regulated(let regulated, _) = form else { return }
                form = .regulated(regulated, opening: newValue)
            }
        )
    }
}

// MARK: - 分析面板

struct AnalysisPane: View {
    let analysis: PoemAnalysis
    let showMeter: Bool
    /// 每句句末字韵部；nil 表示不显示。
    let lineEndRhymes: [[String]]?
    @Binding var selection: GridSelection?
    let onChooseReading: (AnalyzedChar, Reading?) -> Void

    var body: some View {
        // 律绝已逐字检查格律，不再重复标注律句律对。
        let meter = showMeter && !analysis.lines.isEmpty && analysis.regulatedForm == nil ? analysis.meter : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let meter {
                    MeterSummary(meter: meter)
                }
                if analysis.lines.isEmpty {
                    Text("在上方输入正文；标点或换行分句，也可不加标点按字数自动切分。")
                        .foregroundStyle(.secondary)
                } else {
                    AnalysisGrid(analysis: analysis, meter: meter, lineEndRhymes: lineEndRhymes, selection: $selection,
                                 onChooseReading: onChooseReading)
                    Legend()
                    IssueList(issues: analysis.issues, selection: $selection, analysis: analysis)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(analysis.formName).font(.headline).accessibilityIdentifier("formName")
            if let variant = analysis.variantName {
                Text(variant).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(analysis.book.displayName).foregroundStyle(.secondary)
            if !analysis.lines.isEmpty {
                Label("\(analysis.errorCount)", systemImage: "xmark.octagon")
                    .foregroundStyle(analysis.errorCount > 0 ? .red : .secondary)
                    .help("错误")
                    .accessibilityIdentifier("errorCount")
                Label("\(analysis.warningCount)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(analysis.warningCount > 0 ? .orange : .secondary)
                    .help("警告")
            }
        }
    }
}

struct AnalysisGrid: View {
    let analysis: PoemAnalysis
    /// nil 表示不显示律句律对。
    let meter: MeterAnalysis?
    /// nil 表示不显示句末字韵部。
    let lineEndRhymes: [[String]]?
    @Binding var selection: GridSelection?
    let onChooseReading: (AnalyzedChar, Reading?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(analysis.lines.enumerated()), id: \.offset) { lineIndex, line in
                if lineIndex > 0, line.stanza != analysis.lines[lineIndex - 1].stanza {
                    Divider().padding(.vertical, 4)
                }
                HStack(spacing: 4) {
                    Button {
                        selection = GridSelection(line: lineIndex, anchor: 0, head: max(0, line.characters.count - 1))
                    } label: {
                        Text("\(lineIndex + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 22)
                    }
                    .buttonStyle(.plain)
                    .help("选中整句")
                    ForEach(Array(line.characters.enumerated()), id: \.offset) { column, character in
                        CharCell(character: character, isSelected: isSelected(lineIndex, column))
                            .onTapGesture { tap(line: lineIndex, column: column) }
                            .contextMenu {
                                ReadingPicker(character: character, book: analysis.book, onChoose: onChooseReading)
                                    .pickerStyle(.inline)
                                Divider()
                                SouYunButtons(character: character.character)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("cell-\(lineIndex)-\(column)")
                            .accessibilityAddTraits(.isButton)
                    }
                    if let pattern = line.patternText {
                        Text(pattern)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 12)
                            .help("格律要求（中＝可平可仄）")
                    }
                    if let lineEndRhymes, lineEndRhymes.indices.contains(lineIndex) {
                        rhymeTag(lineEndRhymes[lineIndex], line: line, index: lineIndex)
                            .padding(.leading, 12)
                    }
                    if let meter {
                        MeterTags(meter: meter, line: lineIndex)
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func rhymeTag(_ labels: [String], line: AnalyzedLine, index: Int) -> TagLabel {
        let last = line.characters.last.map { String($0.character) } ?? ""
        return TagLabel(text: labels.isEmpty ? "未收录" : labels.joined(separator: "／"), color: .accentColor,
                        help: "句末字「\(last)」的韵部（\(analysis.book.displayName)）", identifier: "rhyme-\(index)")
    }

    private func isSelected(_ line: Int, _ column: Int) -> Bool {
        guard let selection, selection.line == line else { return false }
        return selection.range.contains(column)
    }

    private func tap(line: Int, column: Int) {
        if NSEvent.modifierFlags.contains(.shift), let current = selection, current.line == line {
            selection = GridSelection(line: line, anchor: current.anchor, head: column)
        } else {
            selection = GridSelection(line: line, anchor: column, head: column)
        }
    }
}

struct CharCell: View {
    let character: AnalyzedChar
    let isSelected: Bool

    private var toneLabel: String {
        switch character.tones.count {
        case 0: "？"
        case 1: character.tones.first?.rawValue ?? "？"
        default: "平仄"
        }
    }

    private var fill: Color {
        switch character.status {
        case .mismatch: .red.opacity(0.28)
        case .rescued: .orange.opacity(0.22)
        case .flexible: .yellow.opacity(0.18)
        case .ambiguous: .blue.opacity(0.14)
        case .unknown: .gray.opacity(0.22)
        case .ok, .unconstrained: Color(nsColor: .controlBackgroundColor)
        }
    }

    private var helpText: String {
        var parts = ["实际：\(toneLabel)"]
        if let expected = character.expected { parts.append("要求：\(expected.rawValue)") }
        switch character.status {
        case .mismatch: parts.append("不合律")
        case .rescued: parts.append("拗救或特定格式")
        case .flexible: parts.append("可平可仄处")
        case .ambiguous: parts.append("多音字")
        case .unknown: parts.append("韵书未收录")
        default: break
        }
        if character.rhymeGroup != nil { parts.append("韵脚") }
        if character.chosenReading != nil { parts.append("已指定读音") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(String(character.character))
                .font(.system(size: 26, design: .serif))
            Text(toneLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .frame(width: 42, height: 58)
        .background(RoundedRectangle(cornerRadius: 6).fill(fill))
        .overlay(alignment: .topTrailing) {
            if let group = character.rhymeGroup {
                Text(group == "A" ? "韵" : "韵\(group)")
                    .font(.system(size: 8, weight: .bold))
                    .padding(2)
                    .foregroundStyle(.white)
                    .background(Circle().fill(Color.accentColor))
                    .offset(x: 3, y: -3)
            }
        }
        .overlay(alignment: .topLeading) {
            if character.chosenReading != nil {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color.accentColor)
                    .padding(3)
                    .accessibilityLabel("已指定读音")
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(Rectangle())
        .help(helpText)
    }
}

// MARK: - 律句律对

struct MeterSummary: View {
    let meter: MeterAnalysis

    var body: some View {
        Group {
            if meter.supportedLineCount == 0 {
                Text("没有五言或七言句，不判断律句")
            } else {
                Text("律句 \(meter.regularLineCount)/\(meter.supportedLineCount)　律对 \(meter.opposedCoupletCount)/\(meter.pairedCoupletCount)　粘 \(meter.adheredCount)/\(meter.adherenceCheckedCount)")
                    .help("按次序两句一联；粘只在相邻两句都是律句且字数相同时判断")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("meterSummary")
    }
}

/// 一句后面的标注：句型、与上联的粘（出句）、本联是否律对（对句）。
struct MeterTags: View {
    let meter: MeterAnalysis
    let line: Int

    var body: some View {
        let couplet = meter.couplet(containing: line)
        HStack(spacing: 6) {
            switch meter.lines[line] {
            case .regular(let lineMeter):
                TagLabel(text: lineMeter.variant == .standard ? "律·\(lineMeter.displayName)" : "律·\(lineMeter.displayName)（\(lineMeter.variant.rawValue)）",
                         color: .green, help: "律句，句型 \(lineMeter.patternText)", identifier: "meter-\(line)")
            case .irregular:
                TagLabel(text: "非律句", color: .orange, help: "不合五七言律句句型（含孤平、三平尾、大拗未救）", identifier: "meter-\(line)")
            case .unsupported:
                EmptyView()
            }
            if let couplet, couplet.firstLine == line, let adheres = couplet.adheres {
                TagLabel(text: adheres ? "粘" : "不粘", color: adheres ? .secondary : .orange,
                         help: adheres ? "与上句第二字平仄相同" : "与上句第二字平仄不同", identifier: "adhere-\(line)")
            }
            if let couplet, couplet.lastLine == line, couplet.relation != .unpaired {
                let text = couplet.relation == .opposed && couplet.sharesEnding
                    ? "\(couplet.relation.rawValue)（出句入韵）" : couplet.relation.rawValue
                TagLabel(text: text, color: couplet.relation == .opposed ? .green : .orange,
                         help: "第\(couplet.firstLine + 1)、\(couplet.lastLine + 1)句", identifier: "couplet-\(line)")
            }
        }
    }
}

/// 网格行尾的小标签。
struct TagLabel: View {
    let text: String
    let color: Color
    let help: String
    let identifier: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .help(help)
            .accessibilityIdentifier(identifier)
    }
}

struct Legend: View {
    var body: some View {
        HStack(spacing: 14) {
            item(.red.opacity(0.28), "不合律")
            item(.orange.opacity(0.22), "拗救/特拗")
            item(.yellow.opacity(0.18), "可平可仄")
            item(.blue.opacity(0.14), "多音字")
            item(.gray.opacity(0.22), "未收录")
            Label("已指定读音", systemImage: "pin.fill")
            Text("点选字、按住 Shift 扩选，右侧给出替换候选；右键多音字可指定读音").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func item(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 12, height: 12)
            Text(text)
        }
    }
}

struct IssueList: View {
    let issues: [Issue]
    @Binding var selection: GridSelection?
    let analysis: PoemAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(issues) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: icon(issue.severity))
                        .foregroundStyle(color(issue.severity))
                    Text(issue.message)
                        .textSelection(.enabled)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard let first = issue.positions.first, analysis.character(at: first) != nil else { return }
                    selection = GridSelection(line: first.line, anchor: first.column, head: first.column)
                }
            }
        }
        .accessibilityIdentifier("issueList")
    }

    private func icon(_ severity: Severity) -> String {
        switch severity {
        case .error: "xmark.octagon.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .hint: "info.circle"
        }
    }

    private func color(_ severity: Severity) -> Color {
        switch severity {
        case .error: .red
        case .warning: .orange
        case .hint: .secondary
        }
    }
}
