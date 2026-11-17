import Foundation
import PoetryCore

// shici-mcp：诗词助手的 MCP 服务（stdio）。数据目录与 App 相同，可用环境变量 SHICI_DATA_DIR 覆盖。
let paths = AppPaths.resolve()
let server: MCPServer
do {
    server = MCPServer(service: try PoetryService(paths: paths))
} catch {
    FileHandle.standardError.write(Data("shici-mcp: 无法打开数据目录 \(paths.root.path)：\(error)\n".utf8))
    exit(1)
}

while let line = readLine(strippingNewline: true) {
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    if let response = await server.handle(line: line) {
        FileHandle.standardOutput.write(Data((response + "\n").utf8))
    }
}
