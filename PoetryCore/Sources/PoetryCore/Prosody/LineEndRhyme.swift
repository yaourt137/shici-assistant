import Foundation

extension CharDictionary {
    /// 一种读法的简称：平水韵韵目已含声调（如「下平·一先」）；词林正韵、中华通韵前加平仄（如「平·第七部」）。
    public func label(of reading: Reading) -> String {
        reading.rhyme.book == .pingshui
            ? displayName(of: reading.rhyme)
            : "\(reading.tone.rawValue)·\(displayName(of: reading.rhyme))"
    }
}

extension PoemAnalysis {
    /// 每句句末字在所选韵书中的全部韵部（多音字有多个；已指定读音者只取指定的）；韵书未收录则为空数组。
    public func lineEndRhymeLabels(dictionary: CharDictionary) -> [[String]] {
        lines.map { line in
            guard let last = line.characters.last else { return [] }
            if let chosen = last.chosenReading { return [dictionary.label(of: chosen)] }
            return dictionary.readings(of: last.character, in: book).map(dictionary.label(of:))
        }
    }
}
