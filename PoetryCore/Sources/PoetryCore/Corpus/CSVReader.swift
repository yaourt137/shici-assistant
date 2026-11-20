import Foundation

public enum CSVError: Error, Equatable, CustomStringConvertible {
    case notUTF8
    case unterminatedQuote(row: Int)

    public var description: String {
        switch self {
        case .notUTF8: "CSV 不是 UTF-8 编码"
        case .unterminatedQuote(let row): "CSV 第 \(row) 行的引号没有闭合"
        }
    }
}

/// RFC 4180 风格的 CSV：逗号分隔，双引号包裹的字段可含逗号、换行，字段内的 `""` 表示一个引号；行尾可为 LF 或 CRLF。
/// 按 UTF-8 字节解析（分隔符都是 ASCII，不会落在多字节字符中间）。
enum CSVReader {
    private static let quote = UInt8(ascii: "\"")
    private static let comma = UInt8(ascii: ",")
    private static let newline = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")

    static func rows(_ data: Data) throws -> [[String]] {
        guard String(data: data, encoding: .utf8) != nil else { throw CSVError.notUTF8 }
        var bytes = [UInt8](data)
        // 去掉 UTF-8 BOM。
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }

        var rows: [[String]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var fieldStarted = false
        var index = 0

        func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
            fieldStarted = false
        }
        func endRow() {
            endField()
            // 空行不算一行。
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while index < bytes.count {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    if index + 1 < bytes.count, bytes[index + 1] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
            } else if byte == quote, !fieldStarted, field.isEmpty {
                inQuotes = true
                fieldStarted = true
            } else if byte == comma {
                endField()
            } else if byte == newline {
                endRow()
            } else if byte == carriageReturn, index + 1 < bytes.count, bytes[index + 1] == newline {
                // CRLF：交给下一个 LF 处理。
            } else {
                field.append(byte)
                fieldStarted = true
            }
            index += 1
        }
        if inQuotes { throw CSVError.unterminatedQuote(row: rows.count + 1) }
        if fieldStarted || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
