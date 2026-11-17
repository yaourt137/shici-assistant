import Foundation

/// 平仄二分。
public enum Tone: String, Sendable, Hashable, Codable, CaseIterable {
    case ping = "平"
    case ze = "仄"

    public var opposite: Tone { self == .ping ? .ze : .ping }
}

/// 韵书。
public enum RhymeBook: String, Sendable, Hashable, Codable, CaseIterable, Identifiable {
    case pingshui
    case cilin
    case tongyun

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pingshui: "平水韵"
        case .cilin: "词林正韵"
        case .tongyun: "中华通韵"
        }
    }

    /// 平水韵与词林正韵的平仄判定相同（同源于中古音），中华通韵依今音。
    public var usesModernTones: Bool { self == .tongyun }
}

/// 某一韵书中的一个韵部。`id` 的含义随韵书不同：
/// 平水韵为 0...105 的韵目序号；词林正韵为 1...19 部；中华通韵为 1...16 韵。
public struct RhymeKey: Sendable, Hashable, Codable {
    public let book: RhymeBook
    public let id: Int

    public init(book: RhymeBook, id: Int) {
        self.book = book
        self.id = id
    }
}

/// 一个字在某韵书下的一种读法。
public struct Reading: Sendable, Hashable, Codable {
    public let tone: Tone
    public let rhyme: RhymeKey

    public init(tone: Tone, rhyme: RhymeKey) {
        self.tone = tone
        self.rhyme = rhyme
    }
}

/// 格律模板中的一个位置。
public enum ToneSlot: Character, Sendable, Hashable, Codable {
    case ping = "平"
    case ze = "仄"
    case any = "中"

    public init(_ tone: Tone) {
        self = tone == .ping ? .ping : .ze
    }

    public var tone: Tone? {
        switch self {
        case .ping: .ping
        case .ze: .ze
        case .any: nil
        }
    }

    /// 是否接受一个字可能的平仄集合。空集合（未收录字）只被「中」接受。
    public func accepts(_ tones: Set<Tone>) -> Bool {
        guard let tone else { return true }
        return tones.contains(tone)
    }
}
