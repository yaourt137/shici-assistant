import Foundation

/// 律句的格式。
public enum MeterVariant: String, Sendable, Hashable {
    case standard = "正格"
    case guPingRescued = "孤平拗救"
    case teAo = "特拗"
    case sanZeWei = "三仄尾"
    /// 「仄仄平平仄」第四字（七言第六字）用仄，由对句第三字（七言第五字）用平相救。
    case daAoRescued = "大拗，对句救"

    /// 多种读法都成立时，优先取正格。
    var penalty: Int {
        switch self {
        case .standard: 0
        case .guPingRescued, .teAo, .sanZeWei: 1
        case .daAoRescued: 2
        }
    }
}

/// 一句律句：五七言四种基本句型之一。
public struct LineMeter: Sendable, Hashable {
    let type: RegulatedLineType
    public let length: Int
    public let variant: MeterVariant

    /// 第二字为平即「平起」。
    public var startsPing: Bool { type.pattern(length: length)[1] == .ping }
    public var endsPing: Bool { type.endsPing }

    /// 例如「仄起平收」。
    public var displayName: String { "\(startsPing ? "平起" : "仄起")\(endsPing ? "平收" : "仄收")" }

    /// 句型，可平可仄处记作「中」。
    public var patternText: String {
        let pattern = type.pattern(length: length)
        return String(pattern.indices.map {
            type.isFlexible(position: $0, length: length) ? "中" : Character(pattern[$0].rawValue)
        })
    }
}

public enum LineMeterStatus: Sendable, Hashable {
    /// 律句。
    case regular(LineMeter)
    /// 五七言但不合任何律句句型（含孤平、三平尾、大拗未救）。
    case irregular
    /// 非五七言，不作判断。
    case unsupported

    public var meter: LineMeter? {
        if case .regular(let meter) = self { return meter }
        return nil
    }
}

public enum CoupletRelation: String, Sendable, Hashable {
    /// 两句皆为律句，字数相同，第二字平仄相对。
    case opposed = "律对"
    /// 两句皆为律句，但不相对（或字数不同）。
    case notOpposed = "不对"
    /// 至少一句不是律句。
    case irregular = "非律联"
    /// 末尾落单的一句。
    case unpaired = "单句"
}

/// 一联（按次序两句一联）。
public struct CoupletMeter: Sendable, Hashable {
    public let firstLine: Int
    public let lastLine: Int
    public let relation: CoupletRelation
    /// 本联出句与上一联对句是否相粘（第二字平仄相同）；nil 表示不判断：首联，或相邻两句不全是律句、字数不同。
    public let adheres: Bool?
    /// 出句与对句同收平声或同收仄声（出句入韵）。仅在律对时有意义。
    public let sharesEnding: Bool
}

/// 律句、律对与粘的统计，用于长庆体、梅村体等律化歌行。
public struct MeterAnalysis: Sendable, Hashable {
    public let lines: [LineMeterStatus]
    public let couplets: [CoupletMeter]

    public var supportedLineCount: Int { lines.filter { $0 != .unsupported }.count }
    public var regularLineCount: Int { lines.filter { $0.meter != nil }.count }
    public var pairedCoupletCount: Int { couplets.filter { $0.relation != .unpaired }.count }
    public var opposedCoupletCount: Int { couplets.filter { $0.relation == .opposed }.count }
    public var adherenceCheckedCount: Int { couplets.filter { $0.adheres != nil }.count }
    public var adheredCount: Int { couplets.filter { $0.adheres == true }.count }

    public func couplet(containing line: Int) -> CoupletMeter? {
        couplets.first { ($0.firstLine...$0.lastLine).contains(line) }
    }
}

/// 律句律对判定。输入为每句每字可能的平仄（空集合表示韵书未收录，按可平可仄处理）。
public enum MeterAnalyzer {
    public static func analyze(_ lines: [[Set<Tone>]]) -> MeterAnalysis {
        var statuses: [LineMeterStatus] = []
        var couplets: [CoupletMeter] = []
        var index = 0
        while index < lines.count {
            let first = lines[index]
            let previous: LineMeterStatus? = index > 0 ? statuses[index - 1] : nil
            guard index + 1 < lines.count else {
                statuses.append(standalone(first))
                couplets.append(CoupletMeter(firstLine: index, lastLine: index, relation: .unpaired,
                                             adheres: adherence(previous: previous, current: statuses[index]),
                                             sharesEnding: false))
                break
            }
            let second = lines[index + 1]
            let relation: CoupletRelation
            let sharesEnding: Bool
            if let (out, response) = opposedPair(first, second) {
                statuses.append(.regular(out))
                statuses.append(.regular(response))
                relation = .opposed
                sharesEnding = out.endsPing == response.endsPing
            } else {
                let out = standalone(first)
                let response = standalone(second)
                statuses.append(out)
                statuses.append(response)
                relation = (out.meter != nil && response.meter != nil) ? .notOpposed : .irregular
                sharesEnding = false
            }
            couplets.append(CoupletMeter(firstLine: index, lastLine: index + 1, relation: relation,
                                         adheres: adherence(previous: previous, current: statuses[index]),
                                         sharesEnding: sharesEnding))
            index += 2
        }
        return MeterAnalysis(lines: statuses, couplets: couplets)
    }

