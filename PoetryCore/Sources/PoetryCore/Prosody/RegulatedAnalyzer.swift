import Foundation

/// 近体诗的四种基本句型（以五言计）。七言在前面加两字：五言以仄起者加「平平」，以平起者加「仄仄」。
enum RegulatedLineType: CaseIterable {
    case zzppz  // 仄仄平平仄
    case ppzzp  // 平平仄仄平
    case pppzz  // 平平平仄仄
    case zzzpp  // 仄仄仄平平

    var five: [Tone] {
        switch self {
        case .zzppz: [.ze, .ze, .ping, .ping, .ze]
        case .ppzzp: [.ping, .ping, .ze, .ze, .ping]
        case .pppzz: [.ping, .ping, .ping, .ze, .ze]
        case .zzzpp: [.ze, .ze, .ze, .ping, .ping]
        }
    }

    var endsPing: Bool { self == .ppzzp || self == .zzzpp }

    func pattern(length: Int) -> [Tone] {
        guard length == 7 else { return five }
        return (five[0] == .ze ? [.ping, .ping] : [.ze, .ze]) + five
    }

    /// 可平可仄的位置（以五言下标计）。「仄仄仄平平」第三字若用平即成三平尾，故不可通。
    func isFlexible(core index: Int) -> Bool {
        switch self {
        case .zzzpp: index == 0
        default: index == 0 || index == 2
        }
    }

    func isFlexible(position: Int, length: Int) -> Bool {
        let offset = length - 5
        if position < offset { return position == 0 }
        return isFlexible(core: position - offset)
    }

    /// 首句入韵时，首句由仄收句换成对应的平收句。
    var rhymedFirstLine: RegulatedLineType {
        switch self {
        case .zzppz: .zzzpp
        case .pppzz: .ppzzp
        default: self
        }
    }
}

/// 近体诗（五七言绝句、律诗）格律检查。
struct RegulatedAnalyzer {
    let resolver: ReadingResolver
    var dictionary: CharDictionary { resolver.dictionary }
    var book: RhymeBook { resolver.book }

    private static let baseSequences: [[RegulatedLineType]] = [
        [.zzppz, .ppzzp, .pppzz, .zzzpp],
        [.pppzz, .zzzpp, .zzppz, .ppzzp],
    ]

    /// 平水韵常见邻韵（用于「首句借邻韵」），以韵目代表字（繁体）表示。
    private static let neighborGroups: [[Character]] = [
        ["東", "冬"], ["江", "陽"], ["支", "微", "齊"], ["魚", "虞"], ["佳", "灰"],
        ["真", "文", "元"], ["元", "寒", "刪", "先"], ["蕭", "肴", "豪"], ["歌", "麻"],
        ["庚", "青", "蒸"], ["覃", "鹽", "咸"],
    ]

    static func detect(_ segments: [[TextChar]]) -> RegulatedForm? {
        let counts = segments.map(\.count)
        if let exact = RegulatedForm.allCases.first(where: { counts == Array(repeating: $0.lineLength, count: $0.lineCount) }) {
            return exact
        }
        let total = counts.reduce(0, +)
        return RegulatedForm.allCases.first { $0.lineLength * $0.lineCount == total }
    }

    static func sequence(base: [RegulatedLineType], firstRhymes: Bool, count: Int) -> [RegulatedLineType] {
        var result: [RegulatedLineType] = []
        while result.count < count { result.append(contentsOf: base) }
        result = Array(result.prefix(count))
        if firstRhymes, !result.isEmpty { result[0] = result[0].rhymedFirstLine }
        return result
    }

