import Foundation

/// 格律分析入口：近体诗、词谱与自由标注。
public struct PoemAnalyzer: Sendable {
    public let dictionary: CharDictionary
    public let tunes: CiTuneLibrary

    public init(dictionary: CharDictionary = .shared, tunes: CiTuneLibrary = .bundled) {
        self.dictionary = dictionary
        self.tunes = tunes
    }

    /// - Parameter choices: 用户指定的读音，只有与 `book` 相同韵书者生效。
    public func analyze(_ text: String, form: FormSelection, book: RhymeBook, choices: [ReadingChoice] = []) -> PoemAnalysis {
        let segments = TextSegmenter.segments(of: text)
        guard !segments.isEmpty else { return .empty(book: book) }
        let resolver = ReadingResolver(dictionary: dictionary, book: book, choices: choices)
        switch form {
        case .automatic:
            if let detected = RegulatedAnalyzer.detect(segments) {
                return RegulatedAnalyzer(resolver: resolver).analyze(segments, form: detected)
            }
            return free(segments, resolver: resolver, note: Issue(.hint, .unrecognizedForm,
                "未识别为近体诗（五言或七言的绝句、律诗），仅逐字标注平仄；如为词，请在体裁中选择词牌"))
        case .regulated(let form, let opening):
            return RegulatedAnalyzer(resolver: resolver).analyze(segments, form: form, opening: opening)
        case .ci(let id):
            guard let tune = tunes.tune(id: id) else {
                return free(segments, resolver: resolver, note: Issue(.error, .unrecognizedForm, "未找到词牌「\(id)」"))
            }
            return ci(segments, tune: tune, resolver: resolver)
        case .free:
            return free(segments, resolver: resolver, note: nil)
        }
    }

    // MARK: - 自由标注

    private func free(_ segments: [[TextChar]], resolver: ReadingResolver, note: Issue?) -> PoemAnalysis {
        let book = resolver.book
        let lines = segments.map { segment in
            AnalyzedLine(characters: segment.map { textChar in
                let tones = resolver.tones(of: textChar.character, at: textChar.offset)
                return AnalyzedChar(character: textChar.character, offset: textChar.offset, tones: tones, expected: nil,
                                    status: tones.isEmpty ? .unknown : .unconstrained, rhymeGroup: nil,
                                    chosenReading: resolver.chosenReading(of: textChar.character, at: textChar.offset))
            }, patternText: nil, stanza: 0)
        }
        var issues = note.map { [$0] } ?? []
        issues.append(contentsOf: PoemAnalyzer.characterNotes(lines))
        return PoemAnalysis(book: book, formName: "自由", variantName: nil, lines: lines, issues: issues,
                            rhymeKeys: [:], rhymeBookForKeys: book)
    }

    // MARK: - 词谱

    private func ci(_ segments: [[TextChar]], tune: CiTune, resolver: ReadingResolver) -> PoemAnalysis {
        let book = resolver.book
        let lengths = tune.lines.map(\.slots.count)
        let (lines, aligned) = TextSegmenter.fit(segments, lengths: lengths)
        // 填词通行词林正韵；选平水韵时平仄相同，押韵按词林正韵部判断。
        let keyBook: RhymeBook = book == .tongyun ? .tongyun : .cilin
        var analyzed: [AnalyzedLine] = []
        var issues: [Issue] = []

        if !aligned {
            let actual = segments.reduce(0) { $0 + $1.count }
            let expected = lengths.map(String.init).joined(separator: "/")
            issues.append(Issue(.error, .lineLength,
                                "字数或句读与《\(tune.name)》不符：应为\(tune.characterCount)字（各句 \(expected)），实为\(actual)字"))
        }

        for (lineIndex, line) in lines.enumerated() {
            let spec: CiLine? = lineIndex < tune.lines.count ? tune.lines[lineIndex] : nil
            var characters: [AnalyzedChar] = []
            for (column, textChar) in line.enumerated() {
                let tones = resolver.tones(of: textChar.character, at: textChar.offset)
                let chosen = resolver.chosenReading(of: textChar.character, at: textChar.offset)
                guard let spec, column < spec.slots.count else {
                    characters.append(AnalyzedChar(character: textChar.character, offset: textChar.offset, tones: tones,
                                                   expected: nil, status: tones.isEmpty ? .unknown : .unconstrained, rhymeGroup: nil,
                                                   chosenReading: chosen))
                    continue
                }
                let slot = spec.slots[column]
                let status: SlotStatus
                if tones.isEmpty {
                    status = .unknown
                } else if slot.accepts(tones) {
                    status = (slot != .any && tones.count > 1) ? .ambiguous : .ok
                } else {
                    status = .mismatch
                    issues.append(Issue(.error, .toneMismatch,
                                        "第\(lineIndex + 1)句第\(column + 1)字「\(textChar.character)」应\(slot.rawValue)",
                                        positions: [CharPosition(line: lineIndex, column: column)]))
                }
                characters.append(AnalyzedChar(character: textChar.character, offset: textChar.offset, tones: tones,
                                               expected: slot, status: status, rhymeGroup: nil, chosenReading: chosen))
            }
            analyzed.append(AnalyzedLine(characters: characters, patternText: spec?.patternText, stanza: spec?.stanza ?? 0))
        }

        var rhymeKeys: [String: RhymeKey] = [:]
        var groupOrder: [String] = []
        for line in tune.lines {
            if let group = line.rhymeGroup, !groupOrder.contains(group) { groupOrder.append(group) }
        }
        for group in groupOrder {
            let indices = analyzed.indices.filter { index in
                index < tune.lines.count && tune.lines[index].rhymeGroup == group
                    && analyzed[index].characters.count == tune.lines[index].slots.count
            }
            var keySets: [Int: Set<RhymeKey>] = [:]
            for index in indices {
                guard let tone = tune.lines[index].slots.last?.tone,
                      let last = analyzed[index].characters.last else { continue }
                keySets[index] = resolver.rhymeKeys(of: last.character, at: last.offset, in: keyBook, tone: tone)
                analyzed[index].characters[analyzed[index].characters.count - 1].rhymeGroup = group
            }
            guard let best = PoemAnalyzer.bestKey(indices.map { keySets[$0] ?? [] }) else { continue }
            rhymeKeys[group] = best
            for index in indices {
                let keys = keySets[index] ?? []
                guard !keys.isEmpty, !keys.contains(best) else { continue }
                let column = analyzed[index].characters.count - 1
                let character = analyzed[index].characters[column].character
                analyzed[index].characters[column].status = .mismatch
                let names = keys.map(dictionary.displayName(of:)).sorted().joined(separator: "、")
                issues.append(Issue(.error, .chuYun, "第\(index + 1)句韵脚「\(character)」属\(names)，与\(dictionary.displayName(of: best))不同部",
                                    positions: [CharPosition(line: index, column: column)]))
            }
        }

        issues.append(contentsOf: PoemAnalyzer.characterNotes(analyzed))
        let variant = book == .pingshui ? "\(tune.summary)押韵按词林正韵部判断。" : tune.summary
        return PoemAnalysis(book: book, formName: "词·\(tune.name)", variantName: variant, lines: analyzed,
                            issues: issues, rhymeKeys: rhymeKeys, rhymeBookForKeys: keyBook)
    }

