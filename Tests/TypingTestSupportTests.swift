// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: Typing Test. Words are typed and corrected the way Monkeytype does
/// it, the two kinds of test end where they should, speed, accuracy and
/// consistency come out right, the history round-trips, and the averages
/// add up.
enum TypingTestSupportTests {
    static func run(_ suite: TestSuite) {
        words(suite)
        typing(suite)
        timed(suite)
        counted(suite)
        quotes(suite)
        code(suite)
        scoring(suite)
        history(suite)
        modes(suite)
    }

    /// Types `text` one key per `step` seconds starting at `start`.
    private static func type(_ text: String, into run: inout TypingTestRun, start: Double = 100,
                             step: Double = 0.1) -> Double {
        var time = start
        for character in text {
            run.type(character, at: time)
            time += step
        }
        return time
    }

    private static func words(_ suite: TestSuite) {
        var a = TypingTestWords(seed: 42), b = TypingTestWords(seed: 42)
        let first = a.next(200)
        suite.expect(first == b.next(200), "the same seed gives the same words")
        suite.expect(zip(first, first.dropFirst()).allSatisfy { $0 != $1 }, "no word twice in a row")
        suite.expect(first.allSatisfy { TypingTestWords.common.contains($0) }, "only common words")
        suite.expect(Set(TypingTestWords.common).count == TypingTestWords.common.count, "the list has no repeats")
    }

    private static func typing(_ suite: TestSuite) {
        var run = TypingTestRun(mode: TypingTestMode(kind: .words, amount: 10), seed: 7)
        let word = run.words[0]
        run.type(" ", at: 1)
        suite.expect(!run.isStarted && run.currentIndex == 0, "a space before anything is ignored")
        _ = type(word + " ", into: &run, start: 1)
        suite.expect(run.isStarted && run.currentIndex == 1, "a word and a space move on")
        suite.expect(run.correctCharacters == word.count + 1, "a right word counts with its space")

        // A wrong word, then back into it to fix it.
        let second = run.words[1]
        _ = type("zz ", into: &run, start: 3)
        suite.expect(run.currentIndex == 2, "a wrong word still moves on")
        run.deleteBackward(at: 4)
        suite.expect(run.currentIndex == 1 && run.typed[1] == "zz", "backspace returns into a wrong word")
        run.deleteBackward(wholeWord: true, at: 4.1)
        suite.expect(run.typed[1].isEmpty, "a whole word deletes at once")
        _ = type(second + " ", into: &run, start: 5)
        run.deleteBackward(at: 7)
        suite.expect(run.currentIndex == 2, "a right word can't be reopened")
        suite.expect(run.keystrokes > run.correctKeystrokes, "the mistakes still count against accuracy")

        // Extra letters past the end of a word.
        var extra = TypingTestRun(mode: TypingTestMode(kind: .words, amount: 10), seed: 9)
        _ = type(extra.words[0] + "xyz", into: &extra)
        suite.expect(extra.typed[0].count == extra.words[0].count + 3, "extra letters are kept")
        suite.expect(extra.characters.extra == 3, "and counted as extra")
    }

    private static func timed(_ suite: TestSuite) {
        var run = TypingTestRun(mode: TypingTestMode(kind: .time, amount: 15), seed: 3)
        var time = 100.0
        // Five words a second... at 0.3 s a key, roughly forty words per minute.
        while !run.isFinished {
            let word = run.words[run.currentIndex]
            time = type(word + " ", into: &run, start: time, step: 0.3)
            run.tick(at: time)
        }
        suite.expect(run.elapsed(at: 999) == 15, "a timed test stops at its time exactly")
        suite.expect(run.samples.count == 15, "with one sample a second")
        suite.expect(run.words.count > run.currentIndex + 10, "and never runs out of words")
        let keys = run.keystrokes
        suite.expect(!run.type("a", at: time + 1) && run.keystrokes == keys, "keys after the end do nothing")
        let result = run.result()
        suite.expect(result != nil, "a finished test has a result")
        if let result {
            suite.expect(result.wpm > 30 && result.wpm < 50, "about forty words a minute (\(Int(result.wpm)))")
            suite.expect(result.accuracy == 100, "with every key right")
            suite.expect(result.isWorthKeeping, "a clean full test is kept")
            suite.expect(result.wpmBySecond.count == 15 && result.rawBySecond.count == 15, "speeds by second")
        }
    }