    /// - Parameter opening: 指定首句起收；nil 时在四种格式中取问题最少者。
    func analyze(_ segments: [[TextChar]], form: RegulatedForm, opening: RegulatedOpening? = nil) -> PoemAnalysis {
        let lengths = Array(repeating: form.lineLength, count: form.lineCount)
        let (lines, aligned) = TextSegmenter.fit(segments, lengths: lengths)
        var candidates: [PoemAnalysis] = []
        for base in RegulatedAnalyzer.baseSequences {
            for firstRhymes in [false, true] {
                let types = RegulatedAnalyzer.sequence(base: base, firstRhymes: firstRhymes, count: form.lineCount)
                if let opening {
                    let startsPing = types[0].pattern(length: form.lineLength)[1] == .ping
                    guard startsPing == opening.startsPing, firstRhymes == opening.firstLineRhymes else { continue }
                }
                candidates.append(evaluate(lines, types: types, form: form, firstRhymes: firstRhymes, specified: opening != nil))
            }
        }
        // 分数相同时取先生成者（首句不入韵优先），保证结果稳定。
        var best = candidates[0]
        for candidate in candidates.dropFirst() where candidate.score < best.score {
            best = candidate
        }
        guard !aligned else { return best }
        var structural: [Issue] = []
        if lines.count != form.lineCount {
            structural.append(Issue(.error, .lineCount, "\(form.rawValue)应为\(form.lineCount)句，实为\(lines.count)句"))
        }
        for (index, line) in lines.enumerated() where line.count != form.lineLength {
            structural.append(Issue(.error, .lineLength, "第\(index + 1)句应为\(form.lineLength)字，实为\(line.count)字",
                                    positions: line.indices.map { CharPosition(line: index, column: $0) }))
        }
        best.issues = structural + best.issues
        return best
    }

    // MARK: - 逐字与句型规则

    private func canBe(_ character: AnalyzedChar, _ tone: Tone) -> Bool {
        character.tones.isEmpty || character.tones.contains(tone)
    }

    private func onlyIs(_ character: AnalyzedChar, _ tone: Tone) -> Bool {
        character.tones == [tone]
    }

