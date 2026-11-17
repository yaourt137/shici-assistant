import PoetryCore
import SwiftUI

@main
struct ShiCiApp: App {
    @State private var model: AppModel?
    @State private var launchError: String?

    init() {
        do {
            _model = State(initialValue: try AppModel(paths: AppPaths.resolve()))
        } catch {
            _launchError = State(initialValue: String(describing: error))
        }
    }

    var body: some Scene {
        WindowGroup("诗词助手") {
            if let model {
                ContentView()
                    .environment(model)
                    .frame(minWidth: MainWindowSize.minimumSize.width, minHeight: MainWindowSize.minimumSize.height)
                    .background(WindowFrameAutosave(name: MainWindowSize.autosaveName))
            } else {
                ContentUnavailableView("无法打开数据目录", systemImage: "exclamationmark.triangle",
                                       description: Text(launchError ?? "未知错误"))
                    .frame(minWidth: 480, minHeight: 320)
            }
        }
        .defaultSize(MainWindowSize.defaultSize)
        .commands {
            if let model {
                AppCommands(model: model)
            }
        }

        Settings {
            if let model {
                SettingsView()
                    .environment(model)
            }
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新建作品") { model.newPoem() }
                .keyboardShortcut("n")
        }
        CommandMenu("资料库") {
            Button("刷新") { model.reload() }
                .keyboardShortcut("r")
            Divider()
            Button("全部收藏") { model.selection = .allPhrases }
                .keyboardShortcut("1")
            Button("韵书") { model.selection = .rhymeBook }
                .keyboardShortcut("2")
            Button("语料包") { model.selection = .packs }
                .keyboardShortcut("3")
        }
    }
}
