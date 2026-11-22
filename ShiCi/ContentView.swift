import PoetryCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) { statusBanner }
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .task {
            await model.importPendingPacks()
            await model.importPendingClassics()
            if model.selection == nil {
                model.selection = model.poems.first.map { .poem($0.id) } ?? .allPhrases
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case .poem(let id):
            if model.poem(id) != nil {
                PoemEditorView(poemID: id)
                    .id(id)
            } else {
                ContentUnavailableView("作品已删除", systemImage: "doc")
            }
        case .allPhrases:
            PhraseLibraryView(scope: .all)
        case .inbox:
            PhraseLibraryView(scope: .inbox)
        case .tag(let path):
            PhraseLibraryView(scope: .tag(path))
                .id(path)
        case .smart(let id):
            if let collection = model.smartCollections.first(where: { $0.id == id }) {
                PhraseLibraryView(scope: .smart(collection))
                    .id(collection)
            } else {
                ContentUnavailableView("收藏夹已删除", systemImage: "folder")
            }
        case .rhymeBook:
            RhymeBrowserView()
        case .leiju:
            LeijuBrowserView()
        case .reading:
            ReadingHomeView()
        case .drill:
            DrillView()
        case .packs:
            PackManagerView()
        case nil:
            ContentUnavailableView("选择或新建一首作品", systemImage: "square.and.pencil")
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let status = model.importStatus {
            HStack(spacing: 12) {
                if let fraction = status.fraction {
                    ProgressView(value: fraction).frame(width: 160)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("\(status.title)：\(status.phase)")
                    .font(.callout)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
            .accessibilityIdentifier("importStatus")
        } else if let notice = model.notice {
            HStack(spacing: 8) {
                Text(notice).font(.callout)
                Button {
                    model.notice = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭提示")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 16)
            .accessibilityIdentifier("notice")
            .task(id: notice) {
                try? await Task.sleep(for: .seconds(6))
                if model.notice == notice { model.notice = nil }
            }
        }
    }
}
