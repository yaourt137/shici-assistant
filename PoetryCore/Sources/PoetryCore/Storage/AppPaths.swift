import Foundation
import notify

/// 数据目录约定。App 与 shici-mcp 共用同一目录：
/// - `library.sqlite`：作品、收藏、标签（用户数据）
/// - `corpus.sqlite`：语料索引（可由语料包重建）
/// - `Packs/`：已安装的语料包
/// - `classics.sqlite`：典籍索引（可由 `Classics/` 中的文本重建）
/// - `Classics/`：下载的典籍文本
public struct AppPaths: Sendable {
    public static let environmentKey = "SHICI_DATA_DIR"
    public static let launchArgument = "-ShiCiDataDirectory"

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 优先使用命令行参数，其次环境变量，最后为 `~/Library/Application Support/ShiCi`。
    public static func resolve(arguments: [String] = CommandLine.arguments,
                               environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let index = arguments.firstIndex(of: launchArgument), index + 1 < arguments.count {
            return AppPaths(root: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
        }
        if let path = environment[environmentKey], !path.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(root: support.appendingPathComponent("ShiCi", isDirectory: true))
    }

    public var library: URL { root.appendingPathComponent("library.sqlite") }
    public var corpus: URL { root.appendingPathComponent("corpus.sqlite") }
    public var packs: URL { root.appendingPathComponent("Packs", isDirectory: true) }
    public var classicsIndex: URL { root.appendingPathComponent("classics.sqlite") }
    public var classics: URL { root.appendingPathComponent("Classics", isDirectory: true) }

    public func createDirectories() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: packs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: classics, withIntermediateDirectories: true)
    }
}

/// 跨进程的「数据已变更」通知（shici-mcp 写入后通知 App 刷新）。
public enum LibraryChangeNotification {
    public static let name = "com.shici.library.changed"

    /// 返回是否发送成功；失败时由调用方记录（App 仍可在下次手动刷新时读到数据）。
    @discardableResult
    public static func post() -> Bool {
        notify_post(name) == NOTIFY_STATUS_OK
    }
}
