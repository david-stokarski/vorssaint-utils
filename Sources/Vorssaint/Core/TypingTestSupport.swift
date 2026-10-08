// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: Typing Test, in the spirit of Monkeytype. A line of common words,
// timed or counted; type them and see words per minute, accuracy and
// consistency, with every finished test kept so averages and bests add up.
// The run's rules and the scoring live here, where the tests compile them;
// the window is in Services/TypingTest and UI/TypingTest.

extension DefaultsKey {
    /// `TypingTestMode.Kind` raw value.
    static let typingTestKind = "typingTestKind"
    /// Seconds for a timed test.
    static let typingTestSeconds = "typingTestSeconds"
    /// Words for a counted test.
    static let typingTestWords = "typingTestWords"
    /// `TypingTestQuote.Length` raw value for a quote test.
    static let typingTestQuoteLength = "typingTestQuoteLength"
    /// `TypingTestLanguage` raw value for a code test, 0 for any language.
    static let typingTestCodeLanguage = "typingTestCodeLanguage"
}

/// What a test runs to: a number of seconds, a number of words, or the end
/// of a real passage or a piece of code.
struct TypingTestMode: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable { case time, words, quote, code }

    var kind: Kind
    var amount: Int

    static let timeOptions = [15, 30, 60, 120]
    static let wordOptions = [10, 25, 50, 100]
    /// `TypingTestQuote.Length` raw values.
    static let quoteOptions = TypingTestQuote.Length.allCases.map(\.rawValue)
    /// 0 for any language, then `TypingTestLanguage` raw values.
    static let codeOptions = [0] + TypingTestLanguage.allCases.map(\.rawValue)
    static let standard = TypingTestMode(kind: .time, amount: 30)

    static func options(for kind: Kind) -> [Int] {
        switch kind {
        case .time: return timeOptions
        case .words: return wordOptions
        case .quote: return quoteOptions
        case .code: return codeOptions
        }
    }

    /// What a kind starts on when it is picked.
    static func preferred(_ kind: Kind) -> TypingTestMode {
        switch kind {
        case .time: return TypingTestMode(kind: .time, amount: 30)
        case .words: return TypingTestMode(kind: .words, amount: 25)
        case .quote: return TypingTestMode(kind: .quote, amount: TypingTestQuote.Length.any.rawValue)
        case .code: return TypingTestMode(kind: .code, amount: 0)
        }
    }

    /// Ends after the last word instead of on a clock.
    var endsOnLastWord: Bool { kind != .time }

    /// How an option reads in the mode bar.
    static func label(_ amount: Int, for kind: Kind) -> String {
        switch kind {
        case .quote: return (TypingTestQuote.Length(rawValue: amount) ?? .any).title
        case .code: return TypingTestLanguage(rawValue: amount)?.shortTitle ?? "all"
        case .time, .words: return "\(amount)"
        }
    }

    var title: String {
        switch kind {
        case .time: return "time \(amount)"
        case .words: return "words \(amount)"
        case .quote: return amount == 0 ? "quote" : "quote \(Self.label(amount, for: .quote))"
        case .code: return amount == 0 ? "code" : "code \(Self.label(amount, for: .code))"
        }
    }

    /// The saved choice, or the standard one where it is unknown.
    static func load(from defaults: UserDefaults) -> TypingTestMode {
        let kind = defaults.string(forKey: DefaultsKey.typingTestKind).flatMap(Kind.init(rawValue:)) ?? .time
        switch kind {
        case .time:
            let seconds = defaults.integer(forKey: DefaultsKey.typingTestSeconds)
            return TypingTestMode(kind: .time, amount: timeOptions.contains(seconds) ? seconds : 30)
        case .words:
            let words = defaults.integer(forKey: DefaultsKey.typingTestWords)
            return TypingTestMode(kind: .words, amount: wordOptions.contains(words) ? words : 25)
        case .quote:
            let length = defaults.integer(forKey: DefaultsKey.typingTestQuoteLength)
            return TypingTestMode(kind: .quote, amount: quoteOptions.contains(length) ? length : 0)
        case .code:
            let language = defaults.integer(forKey: DefaultsKey.typingTestCodeLanguage)
            return TypingTestMode(kind: .code, amount: codeOptions.contains(language) ? language : 0)
        }
    }

    func save(to defaults: UserDefaults) {
        defaults.set(kind.rawValue, forKey: DefaultsKey.typingTestKind)
        let key: String
        switch kind {
        case .time: key = DefaultsKey.typingTestSeconds
        case .words: key = DefaultsKey.typingTestWords
        case .quote: key = DefaultsKey.typingTestQuoteLength
        case .code: key = DefaultsKey.typingTestCodeLanguage
        }
        defaults.set(amount, forKey: key)
    }
}