    // MARK: - 共用

    /// 选出覆盖最多韵脚的韵部；并列时取最先出现者。
    static func bestKey(_ keySets: [Set<RhymeKey>]) -> RhymeKey? {
        var counts: [RhymeKey: Int] = [:]
        var firstSeen: [RhymeKey: Int] = [:]
        for (index, keys) in keySets.enumerated() {
            for key in keys {
                counts[key, default: 0] += 1
                if firstSeen[key] == nil { firstSeen[key] = index }
            }
        }
        return counts.keys.max { lhs, rhs in
            let left = counts[lhs] ?? 0
            let right = counts[rhs] ?? 0
            if left != right { return left < right }
            let leftFirst = firstSeen[lhs] ?? .max
            let rightFirst = firstSeen[rhs] ?? .max
            if leftFirst != rightFirst { return leftFirst > rightFirst }
            return lhs.id > rhs.id
        }
    }

    /// 多音字、未收录字与重字提示。
    static func characterNotes(_ lines: [AnalyzedLine]) -> [Issue] {
        var issues: [Issue] = []
        var polyphonic: [Character] = []
        var polyphonicPositions: [CharPosition] = []
        var unknown: [Character] = []
        var unknownPositions: [CharPosition] = []
        var runs: [Character: [CharPosition]] = [:]
        for (lineIndex, line) in lines.enumerated() {
            for (column, character) in line.characters.enumerated() {
                let position = CharPosition(line: lineIndex, column: column)
                if character.status == .ambiguous {
                    if !polyphonic.contains(character.character) { polyphonic.append(character.character) }
                    polyphonicPositions.append(position)
                }
                if character.status == .unknown {
                    if !unknown.contains(character.character) { unknown.append(character.character) }
                    unknownPositions.append(position)
                }
                let isRepeatOfPrevious = column > 0 && line.characters[column - 1].character == character.character
                if !isRepeatOfPrevious {
                    runs[character.character, default: []].append(position)
                }
            }
        }
        if !polyphonic.isEmpty {
            issues.append(Issue(.hint, .polyphonic, "多音字按可通处理：\(polyphonic.map(String.init).joined(separator: "、"))",
                                positions: polyphonicPositions))
        }
        if !unknown.isEmpty {
            issues.append(Issue(.hint, .unknownCharacter, "韵书未收录，不作判断：\(unknown.map(String.init).joined(separator: "、"))",
                                positions: unknownPositions))
        }
        let repeated = runs.filter { $0.value.count > 1 }.sorted { ($0.value[0].line, $0.value[0].column) < ($1.value[0].line, $1.value[0].column) }
        if !repeated.isEmpty {
            issues.append(Issue(.hint, .repeatedCharacter, "重字：\(repeated.map { String($0.key) }.joined(separator: "、"))",
                                positions: repeated.flatMap(\.value)))
        }
        return issues
    }
}
