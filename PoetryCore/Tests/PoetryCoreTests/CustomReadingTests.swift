import Foundation
import Testing
@testable import PoetryCore

@Suite("自定义读音")
struct CustomReadingTests {
    private let base = CharDictionary.shared

    private func groupID(_ name: String) throws -> Int {
        try #require(base.groups.first { $0.displayName == name }).id
    }

    // MARK: - 词典

    @Test("补充平水韵读音：平水韵、词林正韵随之变化，通韵不变，原词典不受影响")
    func supplement() throws {
        let zhi = try groupID("上声·四纸")
        #expect(base.tones(of: "伎", in: .pingshui) == [.ping], "数据源只收支韵")
        let dictionary = base.supplemented(with: [CustomReading(character: "伎", groupID: zhi)])
        #expect(dictionary.pingshuiGroupIDs(of: "伎").contains(zhi))
        #expect(dictionary.tones(of: "伎", in: .pingshui) == [.ping, .ze])
        #expect(dictionary.tones(of: "伎", in: .cilin) == [.ping, .ze])
        #expect(dictionary.readings(of: "伎", in: .tongyun) == base.readings(of: "伎", in: .tongyun))
        #expect(base.tones(of: "伎", in: .pingshui) == [.ping])
        #expect(dictionary.tones(of: "技", in: .pingshui) == base.tones(of: "技", in: .pingshui), "其他字不受影响")
    }

    @Test("繁简体互通：按繁体补充，简体也能查到")
    func scriptVariants() throws {
        let zhi = try groupID("上声·四纸")
        let dictionary = base.supplemented(with: [CustomReading(character: "聽", groupID: zhi)])
        #expect(dictionary.pingshuiGroupIDs(of: "听").contains(zhi))
        #expect(dictionary.pingshuiGroupIDs(of: "聽").contains(zhi))
    }

    @Test("重复、越界与替换")
    func edgeCases() throws {
        let zhi = try groupID("上声·四纸")
        let baseCount = base.readings(of: "伎", in: .pingshui).count
        let duplicated = base.supplemented(with: [CustomReading(character: "伎", groupID: zhi),
                                                  CustomReading(character: "伎", groupID: zhi)])
        #expect(duplicated.readings(of: "伎", in: .pingshui).count == baseCount + 1)
        let outOfRange = base.supplemented(with: [CustomReading(character: "伎", groupID: -1),
                                                  CustomReading(character: "伎", groupID: base.groups.count)])
        #expect(outOfRange.readings(of: "伎", in: .pingshui).count == baseCount)
        #expect(duplicated.supplemented(with: []).readings(of: "伎", in: .pingshui).count == baseCount, "补充读音整体取代，不累加")
    }

    @Test("韵部字表包含补充的字")
    func rhymeBrowser() throws {
        let zhi = try groupID("上声·四纸")
        let key = RhymeKey(book: .pingshui, id: zhi)
        #expect(!base.characters(in: key).contains("伎"))
        #expect(base.supplemented(with: [CustomReading(character: "伎", groupID: zhi)]).characters(in: key).contains("伎"))
    }

    // MARK: - 存储

    @Test("增删与去重")
    func store() throws {
        let directory = try TemporaryDirectory()
        let store = try LibraryStore(url: directory.url.appendingPathComponent("library.sqlite"))
        #expect(try store.customReadings().isEmpty)
        let reading = CustomReading(character: "伎", groupID: try groupID("上声·四纸"))
        try store.save(reading)
        try store.save(CustomReading(character: "伎", groupID: reading.groupID))
        #expect(try store.customReadings().map(\.id) == [reading.id])
        try store.deleteCustomReading(reading)
        #expect(try store.customReadings().isEmpty)
        try store.deleteCustomReading(reading)
    }

    // MARK: - 服务

    @Test("添加后立即参与分析与读音指定，重启后仍在，删除后恢复")
    func service() throws {
        let directory = try TemporaryDirectory()
        let paths = AppPaths(root: directory.url.appendingPathComponent("data"))
        let zhi = try groupID("上声·四纸")
        let service = try PoetryService(paths: paths)
        #expect(service.analyze("伎", form: .free, book: .pingshui).lines[0].characters[0].tones == [.ping])

        let reading = try service.addCustomReading(" 伎\n", groupID: zhi)
        #expect(reading.character == "伎")
        #expect(service.analyze("伎", form: .free, book: .pingshui).lines[0].characters[0].tones == [.ping, .ze])
        let ze = try #require(service.dictionary.readings(of: "伎", in: .pingshui).first { $0.tone == .ze })
        let chosen = service.analyze("伎", form: .free, book: .pingshui,
                                     choices: [ReadingChoice(offset: 0, character: "伎", reading: ze)])
        #expect(chosen.lines[0].characters[0].tones == [.ze])

        let reopened = try PoetryService(paths: paths)
        #expect(reopened.dictionary.tones(of: "伎", in: .pingshui) == [.ping, .ze])

        try service.removeCustomReading(reading)
        #expect(service.dictionary.tones(of: "伎", in: .pingshui) == [.ping])
        #expect(service.analyze("伎", form: .free, book: .pingshui,
                                choices: [ReadingChoice(offset: 0, character: "伎", reading: ze)])
                    .lines[0].characters[0].chosenReading == nil, "删除后，基于它的指定失效")
    }

    @Test("拒绝非单个汉字、无效韵目和已收录的读音")
    func validation() throws {
        let directory = try TemporaryDirectory()
        let service = try PoetryService(paths: AppPaths(root: directory.url.appendingPathComponent("data")))
        let zhi = try groupID("上声·四纸")
        for text in ["", "  ", "伎技", "a", "，"] {
            #expect(throws: CustomReadingError.notSingleCharacter(text)) { try service.addCustomReading(text, groupID: zhi) }
        }
        #expect(throws: CustomReadingError.invalidGroup(-1)) { try service.addCustomReading("伎", groupID: -1) }
        #expect(throws: CustomReadingError.invalidGroup(106)) { try service.addCustomReading("伎", groupID: 106) }
        #expect(throws: CustomReadingError.alreadyListed(character: "技", group: "上声·四纸")) {
            try service.addCustomReading("技", groupID: zhi)
        }
        try service.addCustomReading("伎", groupID: zhi)
        #expect(throws: CustomReadingError.alreadyListed(character: "伎", group: "上声·四纸")) {
            try service.addCustomReading("伎", groupID: zhi)
        }
        #expect(try service.library.customReadings().count == 1)
    }
}
