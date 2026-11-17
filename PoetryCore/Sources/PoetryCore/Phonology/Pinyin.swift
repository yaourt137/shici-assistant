import Foundation

/// 一个带调拼音音节，例如 `zhī`、`lǜ`、`yuán`。
public struct PinyinSyllable: Sendable, Hashable {
    /// 去掉声调后的拼写，ü 保留为 `ü`。
    public let plain: String
    /// 1...4 为四声，5 为轻声或未标调。
    public let tone: Int
    /// 规范化后的韵母；舌尖元音记为 `-i`，零声母写法已还原（ya → ia，wei → ui，yu → ü）。
    public let final: String

    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        var letters = ""
        var tone = 5
        for scalar in trimmed.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.value {
            case 0x0304: tone = 1
            case 0x0301: tone = 2
            case 0x030C: tone = 3
            case 0x0300: tone = 4
            case 0x0308:
                guard letters.last == "u" else { return nil }
                letters.removeLast()
                letters.append("ü")
            case 0x0302:
                guard letters.last == "e" else { return nil }
                letters.removeLast()
                letters.append("ê")
            default:
                let character = Character(scalar)
                if character == "v" {
                    letters.append("ü")
                } else if let digit = character.wholeNumberValue {
                    guard (1...5).contains(digit) else { return nil }
                    tone = digit
                } else if character.isLetter, character.isASCII {
                    letters.append(character)
                } else {
                    return nil
                }
            }
        }
        guard !letters.isEmpty else { return nil }
        self.plain = letters
        self.tone = tone
        self.final = PinyinSyllable.final(of: letters)
    }

    private static let initials = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l",
                                   "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w"]
    private static let apicalInitials: Set<String> = ["zh", "ch", "sh", "r", "z", "c", "s"]

    static func final(of plain: String) -> String {
        var initial = ""
        var rest = plain
        for candidate in initials where plain.hasPrefix(candidate) && plain.count > candidate.count {
            initial = candidate
            rest = String(plain.dropFirst(candidate.count))
            break
        }
        switch initial {
        case "y":
            if rest.hasPrefix("u") {
                rest = "ü" + rest.dropFirst()
            } else if !rest.hasPrefix("i") {
                rest = "i" + rest
            }
        case "w":
            if !rest.hasPrefix("u") {
                rest = "u" + rest
            }
        case "j", "q", "x":
            if rest.hasPrefix("u") {
                rest = "ü" + rest.dropFirst()
            }
        default:
            if apicalInitials.contains(initial), rest == "i" {
                rest = "-i"
            }
        }
        switch rest {
        case "iou": return "iu"
        case "uei": return "ui"
        case "uen": return "un"
        case "ue": return "üe"
        default: return rest
        }
    }
}

/// 中华通韵（2019）十六韵，依普通话韵母归部。
public enum TongYun {
    public static let names = ["一啊", "二喔", "三鹅", "四衣", "五乌", "六迂", "七哀", "八欸",
                               "九熬", "十欧", "十一安", "十二恩", "十三昂", "十四英", "十五雍", "十六儿"]

    private static let finals: [String: Int] = [
        "a": 1, "ia": 1, "ua": 1,
        "o": 2, "uo": 2, "io": 2,
        "e": 3, "ie": 3, "üe": 3, "ê": 3,
        "i": 4, "-i": 4,
        "u": 5,
        "ü": 6,
        "ai": 7, "uai": 7,
        "ei": 8, "ui": 8,
        "ao": 9, "iao": 9,
        "ou": 10, "iu": 10,
        "an": 11, "ian": 11, "uan": 11, "üan": 11,
        "en": 12, "in": 12, "un": 12, "ün": 12,
        "ang": 13, "iang": 13, "uang": 13,
        "eng": 14, "ing": 14, "ueng": 14,
        "ong": 15, "iong": 15,
        "er": 16,
    ]

    /// 韵母所属的韵号（1...16）；叹词等无法归部的返回 nil。
    public static func rhymeID(forFinal final: String) -> Int? {
        finals[final]
    }

    /// 通韵平仄：阴平、阳平为平，上声、去声为仄；轻声不参与。
    public static func tone(forPinyinTone tone: Int) -> Tone? {
        switch tone {
        case 1, 2: .ping
        case 3, 4: .ze
        default: nil
        }
    }

    public static func name(of id: Int) -> String {
        guard (1...names.count).contains(id) else { return "未知韵" }
        return names[id - 1]
    }
}