/// One test in progress: the words, what was typed against each, and the
/// keystrokes counted on the way. Times are seconds from any fixed clock,
/// passed in, so the rules can be tested without waiting.
struct TypingTestRun {
    let mode: TypingTestMode
    /// The passage of a quote test.
    let quote: TypingTestQuote?
    /// The snippet of a code test, with its lines and colors.
    let code: TypingTestCodeSnippet?
    private(set) var words: [String]
    /// What was typed for each word so far; the last one is the current word.
    private(set) var typed: [String] = [""]
    private(set) var startedAt: Double?
    private(set) var finishedAt: Double?
    /// Every key that put a letter or a space down, right or wrong.
    private(set) var keystrokes = 0
    private(set) var correctKeystrokes = 0
    /// Correct characters (letters of correct words plus their spaces) and all
    /// characters typed, at the end of each whole second.
    private(set) var samples: [(correct: Int, typed: Int)] = []
    /// Keys that were wrong, by whole second, for the chart's marks.
    private(set) var errorsBySecond: [Int: Int] = [:]
    private var typedCharacters = 0
    private var generator: TypingTestWords

    /// `avoiding` and `avoidingCode` are what was just typed, so a passage or
    /// a snippet is never offered twice running while there is another.
    init(mode: TypingTestMode, seed: UInt64 = UInt64.random(in: 1...UInt64.max),
         avoiding: TypingTestQuote? = nil, avoidingCode: TypingTestCodeSnippet? = nil) {
        self.mode = mode
        generator = TypingTestWords(seed: seed)
        switch mode.kind {
        case .code:
            var pool = TypingTestCodeSnippet.pool(TypingTestLanguage(rawValue: mode.amount))
            if pool.isEmpty { pool = TypingTestCodeSnippet.all }
            if pool.count > 1, let avoidingCode { pool.removeAll { $0 == avoidingCode } }
            let snippet = pool[Int(seed % UInt64(pool.count))]
            code = snippet
            quote = nil
            words = snippet.words
        case .quote:
            var pool = TypingTestQuote.pool(TypingTestQuote.Length(rawValue: mode.amount) ?? .any)
            if pool.isEmpty { pool = TypingTestQuote.all }
            if pool.count > 1, let avoiding { pool.removeAll { $0 == avoiding } }
            let quote = pool[Int(seed % UInt64(pool.count))]
            self.quote = quote
            code = nil
            words = quote.words
        case .words:
            quote = nil
            code = nil
            words = generator.next(mode.amount)
        case .time:
            quote = nil
            code = nil
            words = generator.next(60)
        }
    }

    var currentIndex: Int { typed.count - 1 }
    var currentWord: String { words[currentIndex] }
    var isStarted: Bool { startedAt != nil }
    var isFinished: Bool { finishedAt != nil }

    /// Seconds typed, up to `now` or the finish.
    func elapsed(at now: Double) -> Double {
        guard let startedAt else { return 0 }
        return max(0, (finishedAt ?? now) - startedAt)
    }