    private static func counted(_ suite: TestSuite) {
        var run = TypingTestRun(mode: TypingTestMode(kind: .words, amount: 10), seed: 5)
        var time = 100.0
        for index in 0..<9 { time = type(run.words[index] + " ", into: &run, start: time) }
        suite.expect(!run.isFinished, "nine of ten words is not done")
        time = type(run.words[9], into: &run, start: time)
        suite.expect(run.isFinished, "the last word right ends the test, no space needed")
        suite.expect(run.characters.missed == 0 && run.characters.incorrect == 0, "nothing missed")

        var skipped = TypingTestRun(mode: TypingTestMode(kind: .words, amount: 10), seed: 5)
        time = 100
        for index in 0..<10 { time = type(String(skipped.words[index].prefix(1)) + " ", into: &skipped, start: time) }
        suite.expect(skipped.isFinished, "a space on the last word ends it too")
        suite.expect(skipped.characters.missed > 0, "letters skipped by moving on are missed")
    }

    private static func quotes(_ suite: TestSuite) {
        let all = TypingTestQuote.all
        suite.expect(all.count >= 30, "a good number of passages")
        suite.expect(Set(all.map(\.text)).count == all.count, "no passage twice")
        suite.expect(all.allSatisfy { quote in quote.text.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 } },
                     "every passage types on a plain keyboard: no curly quotes or long dashes")
        suite.expect(all.allSatisfy { !$0.text.contains("  ") && $0.text == $0.text.trimmingCharacters(in: .whitespaces) },
                     "single spaces only, so every word is one word")
        suite.expect(all.allSatisfy { !$0.source.isEmpty }, "every passage names its source")
        for length in TypingTestQuote.Length.allCases {
            suite.expect(!TypingTestQuote.pool(length).isEmpty, "there are \(length.title) passages")
        }

        let mode = TypingTestMode(kind: .quote, amount: TypingTestQuote.Length.short.rawValue)
        var run = TypingTestRun(mode: mode, seed: 11)
        guard let quote = run.quote else { suite.expect(false, "a quote test has a passage"); return }
        suite.expect(quote.length == .short, "the length asked for")
        suite.expect(run.words == quote.words, "its words, punctuation and capitals kept")
        var time = 100.0
        for (index, word) in run.words.enumerated() {
            time = type(word + (index < run.words.count - 1 ? " " : ""), into: &run, start: time)
        }
        suite.expect(run.isFinished, "the passage's last word ends it")
        let result = run.result()
        suite.expect(result?.source == quote.source && result?.accuracy == 100, "the result names the passage")
        suite.expect(result?.isWorthKeeping == true, "a quote is kept whatever its length")

        let next = TypingTestRun(mode: mode, seed: 11, avoiding: quote)
        suite.expect(next.quote != quote, "the same passage never comes twice running")
        suite.expect(TypingTestMode.label(2, for: .quote) == "medium" && TypingTestMode.label(30, for: .time) == "30",
                     "the mode bar names lengths and counts")

