import PoetryCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @State private var renamingTag: String?
    @State private var renameText = ""
    @State private var editingCollection: SmartCollection?

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Section("作品") {
                ForEach(model.poems) { poem in
                    Label(poem.displayTitle, systemImage: "doc.text")
                        .tag(SidebarItem.poem(poem.id))
                        .contextMenu {
                            Button("删除作品", role: .destructive) { model.deletePoem(poem.id) }
                        }
                }
                Button {
                    model.newPoem()
                } label: {
                    Label("新建作品", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("newPoemButton")
            }

            Section("收藏") {
                Label("全部收藏", systemImage: "tray.full")
                    .badge(model.phrases.filter { $0.status == .accepted }.count)
                    .tag(SidebarItem.allPhrases)
                    .accessibilityIdentifier("sidebarAllPhrases")
                Label("收件箱", systemImage: "tray.and.arrow.down")
                    .badge(model.inboxCount)
                    .tag(SidebarItem.inbox)
            }

            Section("智能收藏夹") {
                ForEach(model.smartCollections) { collection in
                    Label(collection.name, systemImage: "gearshape")
                        .tag(SidebarItem.smart(collection.id))
                        .help(collection.query)
                        .contextMenu {
                            Button("编辑…") { editingCollection = collection }
                            Button("删除", role: .destructive) { model.deleteSmartCollection(collection.id) }
                        }
                }
                Button {
                    editingCollection = SmartCollection(name: "", query: "")
                } label: {
                    Label("新建智能收藏夹", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            Section("标签") {
                OutlineGroup(TagTreeNode.build(model.tags), children: \.children) { node in
                    Label(node.name, systemImage: "tag")
                        .badge(model.tagUsage[node.id] ?? 0)
                        .tag(SidebarItem.tag(node.id))
                        .contextMenu {
                            Button("重命名…") {
                                renameText = node.id
                                renamingTag = node.id
                            }
                            Button("删除标签", role: .destructive) { model.deleteTag(node.id) }
                        }
                }
            }

            Section("工具") {
                Label("韵书", systemImage: "character.book.closed")
                    .tag(SidebarItem.rhymeBook)
                    .accessibilityIdentifier("sidebarRhymeBook")
                Label("艺文类聚", systemImage: "books.vertical.circle")
                    .tag(SidebarItem.leiju)
                Label("对仗训练", systemImage: "rectangle.split.2x1")
                    .badge(Text("Beta"))
                    .tag(SidebarItem.drill)
                    .accessibilityIdentifier("sidebarDrill")
                Label("语料包", systemImage: "books.vertical")
                    .tag(SidebarItem.packs)
            }
        }
        .alert("重命名标签", isPresented: Binding(get: { renamingTag != nil }, set: { if !$0 { renamingTag = nil } })) {
            TextField("新路径（可用 / 分级）", text: $renameText)
            Button("重命名") {
                if let old = renamingTag { model.renameTag(old, to: renameText) }
                renamingTag = nil
            }
            Button("取消", role: .cancel) { renamingTag = nil }
        } message: {
            Text("下级标签会一并改名；与已有标签同名时合并。")
        }
        .sheet(item: $editingCollection) { collection in
            SmartCollectionEditor(collection: collection)
        }
    }
}

struct SmartCollectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var collection: SmartCollection

    private var parseError: String? {
        do {
            _ = try PhraseFilterParser.parse(collection.query)
            return nil
        } catch {
            return error.message
        }
    }

    private var matchCount: Int {
        guard let filter = try? PhraseFilterParser.parse(collection.query) else { return 0 }
        return model.phrases.filter(filter.matches).count
    }

    var body: some View {
        Form {
            TextField("名称", text: $collection.name)
            TextField("条件", text: $collection.query, prompt: Text("例如：季节/秋 月|雁 -来源:agent"))
            if let parseError {
                Text(parseError).foregroundStyle(.red).font(.callout)
            } else {
                Text("当前匹配 \(matchCount) 条").foregroundStyle(.secondary).font(.callout)
            }
            Text(FilterHelp.text).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    model.save(collection)
                    dismiss()
                }
                .disabled(parseError != nil || collection.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

enum FilterHelp {
    static let text = "空格表示「且」，| 表示「或」，前缀 - 表示「非」。标签可写层级（季节/秋）或任一层名（秋）。分面：字数:5、类型:句、来源:摘录、状态:收件箱、含:月。"
}
