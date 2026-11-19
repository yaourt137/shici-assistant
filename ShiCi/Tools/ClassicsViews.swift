import AppKit
import PoetryCore
import SwiftUI

/// 语料包页面中的典籍：声律启蒙（内置）与可下载的佩文韵府、艺文类聚。
struct ClassicsPackSection: View {
    @Environment(AppModel.self) private var model
    @State private var pendingRemoval: ClassicWork?

    var body: some View {
        GroupBox("典籍") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("声律启蒙").frame(width: 72, alignment: .leading)
                    Text("内置。按平水韵三十个平声韵分节，在「韵书」中查看；编辑时可查对仗。")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                ForEach(ClassicWork.allCases) { work in
                    HStack(alignment: .firstTextBaseline) {
                        Text(work.name).frame(width: 72, alignment: .leading)
                        if let info = model.classicInfo(work) {
                            Text("已导入 \(info.entryCount) 条").monospacedDigit()
                            Spacer()
                            Button("删除") { pendingRemoval = work }.controlSize(.small)
                        } else {
                            Text(work.summary).foregroundStyle(.secondary)
                            Spacer()
                            Button("下载并导入") { Task { await model.downloadClassic(work) } }
                                .controlSize(.small)
                                .disabled(model.importStatus != nil)
                                .accessibilityIdentifier("downloadClassic-\(work.rawValue)")
                        }
                    }
                }
                Text("佩文韵府、艺文类聚的文本来自漢リポ（Kanseki Repository）的四库全书本，许可为 \(ClassicWork.license)。原文无标点，个别字为缺字（显示为〓）；条目切分按原书版式推断，个别可能有误。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("删除《\(pendingRemoval?.name ?? "")》？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("删除索引与文本", role: .destructive) {
                if let work = pendingRemoval { Task { await model.removeClassic(work) } }
                pendingRemoval = nil
            }
        } message: {
            Text("之后可重新下载。")
        }
    }
}

/// 典籍原文的显示方式：原书字形或简体。
enum ClassicScript {
    static let storageKey = "classicsShowSimplified"
}

/// 一个字在佩文韵府中的各条：字头注、韵藻（可按字数筛选）、对语、摘句。
struct YunfuCharacterView: View {
    @Environment(AppModel.self) private var model
    let character: Character

    @AppStorage(ClassicScript.storageKey) private var showSimplified = false
    @State private var entries: [YunfuEntry] = []
    @State private var length = 0
    @State private var isLoading = false
    @State private var viewing: YunfuEntry?

    private var isInstalled: Bool { model.classicInfo(.peiwenYunfu) != nil }

    private func display(_ text: String) -> String {
        showSimplified ? model.dictionary.converter.simplified(text) : text
    }

