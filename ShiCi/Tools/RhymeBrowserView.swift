import AppKit
import PoetryCore
import SwiftUI

struct RhymeBrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var book: RhymeBook = .pingshui
    @State private var key: RhymeKey?
    @State private var tone: Tone? = .ping
    @State private var frequencies: [Character: Int] = [:]
    @State private var mode: Mode = .characters
    @State private var selectedCharacter: Character?

    enum Mode: Hashable {
        case characters
        case primer(PrimerWork)
    }

    /// 当前韵部对应的对韵蒙书各节：平水韵平声一韵一节；词林正韵一部可含数节；中华通韵无。
    private func primerSections(_ work: PrimerWork) -> [RhymePrimer.Section] {
        guard let key else { return [] }
        let primer = model.service.primer(work)
        switch book {
        case .pingshui:
            return primer.section(forGroup: key.id).map { [$0] } ?? []
        case .cilin:
            return primer.sections.filter { section in
                model.dictionary.groups.indices.contains(section.groupID)
                    && CilinMapping.possibleSections(forGroupHead: model.dictionary.groups[section.groupID].headCharacter).contains(key.id)
            }
        case .tongyun:
            return []
        }
    }

    /// 有对应各节的对韵蒙书。
    private var availablePrimers: [PrimerWork] {
        PrimerWork.allCases.filter { !primerSections($0).isEmpty }
    }

    /// 在《声律启蒙》或《笠翁对韵》本韵中用作韵脚的字（简体）。
    private var primerRhymes: Set<Character> {
        PrimerWork.allCases.reduce(into: Set<Character>()) { result, work in
            let primer = model.service.primer(work)
            for section in primerSections(work) {
                result.formUnion(primer.rhymeCharacters(of: section, converter: model.dictionary.converter))
            }
        }
    }

    private var characters: [Character] {
        guard let key else { return [] }
        let toneFilter: Tone? = book == .pingshui ? nil : tone
        return model.dictionary.characters(in: key, tone: toneFilter)
            .sorted { (frequencies[$0] ?? 0) > (frequencies[$1] ?? 0) }
    }

    var body: some View {
        HSplitView {
            List(model.dictionary.allKeys(in: book), id: \.self, selection: $key) { key in
                Text(model.dictionary.displayName(of: key))
            }
            .frame(minWidth: 160, idealWidth: 180, maxWidth: 240)

            VStack(alignment: .leading, spacing: 12) {
                if let key {
                    HStack {
                        Text(model.dictionary.displayName(of: key)).font(.title2)
                        Text("\(characters.count) 字").foregroundStyle(.secondary)
                        Spacer()
                        if !availablePrimers.isEmpty {
                            Picker("", selection: $mode) {
                                Text("字表").tag(Mode.characters)
                                ForEach(availablePrimers) { Text($0.name).tag(Mode.primer($0)) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            .accessibilityIdentifier("rhymeBrowserMode")
                        }
                        if book != .pingshui {
                            Picker("声调", selection: $tone) {
                                Text("平声").tag(Tone?.some(.ping))
                                Text("仄声").tag(Tone?.some(.ze))
                                Text("全部").tag(Tone?.none)
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                    if case .primer(let work) = mode, !primerSections(work).isEmpty {
                        if book == .cilin, primerSections(work).count > 1 {
                            Text("词林正韵一部含平水韵数韵，依次列出；「佳、灰、元」等韵分属两部，在两部下都会列出。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        PrimerSectionView(primer: model.service.primer(work), sections: primerSections(work),
                                          highlighted: selectedCharacter)
                    } else {
                        characterGrid
                    }
                } else {
                    ContentUnavailableView("选择一个韵部", systemImage: "character.book.closed")
                }
            }
            .padding(16)
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            if let selectedCharacter {
                YunfuCharacterView(character: selectedCharacter)
                    .padding(12)
                    .frame(minWidth: 260, idealWidth: 320, maxWidth: 460, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .navigationTitle("韵书")
        .toolbar {
            Picker("韵书", selection: $book) {
                ForEach(RhymeBook.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .onChange(of: book) { key = model.dictionary.allKeys(in: book).first }
        .onChange(of: key) { selectedCharacter = nil }
        .task(id: model.packs.count) {
            do {
                frequencies = try await model.service.corpus.characterFrequencies()
            } catch {
                model.errorMessage = String(describing: error)
            }
        }
        .onAppear { if key == nil { key = model.dictionary.allKeys(in: book).first } }
    }

    @ViewBuilder
    private var characterGrid: some View {
        let rhymes = primerRhymes
        Text(frequencies.isEmpty ? "按韵书顺序排列（导入语料后按常用度排序）" : "按语料中的出现次数排序；悬停查看次数")
            .font(.caption).foregroundStyle(.secondary)
        if book == .cilin {
            Text("词林正韵中「佳、灰、元」等韵目分属两部，这里按今音韵母近似拆分，个别字可能与原书不同。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Text(rhymes.isEmpty ? "点选一个字，查看佩文韵府中的韵藻与对语。"
             : "点选一个字，查看佩文韵府中的韵藻与对语；带圆点的字在《声律启蒙》或《笠翁对韵》本韵中用作韵脚。")
            .font(.caption).foregroundStyle(.secondary)
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 6)], spacing: 6) {
                ForEach(characters, id: \.self) { character in
                    let isSelected = selectedCharacter == character
                    Text(String(character))
                        .font(.system(size: 22, design: .serif))
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? Color.accentColor.opacity(0.25) : Color(nsColor: .controlBackgroundColor)))
                        .overlay(alignment: .bottomTrailing) {
                            if rhymes.contains(model.dictionary.converter.simplified(character)) {
                                Circle().fill(Color.accentColor).frame(width: 5, height: 5).padding(3)
                            }
                        }
                        .help(help(for: character))
                        .contentShape(Rectangle())
                        .onTapGesture { selectedCharacter = isSelected ? nil : character }
                        .accessibilityAddTraits(.isButton)
                        // 点按用于选字，拷贝改由右键菜单提供。
                        .contextMenu {
                            Button("拷贝「\(String(character))」") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(String(character), forType: .string)
                            }
                        }
                }
            }
        }
    }

    private func help(for character: Character) -> String {
        let readings = model.dictionary.readings(of: character, in: book)
            .map { "\($0.tone.rawValue)·\(model.dictionary.displayName(of: $0.rhyme))" }
            .joined(separator: "，")
        return "\(readings)　语料 \(frequencies[character] ?? 0) 次"
    }
}
