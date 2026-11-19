import AppKit
import PoetryCore
import SwiftUI

/// 编辑器的「典籍」页：所选词在《声律启蒙》与佩文韵府对语中的对仗，以及合乎此位置格律的佩文韵藻。
struct ClassicsPanel: View {
    @Environment(AppModel.self) private var model
    let constraint: SlotConstraint?
    let currentText: String
    let onReplace: (String) -> Void

    @State private var couplets: [CoupletSuggestion] = []
    @State private var yunzao: [YunfuEntry] = []
    @State private var isLoading = false
    @State private var viewing: YunfuEntry?

    private var hasYunfu: Bool { model.classicInfo(.peiwenYunfu) != nil }

    private struct LoadKey: Hashable {
        let constraint: SlotConstraint?
        let text: String
        let hasYunfu: Bool
    }

    var body: some View {
        List {
            Section("对仗：与「\(currentText)」相对") {
                if couplets.isEmpty {
                    Text(hasYunfu ? "声律启蒙与佩文对语中未见" : "声律启蒙中未见（下载佩文韵府后另查其对语）").foregroundStyle(.secondary)
                }
                ForEach(Array(couplets.enumerated()), id: \.offset) { _, suggestion in
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.dictionary.converter.simplified(suggestion.counterpart)).font(.system(size: 17, design: .serif))
                        Text(describe(suggestion.source)).font(.caption).foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
            Section(yunzaoTitle) {
                if !hasYunfu {
                    HStack {
                        Text("尚未下载佩文韵府。").foregroundStyle(.secondary)
                        Button("前往语料包") { model.selection = .packs }.controlSize(.small)
                    }
                } else if constraint == nil {
                    Text("无法生成约束").foregroundStyle(.secondary)
                } else if !isLoading, yunzao.isEmpty {
                    Text("没有合乎此位置平仄的韵藻").foregroundStyle(.secondary)
                }
                ForEach(Array(yunzao.enumerated()), id: \.offset) { _, entry in
                    YunzaoRow(entry: entry, onReplace: { replace(with: entry) }, onOpen: { viewing = entry })
                }
            }
        }
        .listStyle(.inset)
        .overlay(alignment: .top) {
            if isLoading { ProgressView().controlSize(.small).padding(.top, 4) }
        }
        .task(id: LoadKey(constraint: constraint, text: currentText, hasYunfu: hasYunfu)) { await load() }
        .yunfuEntrySheet($viewing) { replace(with: $0) }
        .accessibilityIdentifier("classicsPanel")
    }

    private func replace(with entry: YunfuEntry) {
        onReplace(model.dictionary.converter.simplified(entry.phrase))
    }

    private var yunzaoTitle: String {
        guard let constraint else { return "佩文韵藻" }
        var title = "佩文韵藻：\(constraint.patternText)"
        if let rhyme = constraint.rhyme {
            title += " · 押\(model.dictionary.displayName(of: rhyme.key))"
        } else if let last = TextSegmenter.hanOnly(currentText).last {
            title += " · 以「\(last)」结尾"
        }
        return title
    }

    private func describe(_ source: CoupletSuggestion.Source) -> String {
        switch source {
        case .shengLv(let index):
            let sections = model.service.shengLv.sections
            return "声律启蒙 · " + (sections.indices.contains(index) ? sections[index].title : "")
        case .yunfu(let head, let groupID):
            let groups = model.dictionary.groups
            return "佩文对语 · \(head)" + (groups.indices.contains(groupID) ? "（\(groups[groupID].displayName)）" : "")
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            couplets = try await model.service.couplets(matching: currentText)
            if hasYunfu, let constraint, let last = TextSegmenter.hanOnly(currentText).last {
                yunzao = try await model.service.yunzaoCandidates(for: constraint, lastCharacter: last)
            } else {
                yunzao = []
            }
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}

struct YunzaoRow: View {
    @Environment(AppModel.self) private var model
    let entry: YunfuEntry
    let onReplace: () -> Void
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.dictionary.converter.simplified(entry.phrase)).font(.system(size: 17, design: .serif))
                    if entry.kind != .yunzao {
                        Text(entry.kind.displayName).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if !entry.note.isEmpty {
                    Text(entry.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .help(entry.rawNote == entry.note ? entry.note : "原文：\(entry.rawNote)")
                }
            }
            Spacer()
            Button("替换", action: onReplace).controlSize(.small)
        }
        .contentShape(Rectangle())
        // 与前人用例一致：双击查看全文，替换用按钮或右键菜单。
        .onTapGesture(count: 2, perform: onOpen)
        .contextMenu {
            Button("查看全文", action: onOpen)
            Button("替换", action: onReplace)
            Button("拷贝出处") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(entry.phrase)：\(entry.note)", forType: .string)
            }
        }
    }
}

/// 字音页中佩文韵府对该字的反切与释义（未下载或未收时不显示）。
struct YunfuGlossRows: View {
    @Environment(AppModel.self) private var model
    let character: Character

    @State private var glosses: [YunfuEntry] = []

    var body: some View {
        ForEach(Array(glosses.enumerated()), id: \.offset) { _, entry in
            HStack(alignment: .firstTextBaseline) {
                Text("佩文韵府").foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Text("\(model.dictionary.groups.indices.contains(entry.groupID) ? model.dictionary.groups[entry.groupID].displayName : "")　\(entry.note)")
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(entry.note)
            }
        }
        .task(id: "\(character)|\(model.classicInfo(.peiwenYunfu)?.importedAt.timeIntervalSince1970 ?? 0)") { await load() }
    }

    private func load() async {
        guard model.classicInfo(.peiwenYunfu) != nil else {
            glosses = []
            return
        }
        do {
            glosses = try await model.service.classics.yunfuEntries(head: character, kinds: [.gloss])
        } catch {
            model.errorMessage = String(describing: error)
        }
    }
}
