import XCTest

/// 每个用例使用独立的临时数据目录，不触碰真实资料库。
@MainActor
final class ShiCiUITests: XCTestCase {
    private var dataDirectory: URL!
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("shici-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchArguments = ["-ShiCiDataDirectory", dataDirectory.path]
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    private func createPoem(_ text: String) {
        app.buttons["newPoemButton"].click()
        let body = app.textViews["poemBody"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        body.click()
        body.typeText(text)
    }

    func testRegulatedPoemIsAnalyzed() {
        createPoem("白日依山尽，黄河入海流。欲穷千里目，更上一层楼。")
        XCTAssertTrue(app.staticTexts["formName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["formName"].value as? String ?? app.staticTexts["formName"].label, "五绝")
        XCTAssertTrue(app.descendants(matching: .any)["cell-3-4"].exists, "第四句第五字应出现在网格中")
    }

    func testToneErrorIsReported() {
        createPoem("白日依山尽，黄河入海东。欲穷千里目，更上一层楼。")
        let issues = app.descendants(matching: .any)["issueList"]
        XCTAssertTrue(issues.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "出韵")).firstMatch.waitForExistence(timeout: 5))
    }

    func testSelectingCellShowsConstraintAndCollectionCandidate() {
        // 先收藏一个平平仄的三字词，再在仄仄平平仄句尾选三字，应出现在候选中。
        app.buttons["sidebarAllPhrases"].firstMatch.click()
        app.buttons["newPhraseButton"].firstMatch.click()
        let text = app.textFields["phraseText"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.click()
        text.typeText("春山远")
        app.buttons["savePhraseSheet"].click()

        createPoem("白日依山尽，黄河入海流。欲穷千里目，更上一层楼。")
        let cell = app.descendants(matching: .any)["cell-0-2"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.click()
        XCUIElement.perform(withKeyModifiers: .shift) {
            app.descendants(matching: .any)["cell-0-4"].click()
        }
        XCTAssertTrue(app.staticTexts["constraintDescription"].waitForExistence(timeout: 5))
        let candidate = app.staticTexts["春山远"]
        XCTAssertTrue(candidate.waitForExistence(timeout: 5), "收藏的「春山远」应作为候选出现")
    }

    func testCollectSelectionAddsPhraseWithTag() {
        createPoem("白日依山尽，黄河入海流。")
        app.descendants(matching: .any)["cell-1-0"].click()
        XCUIElement.perform(withKeyModifiers: .shift) {
            app.descendants(matching: .any)["cell-1-1"].click()
        }
        app.buttons["collectSelection"].click()
        let tagInput = app.textFields["tagInput"]
        XCTAssertTrue(tagInput.waitForExistence(timeout: 5))
        tagInput.click()
        tagInput.typeText("地理/河\r")
        app.buttons["savePhraseSheet"].click()

        app.buttons["sidebarAllPhrases"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["黄河"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["地理/河"].waitForExistence(timeout: 5))
    }

    func testClassicsTabShowsPrimerCouplet() {
        createPoem("白日依山尽，黄河入海流。")
        let cell = app.descendants(matching: .any)["cell-0-3"]
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.click()
        app.radioButtons["典籍"].click()
        XCTAssertTrue(app.descendants(matching: .any)["classicsPanel"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["水"].waitForExistence(timeout: 5), "声律启蒙「山對水」")
        XCTAssertTrue(app.staticTexts["尚未下载佩文韵府。"].exists)
    }

    func testRhymeBookShowsPrimerSection() {
        app.descendants(matching: .any)["sidebarRhymeBook"].firstMatch.click()
        let mode = app.radioButtons["声律启蒙"]
        XCTAssertTrue(mode.waitForExistence(timeout: 5))
        mode.click()
        XCTAssertTrue(app.staticTexts["卷上 · 一、東"].waitForExistence(timeout: 5))
    }

    func testFilterExpressionErrorIsShown() {
        app.buttons["sidebarAllPhrases"].firstMatch.click()
        let filter = app.textFields["filterField"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        filter.click()
        filter.typeText("月|")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "两侧都需要条件")).firstMatch.waitForExistence(timeout: 5))
    }
}