        // A result saved before quotes existed still loads.
        let old = #"[{"id":"\#(UUID().uuidString)","date":1000,"mode":{"kind":"time","amount":30},"wpm":60,"raw":65,"accuracy":96,"consistency":70,"seconds":30,"correct":150,"incorrect":3,"extra":0,"missed":0,"wpmBySecond":[60],"rawBySecond":[65]}]"#
        let decoded = TypingTestSupport.decode(Data(old.utf8))
        suite.expect(decoded.count == 1 && decoded.first?.source == nil, "older results load without a source")
    }

    private static func code(_ suite: TestSuite) {
        let all = TypingTestCodeSnippet.all
        for language in TypingTestLanguage.allCases {
            suite.expect(TypingTestCodeSnippet.pool(language).count >= 3, "\(language.title) has snippets")
        }
        for snippet in all {
            let name = snippet.source
            let lines = snippet.text.split(separator: "\n", omittingEmptySubsequences: false)
            suite.expect(snippet.text.unicodeScalars.allSatisfy { $0.isASCII && ($0.value >= 32 || $0 == "\n") },
                         "\(name) types on a plain keyboard, no tabs")
            suite.expect(lines.allSatisfy { !$0.hasSuffix(" ") && !$0.drop { $0 == " " }.contains("  ") },
                         "\(name) has single spaces between words and none at line ends")
            suite.expect(snippet.columns <= 72, "\(name) fits the window")
            suite.expect(snippet.syntax.map(\.count) == snippet.words.map(\.count), "\(name) colors every letter")
            let flattened = snippet.lines.flatMap { Array($0.words) }
            suite.expect(flattened == Array(0..<snippet.words.count), "\(name) puts every word on one line, in order")
        }

        func kinds(_ line: String, _ language: TypingTestLanguage) -> String {
            TypingTestCodeSnippet.highlight(line, language).map { kind -> String in
                switch kind {
                case .plain: return "."
                case .keyword: return "k"
                case .string: return "s"
                case .comment: return "c"
                case .number: return "n"
                case .type: return "t"
                case .function: return "f"
                case .punctuation: return "p"
                }
            }.joined()
        }
        suite.expect(kinds(#"let x = "a b" // hi"#, .swift) == "kkk...p.sssss.ccccc", "keywords, strings and comments")
        suite.expect(kinds("print(Foo, 42)", .swift) == "fffffptttp.nnp", "calls, types and numbers")
        suite.expect(kinds("x2 = 3 # note", .python) == "...p.n.cccccc", "a digit inside a name is not a number")
        suite.expect(kinds("fn f() -> &'a str", .rust).contains("kkk"), "a Rust lifetime is not a string")
        suite.expect(!kinds("fn f() -> &'a str", .rust).contains("s"), "so nothing after it is a string")

        let mode = TypingTestMode(kind: .code, amount: TypingTestLanguage.python.rawValue)
        var run = TypingTestRun(mode: mode, seed: 21)
        guard let snippet = run.code else { suite.expect(false, "a code test has a snippet"); return }
        suite.expect(snippet.language == .python, "the language asked for")
        var time = 100.0
        for line in snippet.lines where !line.words.isEmpty {
            for word in line.words {
                let last = word == snippet.words.count - 1
                let separator = word == line.words.upperBound - 1 ? "\n" : " "
                time = type(snippet.words[word] + (last ? "" : separator), into: &run, start: time)
            }
        }
        suite.expect(run.isFinished, "Return between lines and the last word typed ends it")
        suite.expect(run.result()?.accuracy == 100, "a new line counts as a right key")
        suite.expect(run.result()?.source == snippet.source, "the result names the snippet")
        let next = TypingTestRun(mode: mode, seed: 21, avoidingCode: snippet)
        suite.expect(next.code != snippet, "the same snippet never comes twice running")
        suite.expect(TypingTestMode.label(TypingTestLanguage.javascript.rawValue, for: .code) == "js"
                        && TypingTestMode.label(0, for: .code) == "all", "the mode bar names languages")
        suite.expect(Set(TypingTestLanguage.menuOrder) == Set(TypingTestLanguage.allCases)
                        && TypingTestLanguage.menuOrder.count == TypingTestLanguage.allCases.count,
                     "the language menu lists every language once")
        suite.expect(TypingTestLanguage.swift.rawValue == 1 && TypingTestLanguage.rust.rawValue == 5,
                     "saved languages keep their numbers")
        suite.expect(kinds("SELECT name FROM users -- all", .sql) == "kkkkkk......kkkk.......cccccc",
                     "SQL keywords and -- comments")
        suite.expect(kinds("select 'x'", .sql) == "kkkkkk.sss", "SQL keywords in any case, ' strings")
        suite.expect(kinds("<Card title={t}>", .react) == "ptttt......pp.pp", "a JSX tag is colored, its attribute is not")
        suite.expect(kinds("</li>", .react) == "ppttp", "and so is a closing tag")
    }

    private static func scoring(_ suite: TestSuite) {
        suite.expect(TypingTestScoring.consistency([80, 80, 80, 80]) == 100, "an even pace is fully consistent")
        suite.expect(TypingTestScoring.consistency([20, 140, 30, 150]) < 50, "an uneven pace is not")
        suite.expect(TypingTestScoring.consistency([]) == 0, "no samples, no consistency")
        let speeds = TypingTestScoring.secondSpeeds([(10, 10), (20, 25)])
        suite.expect(speeds.wpm == [120, 120], "correct speed is cumulative")
        suite.expect(speeds.raw == [120, 180], "raw speed is per second")
    }

    private static func history(_ suite: TestSuite) {
        let mode = TypingTestMode(kind: .time, amount: 30)
        func result(_ wpm: Double, _ minutesAgo: Double) -> TypingTestResult {
            TypingTestResult(date: Date(timeIntervalSince1970: 1_000_000 - minutesAgo * 60), mode: mode,
                             wpm: wpm, raw: wpm + 5, accuracy: 95, consistency: 70, seconds: 30,
                             characters: .init(correct: 100, incorrect: 3, extra: 0, missed: 1),
                             wpmBySecond: [wpm], rawBySecond: [wpm])
        }
        let results = (0..<12).map { result(Double(50 + $0), Double($0)) }
        let decoded = TypingTestSupport.decode(TypingTestSupport.encode(results))
        suite.expect(decoded.count == 12 && Set(decoded.map(\.id)) == Set(results.map(\.id)), "history round-trips")
        suite.expect(decoded.first?.wpm == 50, "newest first")
        suite.expect(TypingTestSupport.decode(Data("nonsense".utf8)).isEmpty, "a broken file is an empty history")
        let summary = TypingTestSummary(results)
        suite.expect(summary.tests == 12 && summary.bestWPM == 61, "count and best")
        suite.expect(abs(summary.averageWPM - 55.5) < 0.001, "average of all")
        suite.expect(abs(summary.recentWPM - 54.5) < 0.001, "average of the newest ten")
        suite.expect(summary.secondsTyping == 360, "time typing adds up")
        suite.expect(TypingTestSummary.best(in: mode, of: results, excluding: results[11].id) == 60,
                     "the best before this one")
        suite.expect(TypingTestSummary.best(in: TypingTestMode(kind: .words, amount: 10), of: results) == nil,
                     "no best in a mode never typed")
        var short = result(80, 0)
        short.seconds = 4
        suite.expect(!short.isWorthKeeping, "a timed test cut short is not kept")
    }

    private static func modes(_ suite: TestSuite) {
        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.typingtest")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.typingtest")
        suite.expect(TypingTestMode.load(from: defaults) == .standard, "thirty seconds by default")
        TypingTestMode(kind: .words, amount: 50).save(to: defaults)
        suite.expect(TypingTestMode.load(from: defaults) == TypingTestMode(kind: .words, amount: 50), "the choice is kept")
        defaults.set(37, forKey: DefaultsKey.typingTestWords)
        suite.expect(TypingTestMode.load(from: defaults).amount == 25, "an unknown count falls back")
        TypingTestMode(kind: .quote, amount: 3).save(to: defaults)
        suite.expect(TypingTestMode.load(from: defaults) == TypingTestMode(kind: .quote, amount: 3), "a quote length is kept")
        defaults.set(9, forKey: DefaultsKey.typingTestQuoteLength)
        suite.expect(TypingTestMode.load(from: defaults).amount == 0, "an unknown length is all")
        TypingTestMode(kind: .code, amount: TypingTestLanguage.rust.rawValue).save(to: defaults)
        suite.expect(TypingTestMode.load(from: defaults) == TypingTestMode(kind: .code, amount: 5), "a language is kept")
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.typingtest")
    }
}