    /// Seconds left in a timed test.
    func remaining(at now: Double) -> Int {
        guard mode.kind == .time else { return 0 }
        return max(0, Int((Double(mode.amount) - elapsed(at: now)).rounded(.up)))
    }

    // MARK: Typing

    /// A letter, a space, or a new line (Return, which moves on from a word
    /// the way Space does). Returns false once the test is over.
    @discardableResult
    mutating func type(_ character: Character, at now: Double) -> Bool {
        guard !isFinished else { return false }
        tick(at: now)
        guard !isFinished else { return false }
        if character == " " || character == "\n" {
            // A space on an empty word does nothing, as in Monkeytype.
            guard !typed[currentIndex].isEmpty else { return true }
            if startedAt == nil { startedAt = now }
            count(keystroke: typed[currentIndex] == currentWord, at: now)
            typedCharacters += 1
            if mode.endsOnLastWord, currentIndex == words.count - 1 {
                finish(at: now)
                return true
            }
            typed.append("")
            topUp()
            return true
        }
        guard !character.isWhitespace, !character.isNewline else { return true }
        if startedAt == nil { startedAt = now }
        let position = typed[currentIndex].count
        let expected = position < currentWord.count
            ? currentWord[currentWord.index(currentWord.startIndex, offsetBy: position)] : nil
        // Extra letters past the word's end stop at a sensible length.
        guard position < currentWord.count + 12 else { return true }
        typed[currentIndex].append(character)
        typedCharacters += 1
        count(keystroke: character == expected, at: now)
        // The last word of a counted test or a quote ends it once it is right.
        if mode.endsOnLastWord, currentIndex == words.count - 1, typed[currentIndex] == currentWord {
            finish(at: now)
        }
        return true
    }

    /// Backspace: a letter, or back into the previous word while it is wrong.
    mutating func deleteBackward(wholeWord: Bool = false, at now: Double) {
        guard !isFinished else { return }
        tick(at: now)
        guard !isFinished else { return }
        if typed[currentIndex].isEmpty {
            guard currentIndex > 0, typed[currentIndex - 1] != words[currentIndex - 1] else { return }
            typed.removeLast()
            if !wholeWord { return }
        }
        if wholeWord {
            typed[currentIndex] = ""
        } else {
            typed[currentIndex].removeLast()
        }
    }

    /// Advances the clock: closes whole seconds and ends a timed test.
    mutating func tick(at now: Double) {
        guard let startedAt, !isFinished else { return }
        let elapsed = now - startedAt
        while Double(samples.count + 1) <= elapsed, samples.count < 600 {
            samples.append((correctCharacters, typedCharacters))
            if mode.kind == .time, samples.count >= mode.amount { break }
        }
        if mode.kind == .time, elapsed >= Double(mode.amount) {
            finish(at: startedAt + Double(mode.amount))
        }
    }

    private mutating func finish(at time: Double) {
        guard finishedAt == nil else { return }
        finishedAt = time
        if let startedAt, Double(samples.count) < time - startedAt - 0.05 || samples.isEmpty {
            samples.append((correctCharacters, typedCharacters))
        }
    }

    private mutating func count(keystroke correct: Bool, at now: Double) {
        keystrokes += 1
        if correct {
            correctKeystrokes += 1
        } else if let startedAt {
            errorsBySecond[Int(now - startedAt), default: 0] += 1
        }
    }

    /// A timed test never runs out of words.
    private mutating func topUp() {
        guard mode.kind == .time, words.count - currentIndex < 40 else { return }
        words += generator.next(40)
    }

    // MARK: Scoring

    /// Letters of correctly typed words, the spaces after them, and the
    /// correct start of the word being typed when the test ends: what
    /// Monkeytype counts toward words per minute.
    var correctCharacters: Int {
        var total = 0
        for (index, input) in typed.enumerated() {
            let word = words[index]
            if index < currentIndex {
                if input == word { total += word.count + 1 }
            } else if word.hasPrefix(input) {
                total += input.count
            }
        }
        return total
    }

