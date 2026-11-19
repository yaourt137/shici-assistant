import Foundation

/// 漢リポ（Kanseki Repository）文本的通用处理。
///
/// 文件格式：`#` 开头的元数据行（如 `#+PROPERTY: JUAN 卷一之一`）、`<pb:…>` 页码标记、行尾 `¶`；
/// 小字夹注写在括号内，双行小字以 `/` 分隔右、左两行；缺字写作 `&KR0001;` 形式的实体。
enum KanripoText {
    /// 缺字（无法用 Unicode 表示的字）的替代符号。
    static let missingCharacter: Character = "〓"

    /// 文件元数据，例如 `property("JUAN", in:)` 取「卷一之一」。
    static func property(_ name: String, in text: String) -> String? {
        let prefix = "#+PROPERTY: \(name) "
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix(prefix) {
            let value = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// 正文的物理行：去掉元数据行、页码标记与行尾 `¶`，缺字实体换成「〓」。
    /// 只含页码标记的行整行去掉；正文中的空行保留为空字符串。
    static func bodyLines(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if raw.hasPrefix("#") { continue }
            var line = String(raw)
            let hadPageMarker = line.contains("<pb:")
            line = line.replacingOccurrences(of: #"<pb:[^>]*>"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(of: "¶", with: "")
            line = replacingEntities(line)
            if hadPageMarker, line.allSatisfy(isSpace) { continue }
            lines.append(line)
        }
        return lines
    }

    static func replacingEntities(_ text: String) -> String {
        text.replacingOccurrences(of: #"&KR[0-9]+;"#, with: String(missingCharacter), options: .regularExpression)
    }

    static func isSpace(_ character: Character) -> Bool {
        character == "　" || character == " " || character == "\t"
    }

    static func trimmingSpaces(_ text: some StringProtocol) -> String {
        String(text.drop(while: isSpace).reversed().drop(while: isSpace).reversed())
    }

    /// 夹注的阅读顺序：双行小字先右行、后左行，即按 `/` 分开后依次相接。
    static func joinColumns(_ note: String) -> String {
        note.replacingOccurrences(of: "/", with: "")
    }
}