    private func evaluate(_ lines: [[TextChar]], types: [RegulatedLineType], form: RegulatedForm, firstRhymes: Bool,
                          specified: Bool) -> PoemAnalysis {
        let length = form.lineLength
        let offset = length - 5
        var analyzed: [AnalyzedLine] = []
        for (lineIndex, line) in lines.enumerated() {
            let type: RegulatedLineType? = lineIndex < types.count ? types[lineIndex] : nil
            let pattern = type?.pattern(length: length)
            var characters: [AnalyzedChar] = []
            for (column, textChar) in line.enumerated() {
                let tones = resolver.tones(of: textChar.character, at: textChar.offset)
                let chosen = resolver.chosenReading(of: textChar.character, at: textChar.offset)
                guard let type, let pattern, column < pattern.count else {
                    characters.append(AnalyzedChar(character: textChar.character, offset: textChar.offset, tones: tones,
                                                   expected: nil, status: tones.isEmpty ? .unknown : .unconstrained, rhymeGroup: nil,
                                                   chosenReading: chosen))
                    continue
                }
                let flexible = type.isFlexible(position: column, length: length)
                let expectedTone = pattern[column]
                let status: SlotStatus
                if tones.isEmpty {
                    status = .unknown
                } else if tones.contains(expectedTone) {
                    status = tones.count > 1 ? .ambiguous : .ok
                } else {
                    status = flexible ? .flexible : .mismatch
                }
                characters.append(AnalyzedChar(character: textChar.character, offset: textChar.offset, tones: tones,
                                               expected: flexible ? .any : ToneSlot(expectedTone), status: status, rhymeGroup: nil,
                                               chosenReading: chosen))
            }
            var patternText: String?
            if let type, let pattern {
                patternText = String(pattern.indices.map {
                    type.isFlexible(position: $0, length: length) ? "中" : Character(pattern[$0].rawValue)
                })
            }
            analyzed.append(AnalyzedLine(characters: characters, patternText: patternText, stanza: 0))
        }

        var issues: [Issue] = []
        var handled = Set<CharPosition>()

        for lineIndex in analyzed.indices where lineIndex < types.count && analyzed[lineIndex].characters.count == length {
            let type = types[lineIndex]
            var line = analyzed[lineIndex]
            func column(_ core: Int) -> Int { offset + core }
            func position(_ core: Int) -> CharPosition { CharPosition(line: lineIndex, column: column(core)) }
            func label(_ core: Int) -> String { "第\(lineIndex + 1)句第\(column(core) + 1)字「\(line.characters[column(core)].character)」" }

            switch type {
            case .zzppz:
                if line.characters[column(3)].status == .mismatch {
                    let next = lineIndex + 1
                    let rescued = next < analyzed.count && next < types.count && types[next] == .ppzzp
                        && analyzed[next].characters.count == length
                        && canBe(analyzed[next].characters[column(2)], .ping)
                    handled.insert(position(3))
                    if rescued {
                        line.characters[column(3)].status = .rescued
                        issues.append(Issue(.hint, .aoRescued, "\(label(3))拗，对句第\(column(2) + 1)字用平声相救",
                                            positions: [position(3), CharPosition(line: next, column: column(2))]))
                    } else {
                        issues.append(Issue(.error, .aoUnrescued, "\(label(3))应平而仄，对句第\(column(2) + 1)字未用平声相救",
                                            positions: [position(3)]))
                    }
                } else if onlyIs(line.characters[column(2)], .ze) {
                    issues.append(Issue(.hint, .xiaoAo, "\(label(2))用仄（小拗），可救可不救", positions: [position(2)]))
                }
            case .ppzzp:
                let pingCount = (0..<4).filter { canBe(line.characters[column($0)], .ping) }.count
                if pingCount < 2 {
                    issues.append(Issue(.error, .guPing, "第\(lineIndex + 1)句犯孤平：除韵脚外只有一个平声字",
                                        positions: (0..<4).map(position)))
                } else if onlyIs(line.characters[column(0)], .ze), canBe(line.characters[column(2)], .ping) {
                    line.characters[column(2)].status = .rescued
                    issues.append(Issue(.hint, .guPingRescued, "\(label(0))用仄，第\(column(2) + 1)字用平自救（孤平拗救）",
                                        positions: [position(0), position(2)]))
                }
            case .zzzpp:
                if line.characters[column(2)].status == .mismatch {
                    handled.insert(position(2))
                    issues.append(Issue(.error, .sanPingWei, "第\(lineIndex + 1)句末三字皆平（三平尾）",
                                        positions: [position(2), position(3), position(4)]))
                }
            case .pppzz:
                let third = line.characters[column(2)]
                if line.characters[column(3)].status == .mismatch, onlyIs(third, .ze) {
                    handled.insert(position(3))
                    line.characters[column(3)].status = .rescued
                    issues.append(Issue(.hint, .teAo, "第\(lineIndex + 1)句作「平平仄平仄」（特拗），可用",
                                        positions: [position(2), position(3)]))
                } else if onlyIs(third, .ze), line.characters[column(3)].status != .mismatch {
                    issues.append(Issue(.hint, .sanZeWei, "第\(lineIndex + 1)句末三字皆仄（三仄尾），可用但宜慎",
                                        positions: [position(2), position(3), position(4)]))
                }
            }
            analyzed[lineIndex] = line
        }

        for (lineIndex, line) in analyzed.enumerated() {
            for (columnIndex, character) in line.characters.enumerated() where character.status == .mismatch {
                let position = CharPosition(line: lineIndex, column: columnIndex)
                guard !handled.contains(position), let expected = character.expected?.tone else { continue }
                issues.append(Issue(.error, .toneMismatch,
                                    "第\(lineIndex + 1)句第\(columnIndex + 1)字「\(character.character)」应\(expected.rawValue)",
                                    positions: [position]))
            }
        }

        var rhymeKeys: [String: RhymeKey] = [:]
        if let key = checkRhymes(&analyzed, types: types, length: length, issues: &issues) {
            rhymeKeys["A"] = key
        }
        checkStructure(analyzed, form: form, issues: &issues)
        issues.append(contentsOf: PoemAnalyzer.characterNotes(analyzed))

        let firstPattern = types.first?.pattern(length: length)
        let start = (firstPattern?[1] == .ping) ? "平起" : "仄起"
        let variant = "\(start)，首句\(firstRhymes ? "入韵" : "不入韵")" + (specified ? "（指定）" : "")
        return PoemAnalysis(book: book, formName: form.rawValue, variantName: variant, lines: analyzed,
                            issues: issues, rhymeKeys: rhymeKeys, rhymeBookForKeys: book)
    }

    // MARK: - 押韵