    struct Characters: Equatable {
        var correct = 0, incorrect = 0, extra = 0, missed = 0
    }

    /// Letter by letter over the words reached.
    var characters: Characters {
        var result = Characters()
        for (index, input) in typed.enumerated() {
            let word = Array(words[index]), letters = Array(input)
            for position in 0..<max(word.count, letters.count) {
                if position < letters.count, position < word.count {
                    if letters[position] == word[position] { result.correct += 1 } else { result.incorrect += 1 }
                } else if position < letters.count {
                    result.extra += 1
                } else if index < currentIndex || (mode.endsOnLastWord && isFinished && index == currentIndex) {
                    // Letters skipped by moving on; a timed test stopping
                    // mid-word skipped nothing.
                    result.missed += 1
                }
            }
        }
        return result
    }

    /// The result, once the test is over.
    func result(on date: Date = Date()) -> TypingTestResult? {
        guard let startedAt, let finishedAt else { return nil }
        let seconds = max(finishedAt - startedAt, 0.001)
        let minutes = seconds / 60
        let speeds = TypingTestScoring.secondSpeeds(samples)
        return TypingTestResult(
            date: date, mode: mode,
            wpm: Double(correctCharacters) / 5 / minutes,
            raw: Double(typedCharacters) / 5 / minutes,
            accuracy: keystrokes == 0 ? 0 : Double(correctKeystrokes) / Double(keystrokes) * 100,
            consistency: TypingTestScoring.consistency(speeds.raw),
            seconds: seconds, characters: characters,
            wpmBySecond: speeds.wpm, rawBySecond: speeds.raw, source: quote?.source ?? code?.source)
    }
}

enum TypingTestScoring {
    /// Words per minute (correct) and raw, for each whole second on its own.
    static func secondSpeeds(_ samples: [(correct: Int, typed: Int)]) -> (wpm: [Double], raw: [Double]) {
        var wpm: [Double] = [], raw: [Double] = []
        for (index, sample) in samples.enumerated() {
            let seconds = Double(index + 1)
            wpm.append(Double(sample.correct) / 5 / (seconds / 60))
            let previous = index > 0 ? samples[index - 1].typed : 0
            raw.append(Double(sample.typed - previous) / 5 * 60)
        }
        return (wpm, raw)
    }

    /// How even the pace was, 0 to 100: Monkeytype's measure, one minus the
    /// spread of the per-second raw speed against its mean, eased.
    static func consistency(_ speeds: [Double]) -> Double {
        guard speeds.count > 1 else { return speeds.isEmpty ? 0 : 100 }
        let mean = speeds.reduce(0, +) / Double(speeds.count)
        guard mean > 0 else { return 0 }
        let variance = speeds.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(speeds.count)
        let variation = variance.squareRoot() / mean
        return max(0, min(100, 100 * (1 - tanh(variation + variation * variation * variation / 3
                                                 + variation * variation * variation * variation * variation / 5))))
    }
}

/// One finished test, as kept in the history.
struct TypingTestResult: Codable, Equatable, Identifiable {
    var id = UUID()
    var date: Date
    var mode: TypingTestMode
    var wpm: Double
    var raw: Double
    var accuracy: Double
    var consistency: Double
    var seconds: Double
    var correct: Int
    var incorrect: Int
    var extra: Int
    var missed: Int
    var wpmBySecond: [Double]
    var rawBySecond: [Double]
    /// Where a quote test's passage comes from.
    var source: String?

    init(date: Date, mode: TypingTestMode, wpm: Double, raw: Double, accuracy: Double, consistency: Double,
         seconds: Double, characters: TypingTestRun.Characters, wpmBySecond: [Double], rawBySecond: [Double],
         source: String? = nil) {
        self.date = date
        self.mode = mode
        self.wpm = wpm
        self.raw = raw
        self.accuracy = accuracy
        self.consistency = consistency
        self.seconds = seconds
        correct = characters.correct
        incorrect = characters.incorrect
        extra = characters.extra
        missed = characters.missed
        self.wpmBySecond = wpmBySecond
        self.rawBySecond = rawBySecond
        self.source = source
    }

