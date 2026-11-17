import AppKit
import PoetryCore
import SwiftUI

struct PackManagerView: View {
    @Environment(AppModel.self) private var model
    @State private var showingImporter = false
    @State private var pendingRemoval: PackInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.packs.isEmpty {
                ContentUnavailableView {
                    Label("尚未导入语料", systemImage: "books.vertical")
                } description: {
                    Text("语料用于替换候选、前人用例、相关诗句与出处反查。可一键下载 chinese-poetry（MIT 许可）的唐诗约 5.7 万首与宋词约 2.1 万首（下载约 34MB，索引约 200MB）。")
                } actions: {
                    Button("下载并导入唐诗、宋词") { Task { await model.downloadPublicCorpus() } }
                        .disabled(model.importStatus != nil)
                        .accessibilityIdentifier("downloadCorpus")
                }
            } else {
                Table(model.packs) {
                    TableColumn("启用") { pack in
                        Toggle("", isOn: Binding(get: { pack.isEnabled },
                                                 set: { value in Task { await model.setPackEnabled(value, id: pack.id) } }))
                            .labelsHidden()
                    }
                    .width(36)
                    TableColumn("名称") { Text($0.name) }
                    TableColumn("时代") { Text($0.era ?? "—") }.width(40)
                    TableColumn("作品") { Text("\($0.workCount)").monospacedDigit() }.width(60)
                    TableColumn("句") { Text("\($0.lineCount)").monospacedDigit() }.width(70)
                    TableColumn("许可") { Text($0.license ?? "—").foregroundStyle(.secondary) }
                    TableColumn("") { pack in
                        Button("删除") { pendingRemoval = pack }.controlSize(.small)
                    }
                    .width(50)
                }
            }

            GroupBox("扩展语料包格式") {
                Text("""
                一个文件夹，内含 manifest.json 与若干 .json（作品数组）或 .jsonl（每行一篇）文件。
                manifest 字段：formatVersion（1）、kind（corpus）、id、name、version、era、script（traditional/simplified/mixed）、license、source、files、fieldMapping。
                作品标准字段：title、author、dynasty、form、tune、preface、lines（字符串数组）、tags、notes；字段名不同时用 fieldMapping 映射，如 {"lines": "paragraphs"}。
                lines 中括号（）()〔〕[]【】内的文字视为校注：不计入句、不作候选，查看全文时仍保留。
                放入数据目录的 Packs 文件夹后，下次启动会自动导入；或点击「安装语料包…」。
                """)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .navigationTitle("语料包")
        .toolbar {
            ToolbarItemGroup {
                Button("安装语料包…") { showingImporter = true }
                    .disabled(model.importStatus != nil)
                Button("导入新放入的语料包") { Task { await model.importPendingPacks() } }
                    .disabled(model.importStatus != nil)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.service.paths.packs]) }
            }
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                Task { await model.installPack(from: url) }
            case .failure(let error):
                model.errorMessage = String(describing: error)
            }
        }
        .confirmationDialog("删除语料包「\(pendingRemoval?.name ?? "")」？", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
            Button("删除索引与文件", role: .destructive) {
                if let pack = pendingRemoval { Task { await model.removePack(pack.id) } }
                pendingRemoval = nil
            }
        } message: {
            Text("收藏不受影响；之后可重新安装。")
        }
        .task { await model.refreshPacks() }
    }
}