    /// 一句可能成立的律句读法，正格在前。大拗须由对句救，单独看不算律句。
    static func candidates(_ tones: [Set<Tone>]) -> [LineMeter] {
        let length = tones.count
        guard length == 5 || length == 7 else { return [] }
        let offset = length - 5
        func canBe(_ core: Int, _ tone: Tone) -> Bool {
            let character = tones[offset + core]
            return character.isEmpty || character.contains(tone)
        }
        func onlyIs(_ core: Int, _ tone: Tone) -> Bool { tones[offset + core] == [tone] }

        var result: [LineMeter] = []
        for type in RegulatedLineType.allCases {
            let pattern = type.pattern(length: length)
            let mismatches = pattern.indices.filter { position in
                guard !type.isFlexible(position: position, length: length) else { return false }
                let character = tones[position]
                return !character.isEmpty && !character.contains(pattern[position])
            }
            let variant: MeterVariant?
            switch type {
            case .ppzzp:
                // 孤平：除韵脚外只有第二字（七言第四字）一个平声。
                let isGuPing = !canBe(0, .ping) && !canBe(2, .ping)
                if !mismatches.isEmpty || isGuPing {
                    variant = nil
                } else {
                    variant = onlyIs(0, .ze) ? .guPingRescued : .standard
                }
            case .pppzz:
                if mismatches.isEmpty {
                    variant = onlyIs(2, .ze) ? .sanZeWei : .standard
                } else if mismatches == [offset + 3], onlyIs(2, .ze) {
                    variant = .teAo
                } else {
                    variant = nil
                }
            case .zzppz:
                if mismatches.isEmpty {
                    variant = .standard
                } else if mismatches == [offset + 3] {
                    variant = .daAoRescued
                } else {
                    variant = nil
                }
            case .zzzpp:
                // 第三字（七言第五字）不可通，否则成三平尾。
                variant = mismatches.isEmpty ? .standard : nil
            }
            if let variant { result.append(LineMeter(type: type, length: length, variant: variant)) }
        }
        return result.enumerated()
            .sorted { ($0.element.variant.penalty, $0.offset) < ($1.element.variant.penalty, $1.offset) }
            .map(\.element)
    }

    private static func standalone(_ tones: [Set<Tone>]) -> LineMeterStatus {
        guard tones.count == 5 || tones.count == 7 else { return .unsupported }
        guard let meter = candidates(tones).first(where: { $0.variant != .daAoRescued }) else { return .irregular }
        return .regular(meter)
    }

    /// 取能构成律对的读法（多音字可能有多种），格式越正越优先。
    private static func opposedPair(_ first: [Set<Tone>], _ second: [Set<Tone>]) -> (LineMeter, LineMeter)? {
        var best: (LineMeter, LineMeter)?
        for out in candidates(first) {
            for response in candidates(second) where response.variant != .daAoRescued {
                guard out.length == response.length, out.startsPing != response.startsPing else { continue }
                if out.variant == .daAoRescued, !rescues(response, tones: second) { continue }
                guard let current = best else {
                    best = (out, response)
                    continue
                }
                if out.variant.penalty + response.variant.penalty < current.0.variant.penalty + current.1.variant.penalty {
                    best = (out, response)
                }
            }
        }
        return best
    }

    /// 对句为「平平仄仄平」且第三字（七言第五字）可平，即可救出句大拗。
    private static func rescues(_ response: LineMeter, tones: [Set<Tone>]) -> Bool {
        guard response.type == .ppzzp else { return false }
        let character = tones[response.length - 5 + 2]
        return character.isEmpty || character.contains(.ping)
    }

    private static func adherence(previous: LineMeterStatus?, current: LineMeterStatus) -> Bool? {
        guard let before = previous?.meter, let now = current.meter, before.length == now.length else { return nil }
        return before.startsPing == now.startsPing
    }
}

extension PoemAnalysis {
    /// 按律绝分析（含自动识别为律绝）时为对应体裁，否则为 nil。
    public var regulatedForm: RegulatedForm? { RegulatedForm(rawValue: formName) }

    /// 逐句律句、逐联律对与粘的判定（不依赖所选体裁）。
    public var meter: MeterAnalysis {
        MeterAnalyzer.analyze(lines.map { $0.characters.map(\.tones) })
    }
}