    /// Too short or too wrong to count, as Monkeytype also drops them.
    var isWorthKeeping: Bool {
        correct > 0 && accuracy >= 25 && wpm > 0 && (mode.endsOnLastWord || seconds >= Double(mode.amount) - 0.5)
    }
}

/// Averages and bests over the kept tests.
struct TypingTestSummary: Equatable {
    var tests = 0
    var averageWPM: Double = 0
    var recentWPM: Double = 0
    var averageAccuracy: Double = 0
    var bestWPM: Double = 0
    var secondsTyping: Double = 0

    /// How many of the newest tests "recent" covers.
    static let recentCount = 10

    init() {}

    init(_ results: [TypingTestResult]) {
        guard !results.isEmpty else { return }
        tests = results.count
        averageWPM = results.map(\.wpm).reduce(0, +) / Double(results.count)
        averageAccuracy = results.map(\.accuracy).reduce(0, +) / Double(results.count)
        bestWPM = results.map(\.wpm).max() ?? 0
        secondsTyping = results.map(\.seconds).reduce(0, +)
        let recent = results.sorted { $0.date > $1.date }.prefix(Self.recentCount)
        recentWPM = recent.map(\.wpm).reduce(0, +) / Double(recent.count)
    }

    /// The best speed in one mode, for "personal best" on a new result.
    static func best(in mode: TypingTestMode, of results: [TypingTestResult], excluding id: UUID? = nil) -> Double? {
        results.filter { $0.mode == mode && $0.id != id }.map(\.wpm).max()
    }
}

enum TypingTestSupport {
    static let title = "Typing Test"
    static let hubDescription = "A minimal typing speed test, timed, by word count or on real passages or code, that keeps every result so you can follow your average and your best."

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.typingTestKind: TypingTestMode.Kind.time.rawValue,
        DefaultsKey.typingTestSeconds: 30,
        DefaultsKey.typingTestWords: 25,
        DefaultsKey.typingTestQuoteLength: 0,
        DefaultsKey.typingTestCodeLanguage: 0,
    ]

    /// The newest this many are kept.
    static let historyLimit = 2_000

    static func decode(_ data: Data?) -> [TypingTestResult] {
        guard let data else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([TypingTestResult].self, from: data)) ?? []
    }

    static func encode(_ results: [TypingTestResult]) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return try? encoder.encode(Array(results.sorted { $0.date > $1.date }.prefix(historyLimit)))
    }
}

/// Common English words in a repeatable random order: no word twice in a
/// row, so a doubled word never reads as a typo.
struct TypingTestWords {
    private var state: UInt64
    private var last: String?

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    mutating func next(_ count: Int) -> [String] {
        (0..<max(0, count)).map { _ in
            var word: String
            repeat {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                word = Self.common[Int((state >> 33) % UInt64(Self.common.count))]
            } while word == last
            last = word
            return word
        }
    }

    /// About two hundred of the most used English words.
    static let common = """
    the be of and a to in he have it that for they with as not on she at by this we you do but from or which \
    one would all will there say who make when can more if no man out other so what time up go about than into \
    could state only new year some take come these know see use get like then first any work now may such give \
    over think most even find day also after way many must look before great back through long where much should \
    well people down own just because good each those feel seem how high too place little world very still nation \
    hand old life tell write become here show house both between need mean call develop under last right move \
    thing general school never same another begin while number part turn real leave might want point form off \
    child few small since against ask late home interest large person end open public follow during present \
    without again hold govern around possible head consider word program problem however lead system set order \
    eye plan run keep face fact group play stand increase early course change help line
    """.split(separator: " ").map(String.init)
}
