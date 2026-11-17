import PoetryCore
import SwiftUI

struct RhymeBrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var book: RhymeBook = .pingshui
    @State private var key: RhymeKey?
    @State private var tone: Tone? = .ping
    @State private var frequencies: [Character: Int] = [:]

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
                    Text(frequencies.isEmpty ? "按韵书顺序排列（导入语料后按常用度排序）" : "按语料中的出现次数排序；悬停查看次数")
                        .font(.caption).foregroundStyle(.secondary)
                    if book == .cilin {
                        Text("词林正韵中「佳、灰、元」等韵目分属两部，这里按今音韵母近似拆分，个别字可能与原书不同。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 36), spacing: 6)], spacing: 6) {
                            ForEach(characters, id: \.self) { character in
                                Text(String(character))
                                    .font(.system(size: 22, design: .serif))
                                    .frame(width: 36, height: 36)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
                                    .help(help(for: character))
                                    .textSelection(.enabled)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("选择一个韵部", systemImage: "character.book.closed")
                }
            }
            .padding(16)
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("韵书")
        .toolbar {
            Picker("韵书", selection: $book) {
                ForEach(RhymeBook.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .onChange(of: book) { key = model.dictionary.allKeys(in: book).first }
        .task(id: model.packs.count) {
            do {
                frequencies = try await model.service.corpus.characterFrequencies()
            } catch {
                model.errorMessage = String(describing: error)
            }
        }
        .onAppear { if key == nil { key = model.dictionary.allKeys(in: book).first } }
    }

    private func help(for character: Character) -> String {
        let readings = model.dictionary.readings(of: character, in: book)
            .map { "\($0.tone.rawValue)·\(model.dictionary.displayName(of: $0.rhyme))" }
            .joined(separator: "，")
        return "\(readings)　语料 \(frequencies[character] ?? 0) 次"
    }
}
