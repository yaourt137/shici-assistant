import Foundation
@testable import PoetryCore

/// 测试用临时目录，析构时删除。
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("shici-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func write(_ text: String, to name: String) throws {
        let file = url.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: file, atomically: true, encoding: .utf8)
    }
}

enum Fixtures {
    /// 一个小型语料包：一个 JSON 文件（chinese-poetry 字段名）与一个 JSONL 文件（标准字段名）。
    static func makePack(in directory: TemporaryDirectory, id: String = "test-pack", version: String = "1") throws -> URL {
        let pack = directory.url.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        let manifest = """
        {"formatVersion":1,"kind":"corpus","id":"\(id)","name":"测试语料","version":"\(version)","era":"唐","script":"mixed",
         "files":["tang.json","extra.jsonl"],"fieldMapping":{"lines":"paragraphs"}}
        """
        try manifest.write(to: pack.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        let tang = """
        [
          {"author":"王之渙","title":"登鸛雀樓","paragraphs":["白日依山盡，黃河入海流。","欲窮千里目，更上一層樓。"]},
          {"author":"李白","title":"靜夜思","paragraphs":["床前明月光，疑是地上霜。","舉頭望明月，低頭思故鄉。"]},
          {"author":"佚名","title":"无正文"},
          {"author":"杜甫","title":"春望","paragraphs":["國破山河在，城春草木深。"]}
        ]
        """
        try tang.write(to: pack.appendingPathComponent("tang.json"), atomically: true, encoding: .utf8)
        let extra = """
        {"title":"测试","author":"某","paragraphs":["明月松间照，清泉石上流。"]}
        not json

        {"title":"无字","paragraphs":["，。"]}
        """
        try extra.write(to: pack.appendingPathComponent("extra.jsonl"), atomically: true, encoding: .utf8)
        return pack
    }
}
