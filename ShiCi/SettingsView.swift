import PoetryCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var windowWidth = Int(MainWindowSize.defaultSize.width)
    @State private var windowHeight = Int(MainWindowSize.defaultSize.height)
    @State private var isMainWindowOpen = true
    @State private var customCharacter = ""

    /// shici-mcp 由 `swift build -c release` 在 PoetryCore/.build 下生成（自用版不随 App 打包）。
    private var mcpBinaryPath: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PoetryCore/.build/release/shici-mcp")
            .path
    }

    var body: some View {
        Form {
            Section("Agent 与 MCP") {
                Toggle("agent 写入的收藏先进收件箱", isOn: Binding(
                    get: { model.agentWritesToInbox }, set: { model.setSetting(.agentWritesToInbox, $0) }))
                Toggle("MCP 只读模式（拒绝 agent 写入）", isOn: Binding(
                    get: { model.mcpReadOnly }, set: { model.setSetting(.mcpReadOnly, $0) }))
                VStack(alignment: .leading, spacing: 6) {
                    Text("在 Claude Code 中添加：").font(.callout)
                    Text("claude mcp add shici -- \"\(mcpBinaryPath)\"")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Text("首次使用前在 PoetryCore 目录执行 swift build -c release。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("窗口") {
                HStack {
                    TextField("宽", value: $windowWidth, format: .number.grouping(.never))
                        .frame(width: 120)
                        .accessibilityIdentifier("windowWidth")
                    Text("×")
                    TextField("高", value: $windowHeight, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 80)
                        .accessibilityIdentifier("windowHeight")
                    Spacer()
                    Button("应用") {
                        applyWindowSize(CGSize(width: windowWidth, height: windowHeight))
                    }
                    Button("恢复默认（\(Int(MainWindowSize.defaultSize.width)) × \(Int(MainWindowSize.defaultSize.height))）") {
                        applyWindowSize(MainWindowSize.defaultSize)
                    }
                }
                .disabled(!isMainWindowOpen)
                Text(isMainWindowOpen
                     ? "主窗口内容区大小。最小 \(Int(MainWindowSize.minimumSize.width)) × \(Int(MainWindowSize.minimumSize.height))，最大不超过屏幕；拖动窗口调整的大小同样会被记住，下次启动沿用。"
                     : "主窗口未打开。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("自定义读音") {
                ForEach(model.customReadings) { reading in
                    HStack {
                        Text("「\(reading.character)」").font(.system(.body, design: .serif))
                        Text(model.dictionary.groups.indices.contains(reading.groupID)
                             ? model.dictionary.groups[reading.groupID].displayName : "未知韵目")
                        Spacer()
                        Button("删除", role: .destructive) { model.removeCustomReading(reading) }
                    }
                }
                HStack {
                    TextField("字", text: $customCharacter)
                        .frame(width: 80)
                        .accessibilityIdentifier("customReadingCharacter")
                    PingshuiGroupMenu(title: "补充到平水韵韵目…", excluded: []) { groupID in
                        model.addCustomReading(customCharacter, groupID: groupID)
                    }
                    .fixedSize()
                    .disabled(customCharacter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text("补充韵书数据漏收的又读。词林正韵随平水韵换算；中华通韵依今音，不受影响。也可在编辑器「字音」页为所选字补充。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("数据") {
                LabeledContent("数据目录") {
                    Text(model.service.paths.root.path).textSelection(.enabled)
                }
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([model.service.paths.root]) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .onAppear(perform: loadWindowSize)
    }

    private func loadWindowSize() {
        guard let size = MainWindowSize.current() else {
            isMainWindowOpen = false
            return
        }
        isMainWindowOpen = true
        windowWidth = Int(size.width.rounded())
        windowHeight = Int(size.height.rounded())
    }

    private func applyWindowSize(_ size: CGSize) {
        guard let applied = MainWindowSize.apply(size) else {
            isMainWindowOpen = false
            return
        }
        windowWidth = Int(applied.width.rounded())
        windowHeight = Int(applied.height.rounded())
    }
}