    private var lengths: [Int] {
        Array(Set(entries.filter { $0.kind == .yunzao || $0.kind == .zeng }.map { TextSegmenter.hanOnly($0.phrase).count })).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("佩文韵府「\(String(character))」").font(.headline)
                Spacer()
                Toggle("简体", isOn: $showSimplified).toggleStyle(.checkbox)
            }
            if !isInstalled {
                Text("尚未下载佩文韵府。").foregroundStyle(.secondary)
                Button("前往语料包") { model.selection = .packs }.controlSize(.small)
            } else if isLoading {
                ProgressView().controlSize(.small)
            } else if entries.isEmpty {
                Text("佩文韵府未收此字为韵字。").foregroundStyle(.secondary)
            } else {
                Picker("字数", selection: $length) {
                    Text("全部").tag(0)
                    ForEach(lengths, id: \.self) { Text("\($0) 字").tag($0) }
                }
                .pickerStyle(.segmented)
                List {
                    ForEach(sections, id: \.title) { section in
                        Section(section.title) {
                            ForEach(Array(section.entries.enumerated()), id: \.offset) { _, entry in
                                YunfuEntryRow(entry: entry, display: display, onOpen: { viewing = entry })
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .task(id: "\(character)|\(isInstalled)") { await load() }
        .yunfuEntrySheet($viewing)
    }

    private struct EntrySection {
        let title: String
        let entries: [YunfuEntry]
    }

    private var sections: [EntrySection] {
        let groupName = { (id: Int) in model.dictionary.groups.indices.contains(id) ? model.dictionary.groups[id].displayName : "" }
        var result: [EntrySection] = []
        for groupID in entries.map(\.groupID).reduce(into: [Int](), { if !$0.contains($1) { $0.append($1) } }) {
            let inGroup = entries.filter { $0.groupID == groupID }
            for kind in YunfuEntryKind.allCases {
                var items = inGroup.filter { $0.kind == kind }
                if length > 0, kind == .yunzao || kind == .zeng {
                    items = items.filter { TextSegmenter.hanOnly($0.phrase).count == length }
                }
                if !items.isEmpty { result.append(EntrySection(title: "\(groupName(groupID)) · \(kind.displayName)", entries: items)) }
            }
        }
        return result
    }

    private func load() async {
        guard isInstalled else {
            entries = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await model.service.classics.yunfuEntries(head: character)
            if !lengths.contains(length) { length = 0 }
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

struct YunfuEntryRow: View {
    let entry: YunfuEntry
    let display: (String) -> String
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            switch entry.kind {
            case .duiyu:
                Text("\(display(entry.counterpart ?? "")) — \(display(entry.phrase))").font(.system(.body, design: .serif))
            case .gloss:
                Text(display(entry.note)).font(.callout)
            default:
                Text(display(entry.phrase)).font(.system(.body, design: .serif))
                if !entry.note.isEmpty {
                    Text(display(entry.note)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        .help(entry.rawNote == entry.note ? entry.note : "原文：\(entry.rawNote)")
                }
            }
        }
        // 行内文字可被截断，双击或右键在详情中查看全文并选取文字。
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("查看全文", action: onOpen)
        }
    }
}

extension View {
    /// 以 `entry` 是否为 nil 控制佩文条目详情的显示；给出 `onReplace` 时详情中带「替换」。
    func yunfuEntrySheet(_ entry: Binding<YunfuEntry?>, onReplace: ((YunfuEntry) -> Void)? = nil) -> some View {
        sheet(isPresented: Binding(get: { entry.wrappedValue != nil }, set: { if !$0 { entry.wrappedValue = nil } })) {
            if let current = entry.wrappedValue {
                YunfuEntrySheet(entry: current, onReplace: onReplace.map { action in { action(current) } })
            }
        }
    }
}

/// 佩文韵府一条的详情：完整注文、含「丨」的原文与出处位置；在编辑器中打开时可替换。
struct YunfuEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: YunfuEntry
    let onReplace: (() -> Void)?

    @AppStorage(ClassicScript.storageKey) private var showSimplified = false

    private func display(_ text: String) -> String {
        showSimplified ? model.dictionary.converter.simplified(text) : text
    }

    private var location: String {
        let groups = model.dictionary.groups
        let group = groups.indices.contains(entry.groupID) ? groups[entry.groupID].displayName : ""
        return ["佩文韵府", entry.juan, group, "韵字「\(display(entry.head))」", entry.kind.displayName]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var hasMissingCharacters: Bool {
        (entry.phrase + entry.rawNote + (entry.counterpart ?? "")).contains { $0 == "□" || $0 == "〓" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(entry.kind == .duiyu ? "\(display(entry.counterpart ?? "")) — \(display(entry.phrase))" : display(entry.phrase))
                .font(.system(.title2, design: .serif))
                .textSelection(.enabled)
            Text(location).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !entry.note.isEmpty {
                        Text(display(entry.note))
                            .font(.system(size: 17, design: .serif))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                    }
                    if entry.rawNote != entry.note {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("原文（「丨」代本条词语）").font(.caption).foregroundStyle(.secondary)
                            Text(display(entry.rawNote))
                                .font(.system(size: 14, design: .serif))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if hasMissingCharacters {
                        Text("「□」「〓」为底本缺字或无法录入的字。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Toggle("简体", isOn: $showSimplified)
                Spacer()
                Button("拷贝") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(display(entry.phrase))：\(display(entry.note))（\(location)）", forType: .string)
                }
                if let onReplace {
                    Button("替换") {
                        onReplace()
                        dismiss()
                    }
                }
                Button("关闭") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .toggleStyle(.checkbox)
        }
        .padding(20)
        .frame(width: 560, height: 420)
        .accessibilityIdentifier("yunfuEntrySheet")
    }
}

/// 《声律启蒙》一节：韵脚高亮，不属本韵的韵脚标出实际韵目，所选字加底色。
struct ShengLvSectionView: View {
    @Environment(AppModel.self) private var model
    let sections: [ShengLvQiMeng.Section]
    let highlighted: Character?

    @AppStorage(ClassicScript.storageKey) private var showSimplified = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("车万育《声律启蒙》，文本取自维基文库。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("简体", isOn: $showSimplified).toggleStyle(.checkbox)
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(section.index < 15 ? "卷上" : "卷下") · \(section.title)").font(.headline)
                        ForEach(Array(section.stanzas.enumerated()), id: \.offset) { _, stanza in
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(stanza.enumerated()), id: \.offset) { _, line in
                                    Text(attributed(line, groupID: section.groupID))
                                        .font(.system(size: 16, design: .serif))
                                        .textSelection(.enabled)
                                        .help(line.variant.map { "一作：\($0)" } ?? "")
                                }
                            }
                        }
                        let notes = mismatchNotes(section)
                        if !notes.isEmpty {
                            Text("韵脚不属本韵：" + notes.joined(separator: "；"))
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func isOwnGroup(_ character: Character, _ groupID: Int) -> Bool {
        model.dictionary.pingshuiGroupIDs(of: character).contains(groupID)
    }

    private func attributed(_ line: ShengLvQiMeng.Line, groupID: Int) -> AttributedString {
        let converter = model.dictionary.converter
        let target = highlighted.map(converter.simplified)
        let rhymes = Set(line.rhymeOffsets)
        var result = AttributedString()
        for (offset, character) in line.text.enumerated() {
            var piece = AttributedString(String(showSimplified ? converter.simplified(character) : character))
            if rhymes.contains(offset) {
                piece.foregroundColor = isOwnGroup(character, groupID) ? .accentColor : .orange
                piece.font = .system(size: 16, weight: .semibold, design: .serif)
            }
            if let target, converter.simplified(character) == target {
                piece.backgroundColor = .yellow.opacity(0.35)
            }
            result += piece
        }
        if line.variant != nil { result += AttributedString(" ＊") }
        return result
    }

    private func mismatchNotes(_ section: ShengLvQiMeng.Section) -> [String] {
        model.service.shengLv.rhymeMismatches(dictionary: model.dictionary)
            .filter { $0.sectionIndex == section.index }
            .map { mismatch in
                let groups = mismatch.actualGroupIDs.map { model.dictionary.groups[$0].displayName }
                return "「\(mismatch.character)」" + (groups.isEmpty ? "韵表未收" : "属\(groups.joined(separator: "、"))")
            }
    }
}
