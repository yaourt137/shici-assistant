import AppKit
import PoetryCore
import SwiftUI

// MARK: - 读诗页

/// 读诗：左侧为圈点本列表（最近读过的在前），右侧读所选的一首。可粘入新诗，或按诗句在语料中查找。
struct ReadingHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @State private var isPasting = false
    @State private var isSearching = false
    @State private var deleting: MarkedPoem?

    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Button("粘贴新诗", systemImage: "doc.on.clipboard") { isPasting = true }
                        .accessibilityIdentifier("readingPaste")
                    Button("从语料查找", systemImage: "magnifyingglass") { isSearching = true }
                        .accessibilityIdentifier("readingSearch")
                }
                .controlSize(.small)
                .padding(8)
                if model.markedPoems.isEmpty {
                    ContentUnavailableView("还没有读过的诗", systemImage: "book.pages",
                                           description: Text("粘入一首，或在语料中查找；查看语料全文时也可点「读诗」。"))
                } else {
                    List(model.markedPoems, selection: $model.readingSelection) { poem in
                        MarkedPoemRow(poem: poem)
                            .tag(poem.id)
                            .contextMenu {
                                Button("在新窗口中打开") { openWindow(id: MarkedPoemReader.windowID, value: poem.id) }
                                Divider()
                                Button("删除…", role: .destructive) { deleting = poem }
                            }
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)

            Group {
                if let id = model.readingSelection, model.markedPoem(id) != nil {
                    MarkedPoemReader(poemID: id).id(id)
                } else {
                    ContentUnavailableView("选一首来读", systemImage: "text.book.closed")
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("读诗")
        .sheet(isPresented: $isPasting) {
            PastePoemSheet { model.readingSelection = $0.id }
        }
        .sheet(isPresented: $isSearching) {
            CorpusPoemSearchSheet { model.readingSelection = $0.id }
        }
        .confirmationDialog("删除「\(deleting.map(MarkedPoemRow.title) ?? "")」及其圈点、批注？",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("删除", role: .destructive) {
                if let deleting { model.deleteMarkedPoem(deleting.id) }
                deleting = nil
            }
        }
    }
}

struct MarkedPoemRow: View {
    let poem: MarkedPoem

    static func title(_ poem: MarkedPoem) -> String {
        poem.title.isEmpty ? "无题" : poem.title
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(MarkedPoemRow.title(poem)).font(.system(.body, design: .serif)).lineLimit(1)
            HStack(spacing: 6) {
                Text(SourceInfo(author: poem.author, dynasty: poem.dynasty).summary)
                if !poem.marks.isEmpty || !poem.notes.isEmpty {
                    Text("圈点 \(poem.marks.count) · 批注 \(poem.notes.count)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

// MARK: - 阅读与圈点

/// 读一首诗：拖选文字后用工具栏圈点、批注；双击一句整句密圈。圈点与批注随改随存，可撤销。
struct MarkedPoemReader: View {
    static let windowID = "reader"

    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let poemID: UUID

    @AppStorage("readingShowSimplified") private var showSimplified = false
    @AppStorage("readingShowTones") private var showTones = false
    @AppStorage("readingShowRhymes") private var showRhymes = false
    @AppStorage("readingRhymeBook") private var book: RhymeBook = .pingshui
    @AppStorage("readingVertical") private var isVertical = false
    @AppStorage(MarkInk.storageKey) private var ink: MarkInk = .vermilion
    @State private var selection: LineRange?
    @State private var focusedNoteID: UUID?
    @State private var noteDraft: NoteDraft?
    @State private var collecting: String?

    private var poem: MarkedPoem? { model.markedPoem(poemID) }

    var body: some View {
        if let poem {
            VStack(alignment: .leading, spacing: 0) {
                header(poem)
                Divider()
                HStack(spacing: 0) {
                    textArea(poem)
                    Divider()
                    notesPane(poem).frame(width: 240)
                }
                Divider()
                Text("拖选或点选文字后用上方按钮圈点；双击一句整句密圈。再按一次同样的圈点即取消，可用「编辑 > 撤销」。")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
            .navigationTitle(MarkedPoemRow.title(poem))
            .sheet(item: $noteDraft) { draft in
                NoteEditorSheet(draft: draft) { text in saveNote(draft, text: text) }
            }
            .sheet(isPresented: Binding(get: { collecting != nil }, set: { if !$0 { collecting = nil } })) {
                PhraseEditorSheet(initialText: collecting ?? "", initialKind: .excerpt, draftID: nil, initialSource: poem.source)
            }
        } else {
            ContentUnavailableView("这首已删除", systemImage: "text.book.closed")
        }
    }

    /// 正文：横排上下滚动；竖排左右滚动，打开时停在最右边（第一列）。
    private func textArea(_ poem: MarkedPoem) -> some View {
        // 用 GeometryReader 取可用空间：它的大小不随内容变化，避免内容与测量互相牵动、反复布局。
        GeometryReader { proxy in
            let canvas = MarkedPoemCanvas(poem: poem, selection: $selection, focusedNoteID: focusedNoteID, isVertical: isVertical,
                                          viewport: proxy.size, ink: ink.color, showSimplified: showSimplified,
                                          showTones: showTones, showRhymes: showRhymes, book: book,
                                          onTapSlot: { slot in focusedNoteID = poem.notes(at: slot).first?.id },
                                          onDoubleTapClause: { clause in apply(.circle, to: clause, actionName: "密圈") })
            if isVertical {
                ScrollView(.horizontal) { canvas }
                    .defaultScrollAnchor(.trailing)
            } else {
                ScrollView { canvas }
            }
        }
    }

    private func header(_ poem: MarkedPoem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(display(MarkedPoemRow.title(poem))).font(.system(.title2, design: .serif))
                Text(display(SourceInfo(author: poem.author, dynasty: poem.dynasty).summary)).foregroundStyle(.secondary)
                Text(originDescription(poem.origin)).font(.caption).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                markButtons(poem).disabled(selection == nil)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            HStack(spacing: 10) {
                Toggle("竖排", isOn: $isVertical).accessibilityIdentifier("readingVertical")
                Toggle("简体", isOn: $showSimplified)
                Toggle("平仄", isOn: $showTones)
                Toggle("韵部", isOn: $showRhymes)
                Picker("韵书", selection: $book) {
                    ForEach(RhymeBook.allCases) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .disabled(!showTones && !showRhymes)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
        }
        .padding(16)
    }

    /// 作用于所选文字的按钮：圈点、擦除、批注、收藏。
    @ViewBuilder
    private func markButtons(_ poem: MarkedPoem) -> some View {
        ForEach(PoemMarkKind.allCases) { kind in
            Button { apply(kind) } label: { MarkKindLabel(kind: kind) }
                .keyboardShortcut(MarkedPoemReader.shortcut(for: kind), modifiers: [.command, .option])
                .help("\(kind.rawValue)（⌥⌘\(MarkedPoemReader.shortcut(for: kind).character)）")
                .accessibilityIdentifier("readingMark-\(kind.rawValue)")
        }
        Button("擦除") { erase() }
            .keyboardShortcut(.delete, modifiers: .command)
            .help("去掉所选文字上的圈点（⌘⌫）")
        Divider().frame(height: 16)
        Button("批注") { beginNote() }
            .keyboardShortcut("5", modifiers: [.command, .option])
            .help("为所选文字写批注（⌥⌘5）")
        Button("收藏") { collecting = selection.map(poem.text(of:)) }
            .help("把所选文字收进收藏，出处自动填好")
    }

    private func notesPane(_ poem: MarkedPoem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("批注").font(.headline).padding(12)
            if poem.notes.isEmpty {
                Text("选中文字后点「批注」。").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 12)
                Spacer()
            } else {
                List(selection: Binding(get: { focusedNoteID }, set: { focusedNoteID = $0 })) {
                    ForEach(Array(poem.notes.enumerated()), id: \.element.id) { index, note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(index + 1)　\(display(poem.text(of: note.range)))")
                                .font(.system(.callout, design: .serif)).foregroundStyle(.secondary)
                            Text(note.text).textSelection(.enabled)
                        }
                        .tag(note.id)
                        .contextMenu {
                            Button("编辑…") { noteDraft = NoteDraft(noteID: note.id, range: note.range, quote: poem.text(of: note.range), text: note.text) }
                            Button("删除", role: .destructive) { deleteNote(note.id) }
                        }
                        .onTapGesture(count: 2) {
                            noteDraft = NoteDraft(noteID: note.id, range: note.range, quote: poem.text(of: note.range), text: note.text)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func display(_ text: String) -> String {
        showSimplified ? model.dictionary.converter.simplified(text) : text
    }

    private func originDescription(_ origin: MarkedPoemOrigin) -> String {
        switch origin {
        case .corpus(let packName, _): "语料 · \(packName)"
        case .pasted: "粘入"
        }
    }

    /// 与 ⌥⌘ 合用（⌘ 加数字已用于切换页面）。
    static func shortcut(for kind: PoemMarkKind) -> KeyEquivalent {
        switch kind {
        case .circle: "1"
        case .dot: "2"
        case .properName: "3"
        case .bookTitle: "4"
        }
    }

    private func apply(_ kind: PoemMarkKind) {
        guard let selection else { return }
        apply(kind, to: selection, actionName: kind.rawValue)
    }

    private func apply(_ kind: PoemMarkKind, to range: LineRange, actionName: String) {
        model.updateMarkedPoem(poemID, actionName: actionName, undoManager: undoManager) { try $0.applyMark(kind, to: range) }
    }

    private func erase() {
        guard let selection else { return }
        model.updateMarkedPoem(poemID, actionName: "擦除", undoManager: undoManager) { try $0.eraseMarks(in: selection) }
    }

    private func beginNote() {
        guard let selection, let poem else { return }
        noteDraft = NoteDraft(noteID: nil, range: selection, quote: poem.text(of: selection), text: "")
    }

    private func saveNote(_ draft: NoteDraft, text: String) {
        model.updateMarkedPoem(poemID, actionName: "批注", undoManager: undoManager) { poem in
            if let id = draft.noteID {
                try poem.updateNote(id: id, text: text)
            } else {
                focusedNoteID = try poem.addNote(text, to: draft.range).id
            }
        }
    }

    private func deleteNote(_ id: UUID) {
        model.updateMarkedPoem(poemID, actionName: "删除批注", undoManager: undoManager) { try $0.removeNote(id: id) }
        if focusedNoteID == id { focusedNoteID = nil }
    }
}

/// 工具栏上圈点按钮的图示。
private struct MarkKindLabel: View {
    let kind: PoemMarkKind

    var body: some View {
        HStack(spacing: 3) {
            switch kind {
            case .circle: Image(systemName: "circle")
            case .dot: Image(systemName: "circle.fill").imageScale(.small)
            case .properName: Image(systemName: "underline")
            case .bookTitle: Image(systemName: "water.waves")
            }
            Text(kind.rawValue)
        }
    }
}

struct NoteDraft: Identifiable {
    let id = UUID()
    /// 修改已有批注时为其 id。
    let noteID: UUID?
    let range: LineRange
    let quote: String
    let text: String
}

struct NoteEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let draft: NoteDraft
    let onSave: (String) -> Void

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.noteID == nil ? "批注" : "修改批注").font(.headline)
            Text("「\(draft.quote)」").font(.system(.title3, design: .serif)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 15, design: .serif))
                .frame(minHeight: 120)
                .accessibilityIdentifier("noteText")
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { text = draft.text }
    }
}

// MARK: - 逐字绘制

/// 圈点的颜色：朱笔或墨笔。
enum MarkInk: String, CaseIterable, Identifiable {
    case vermilion = "朱"
    case black = "墨"

    static let storageKey = "readingMarkInk"

    var id: String { rawValue }

    var color: Color {
        switch self {
        // 朱砂色，在白底上不刺眼。
        case .vermilion: Color(red: 0.74, green: 0.2, blue: 0.13)
        // 随深浅色外观取正文颜色。
        case .black: .primary
        }
    }
}

/// 逐字排在格子里。横排：字上方标平仄或韵部，字下画专名线、书名线，再下为圈、点。
/// 竖排：一行一列、自右向左，圈、点在字左（比专名线、书名线更靠外），平仄在字右；标点用竖排字形。选中与批注处衬底色。
struct MarkedPoemCanvas: View {
    @Environment(AppModel.self) private var model
    let poem: MarkedPoem
    @Binding var selection: LineRange?
    let focusedNoteID: UUID?
    let isVertical: Bool
    /// 可见区域的大小（含边距）。
    let viewport: CGSize
    let ink: Color
    let showSimplified: Bool
    let showTones: Bool
    let showRhymes: Bool
    let book: RhymeBook
    let onTapSlot: (CharacterSlot) -> Void
    let onDoubleTapClause: (LineRange) -> Void

    static let padding = EdgeInsets(top: 20, leading: 16, bottom: 20, trailing: 16)
    private static let labelThickness: CGFloat = 14
    /// 字格长度的上下限：按最长一行缩放，使常见的一联放得下一行。
    private static let cellWidthRange: ClosedRange<Double> = 26...34

    /// 一个字格中各部分的位置。
    private struct CellGeometry {
        let glyph: CGRect
        let label: CGPoint
        /// 专名线、书名线所在的横坐标（竖排）或纵坐标（横排）。
        let lineCross: CGFloat
        let emphasis: CGPoint
        let noteNumber: CGPoint
    }

    var body: some View {
        let lines = poem.lines
        let inner = CGSize(width: max(viewport.width - MarkedPoemCanvas.padding.leading - MarkedPoemCanvas.padding.trailing, 60),
                           height: max(viewport.height - MarkedPoemCanvas.padding.top - MarkedPoemCanvas.padding.bottom, 60))
        let available = isVertical ? inner.height : inner.width
        let metrics = MarkedPoemCanvas.metrics(available: available, lines: lines, isVertical: isVertical)
        // 留出一格给悬挂的标点。
        let layout = MarkedPoemLayout.layout(lines: lines, length: Double(available) - metrics.cellWidth, metrics: metrics)
        let extent = CGFloat(layout.extent)
        let size = isVertical ? CGSize(width: max(extent, inner.width), height: inner.height)
                              : CGSize(width: inner.width, height: max(extent, 40))
        // 竖排时内容靠右。
        let offsetX = isVertical ? size.width - extent : 0
        let annotations = (showTones || showRhymes) ? TextAnnotator.annotate(poem.body, book: book, dictionary: model.dictionary) : []
        Canvas { context, _ in
            context.translateBy(x: offsetX, y: 0)
            draw(in: &context, lines: lines, cells: layout.cells, metrics: metrics, annotations: annotations)
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    let find = { (point: CGPoint) in slot(at: point, offsetX: offsetX, cells: layout.cells, metrics: metrics) }
                    guard let start = find(value.startLocation), let end = find(value.location) ?? selectionEnd(from: start) else { return }
                    selection = PoemMarking.selection(from: start, to: end, in: lines)
                }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { value in
                guard let slot = slot(at: value.location, offsetX: offsetX, cells: layout.cells, metrics: metrics),
                      let clause = PoemMarking.clause(in: lines, line: slot.line, offset: slot.offset) else { return }
                selection = clause
                onDoubleTapClause(clause)
            }
        )
        .simultaneousGesture(
            SpatialTapGesture(count: 1).onEnded { value in
                guard let slot = slot(at: value.location, offsetX: offsetX, cells: layout.cells, metrics: metrics) else {
                    selection = nil
                    return
                }
                selection = PoemMarking.selection(from: slot, to: slot, in: lines)
                onTapSlot(slot)
            }
        )
        .padding(MarkedPoemCanvas.padding)
        .accessibilityElement()
        .accessibilityLabel(poem.body)
        .accessibilityIdentifier("readingCanvas")
    }

    /// 字格：长度随可用空间与最长一行变化，字高与字格同长；厚度含平仄标注、线与圈点的位置。
    private static func metrics(available: CGFloat, lines: [String], isVertical: Bool) -> MarkedPoemLayout.Metrics {
        let cell = MarkedPoemLayout.fittedCellWidth(width: Double(available), lines: lines, range: cellWidthRange)
        let thickness = Double(labelThickness) + cell + (isVertical ? 32 : 24)
        return MarkedPoemLayout.Metrics(cellWidth: cell, rowHeight: thickness, emptyLineHeight: 24, isVertical: isVertical)
    }

    private func geometry(of cell: MarkedPoemLayout.Cell, metrics: MarkedPoemLayout.Metrics) -> CellGeometry {
        let side = CGFloat(metrics.cellWidth)
        let x = CGFloat(cell.x), y = CGFloat(cell.y)
        let label = MarkedPoemCanvas.labelThickness
        if isVertical {
            // 横排顺时针转九十度：平仄在右，专名线贴字左，圈点在更左。
            let glyph = CGRect(x: x + 26, y: y, width: side, height: side)
            return CellGeometry(glyph: glyph, label: CGPoint(x: glyph.maxX + 8, y: glyph.midY), lineCross: glyph.minX + 1,
                                emphasis: CGPoint(x: glyph.minX - 7, y: glyph.midY),
                                noteNumber: CGPoint(x: glyph.maxX - 2, y: glyph.maxY - 3))
        }
        let glyph = CGRect(x: x, y: y + label, width: side, height: side)
        return CellGeometry(glyph: glyph, label: CGPoint(x: glyph.midX, y: y + label / 2), lineCross: glyph.maxY + 1,
                            emphasis: CGPoint(x: glyph.midX, y: glyph.maxY + 10),
                            noteNumber: CGPoint(x: glyph.maxX - 2, y: glyph.minY + 2))
    }

    private func slot(at point: CGPoint, offsetX: CGFloat, cells: [MarkedPoemLayout.Cell],
                      metrics: MarkedPoemLayout.Metrics) -> CharacterSlot? {
        MarkedPoemLayout.slot(at: (x: Double(point.x - offsetX), y: Double(point.y)), in: cells, metrics: metrics)
    }

    /// 拖到格子外时沿用当前选区的另一端。
    private func selectionEnd(from start: CharacterSlot) -> CharacterSlot? {
        guard let selection, selection.line == start.line else { return nil }
        let other = start.offset == selection.start ? selection.end - 1 : selection.start
        return CharacterSlot(line: start.line, offset: other)
    }

    private func draw(in context: inout GraphicsContext, lines: [String], cells: [MarkedPoemLayout.Cell],
                      metrics: MarkedPoemLayout.Metrics, annotations: [[AnnotatedCharacter]]) {
        let side = CGFloat(metrics.cellWidth)
        let characters = lines.map(Array.init)
        let marksBySlot = PoemMarking.marksByCharacter(poem.marks)
        let converter = model.dictionary.converter
        var geometryBySlot: [CharacterSlot: CellGeometry] = [:]
        for cell in cells { geometryBySlot[cell.slot] = geometry(of: cell, metrics: metrics) }

        // 底色：批注（所指批注较深）与选区。
        for note in poem.notes {
            let opacity = note.id == focusedNoteID ? 0.35 : 0.16
            for offset in note.range.start..<note.range.end {
                guard let geometry = geometryBySlot[CharacterSlot(line: note.range.line, offset: offset)] else { continue }
                context.fill(Path(geometry.glyph), with: .color(.yellow.opacity(opacity)))
            }
        }
        if let selection {
            for offset in selection.start..<selection.end {
                guard let geometry = geometryBySlot[CharacterSlot(line: selection.line, offset: offset)] else { continue }
                context.fill(Path(geometry.glyph), with: .color(.accentColor.opacity(0.22)))
            }
        }

        for cell in cells {
            let slot = cell.slot
            guard characters.indices.contains(slot.line), characters[slot.line].indices.contains(slot.offset),
                  let geometry = geometryBySlot[slot] else { continue }
            let original = characters[slot.line][slot.offset]
            var shown = showSimplified ? converter.simplified(original) : original
            if isVertical { shown = MarkedPoemLayout.verticalForm(of: shown) }
            context.draw(Text(String(shown)).font(.system(size: side * 0.7, design: .serif)),
                         at: CGPoint(x: geometry.glyph.midX, y: geometry.glyph.midY))

            if annotations.indices.contains(slot.line), annotations[slot.line].indices.contains(slot.offset) {
                drawAnnotation(annotations[slot.line][slot.offset], in: &context, geometry: geometry)
            }
            for kind in marksBySlot[slot] ?? [] where !kind.isUnderline {
                drawEmphasis(kind, at: geometry.emphasis, side: side, in: &context)
            }
        }

        // 专名线、书名线按段画，相邻两段之间留空，折行处断开。
        for mark in poem.marks where mark.kind.isUnderline {
            var segment: (start: CGFloat, end: CGFloat, cross: CGFloat)?
            func flush() {
                guard let current = segment else { return }
                drawLine(mark.kind, from: current.start, to: current.end, cross: current.cross, in: &context)
                segment = nil
            }
            for offset in mark.range.start..<mark.range.end {
                guard let geometry = geometryBySlot[CharacterSlot(line: mark.range.line, offset: offset)] else { continue }
                let (start, end) = isVertical ? (geometry.glyph.minY, geometry.glyph.maxY) : (geometry.glyph.minX, geometry.glyph.maxX)
                if let current = segment, current.cross == geometry.lineCross {
                    segment = (current.start, end - 3, current.cross)
                } else {
                    flush()
                    segment = (start + 3, end - 3, geometry.lineCross)
                }
            }
            flush()
        }

        // 批注序号标在所指文字末字旁。
        for (index, note) in poem.notes.enumerated() {
            guard let geometry = geometryBySlot[CharacterSlot(line: note.range.line, offset: note.range.end - 1)] else { continue }
            context.draw(Text("\(index + 1)").font(.system(size: 9, weight: .semibold)).foregroundColor(.orange), at: geometry.noteNumber)
        }
    }

    /// 圈「○」与点「、」（点画成一笔短斜的笔触）。
    private func drawEmphasis(_ kind: PoemMarkKind, at center: CGPoint, side: CGFloat, in context: inout GraphicsContext) {
        switch kind {
        case .circle:
            let radius = side * 0.17
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                           with: .color(ink), lineWidth: 1.6)
        case .dot:
            let length = side * 0.17
            var stroke = Path()
            stroke.move(to: CGPoint(x: center.x - length * 0.32, y: center.y - length * 0.5))
            stroke.addQuadCurve(to: CGPoint(x: center.x + length * 0.3, y: center.y + length * 0.5),
                                control: CGPoint(x: center.x + length * 0.25, y: center.y - length * 0.15))
            context.stroke(stroke, with: .color(ink), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        case .properName, .bookTitle:
            break
        }
    }

    /// 平仄或韵部的小字：开了韵部时分句末字标韵部，否则开了平仄时标平仄。竖排时逐字竖写。
    private func drawAnnotation(_ item: AnnotatedCharacter, in context: inout GraphicsContext, geometry: CellGeometry) {
        guard item.isHan else { return }
        let stacked = { (text: String) in self.isVertical ? text.map(String.init).joined(separator: "\n") : text }
        if showRhymes, let labels = item.rhymeLabels {
            let text = labels.isEmpty ? "未收录" : labels.joined(separator: "／")
            let label = Text(stacked(text)).font(.system(size: 9)).foregroundColor(.accentColor)
            if isVertical {
                // 竖排时从字的上端往下写，多出的部分落在其后的标点旁。
                context.draw(label, at: CGPoint(x: geometry.label.x, y: geometry.glyph.minY), anchor: .top)
            } else {
                context.draw(label, at: geometry.label)
            }
        } else if showTones {
            let color: Color = switch item.tones.count {
            case 1: item.tones.contains(.ping) ? .secondary : .primary
            case 0: .gray
            default: .blue
            }
            context.draw(Text(stacked(item.tones.label)).font(.system(size: 9, design: .monospaced)).foregroundColor(color),
                         at: geometry.label)
        }
    }

    /// 专名线（直线）或书名线（波浪线），沿行的方向从 `start` 画到 `end`，位于 `cross`。
    private func drawLine(_ kind: PoemMarkKind, from start: CGFloat, to end: CGFloat, cross: CGFloat, in context: inout GraphicsContext) {
        let point = { (along: CGFloat, offset: CGFloat) in
            self.isVertical ? CGPoint(x: cross + offset, y: along) : CGPoint(x: along, y: cross + offset)
        }
        var path = Path()
        path.move(to: point(start, 0))
        if kind == .bookTitle {
            // 波浪线：半波长 3，振幅约 1.6。
            var along = start
            var up = true
            while along < end {
                let next = min(along + 3, end)
                path.addQuadCurve(to: point(next, 0), control: point((along + next) / 2, up ? -3.2 : 3.2))
                along = next
                up.toggle()
            }
        } else {
            path.addLine(to: point(end, 0))
        }
        context.stroke(path, with: .color(ink), lineWidth: 1.2)
    }
}

// MARK: - 新建

/// 粘入一首新诗。
struct PastePoemSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreate: (MarkedPoem) -> Void

    @State private var title = ""
    @State private var author = ""
    @State private var dynasty = ""
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("粘贴新诗").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("题目").foregroundStyle(.secondary)
                    TextField("可空", text: $title).accessibilityIdentifier("pasteTitle")
                }
                GridRow {
                    Text("作者").foregroundStyle(.secondary)
                    HStack {
                        TextField("可空", text: $author)
                        Text("朝代").foregroundStyle(.secondary)
                        TextField("可空", text: $dynasty).frame(width: 80)
                    }
                }
            }
            .textFieldStyle(.roundedBorder)
            Text("正文（一行一句或一联，空行分段）").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 16, design: .serif))
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                .accessibilityIdentifier("pasteBody")
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("开始读") {
                    if let poem = model.createMarkedPoem(title: title, author: author, dynasty: dynasty, text: text) {
                        onCreate(poem)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(TextSegmenter.hanOnly(text).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// 按诗句在语料中查找一首来读。
struct CorpusPoemSearchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onOpen: (MarkedPoem) -> Void

    @State private var query = ""
    @State private var results: [CorpusLine] = []
    @State private var searched = ""
    @State private var isSearching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("从语料查找").font(.headline)
            HStack {
                TextField("输入诗中的几个字或一句", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                    .accessibilityIdentifier("readingSearchField")
                Button("查找") { Task { await search() } }
                    .disabled(TextSegmenter.hanOnly(query).count < 2 || isSearching)
            }
            Text("按诗句查找，繁简不论，至少两个字。").font(.caption).foregroundStyle(.secondary)
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !searched.isEmpty, results.isEmpty {
                Text("语料中没有找到含「\(searched)」的诗句。").foregroundStyle(.secondary)
            }
            List(results) { line in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text).font(.system(.body, design: .serif))
                        Text(line.sourceSummary + " · " + line.packName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("读这首") {
                        Task {
                            if let poem = await model.openMarkedPoem(corpusWorkID: line.workID) {
                                onOpen(poem)
                                dismiss()
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .listStyle(.inset)
            HStack {
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private func search() async {
        let text = TextSegmenter.hanOnly(query)
        guard text.count >= 2 else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await model.service.corpus.usages(of: text, limit: 100)
            searched = text
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}