    private func checkRhymes(_ analyzed: inout [AnalyzedLine], types: [RegulatedLineType], length: Int, issues: inout [Issue]) -> RhymeKey? {
        let rhymeLines = analyzed.indices.filter { $0 < types.count && types[$0].endsPing && analyzed[$0].characters.count == length }
        guard !rhymeLines.isEmpty else { return nil }
        let last = length - 1
        var keySets: [Int: Set<RhymeKey>] = [:]
        for index in rhymeLines {
            let character = analyzed[index].characters[last]
            keySets[index] = resolver.rhymeKeys(of: character.character, at: character.offset, in: book, tone: .ping)
        }
        let mandatory = rhymeLines.filter { $0 % 2 == 1 }
        let counted = mandatory.isEmpty ? rhymeLines : mandatory
        guard let best = PoemAnalyzer.bestKey(counted.map { keySets[$0] ?? [] }) else {
            for index in rhymeLines { analyzed[index].characters[last].rhymeGroup = "A" }
            return nil
        }
        var seen: [Character: Int] = [:]
        for index in rhymeLines {
            analyzed[index].characters[last].rhymeGroup = "A"
            let character = analyzed[index].characters[last].character
            let simplified = dictionary.converter.simplified(character)
            if let previous = seen[simplified] {
                issues.append(Issue(.warning, .repeatedRhyme, "韵脚「\(character)」重复使用（第\(previous + 1)、\(index + 1)句）",
                                    positions: [CharPosition(line: previous, column: last), CharPosition(line: index, column: last)]))
            } else {
                seen[simplified] = index
            }
            let keys = keySets[index] ?? []
            guard !keys.isEmpty, !keys.contains(best) else { continue }
            let position = CharPosition(line: index, column: last)
            let names = keys.map(dictionary.displayName(of:)).sorted().joined(separator: "、")
            if index == 0, isNeighbor(best, of: keys) {
                issues.append(Issue(.hint, .neighborRhyme, "首句「\(character)」属\(names)，借邻韵（\(dictionary.displayName(of: best))）",
                                    positions: [position]))
            } else {
                analyzed[index].characters[last].status = .mismatch
                issues.append(Issue(.error, .chuYun, "第\(index + 1)句韵脚「\(character)」属\(names)，与\(dictionary.displayName(of: best))不同韵",
                                    positions: [position]))
            }
        }
        return best
    }

    private func isNeighbor(_ key: RhymeKey, of keys: Set<RhymeKey>) -> Bool {
        guard book == .pingshui, dictionary.groups.indices.contains(key.id) else { return false }
        let head = dictionary.groups[key.id].headCharacter
        let neighbors = RegulatedAnalyzer.neighborGroups.filter { $0.contains(head) }.flatMap { $0 }
        return keys.contains { other in
            dictionary.groups.indices.contains(other.id)
                && dictionary.groups[other.id].tone == .ping
                && neighbors.contains(dictionary.groups[other.id].headCharacter)
        }
    }

    // MARK: - 粘对

    private func checkStructure(_ analyzed: [AnalyzedLine], form: RegulatedForm, issues: inout [Issue]) {
        guard analyzed.count == form.lineCount, analyzed.allSatisfy({ $0.characters.count == form.lineLength }) else { return }
        let seconds = analyzed.map { $0.characters[1].tones }
        func single(_ tones: Set<Tone>) -> Bool { tones.count == 1 }
        var index = 0
        while index + 1 < seconds.count {
            if single(seconds[index]), single(seconds[index + 1]), seconds[index] == seconds[index + 1] {
                issues.append(Issue(.error, .shiDui, "第\(index + 1)、\(index + 2)句第二字平仄相同（失对）",
                                    positions: [CharPosition(line: index, column: 1), CharPosition(line: index + 1, column: 1)]))
            }
            index += 2
        }
        index = 1
        while index + 1 < seconds.count {
            if single(seconds[index]), single(seconds[index + 1]), seconds[index] != seconds[index + 1] {
                issues.append(Issue(.error, .shiNian, "第\(index + 1)、\(index + 2)句第二字平仄不同（失粘）",
                                    positions: [CharPosition(line: index, column: 1), CharPosition(line: index + 1, column: 1)]))
            }
            index += 2
        }
    }
}
