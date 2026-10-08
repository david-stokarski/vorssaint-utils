// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Charts
import SwiftUI

/// Fork: the Typing Test window. The words in three lines with a caret, the
/// result with its speed over time, and the history with averages. Every key
/// goes to one catcher view: letters and space type, Backspace deletes (with
/// ⌥ or ⌘ a whole word), Tab starts over, Esc stops a test or closes.
struct TypingTestView: View {
    @ObservedObject var service: TypingTestService
    @State private var focused = true

    var body: some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, 30)
                .padding(.horizontal, 36)
            Group {
                switch service.page {
                case .history:
                    TypingTestHistoryView(service: service)
                case .test:
                    if let result = service.lastResult {
                        TypingTestResultView(result: result, quote: service.run.quote, isBest: service.lastWasBest,
                                             kept: result.isWorthKeeping, next: service.restart)
                    } else {
                        if let code = service.run.code {
                            TypingTestCodeArea(run: service.run, snippet: code, focused: focused)
                        } else {
                            TypingTestArea(run: service.run, now: service.now, focused: focused)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
                .padding(.bottom, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(
            TypingKeyCatcher(active: service.page == .test, focused: $focused) { key in handle(key) }
        )
        .frame(minWidth: 720, minHeight: 440)
    }

    private var typing: Bool { service.run.isStarted && !service.run.isFinished }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 18) {
            Label(TypingTestSupport.title, systemImage: "keyboard")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            modePicker
                .opacity(service.page == .test ? 1 : 0)
            Spacer()
            HStack(spacing: 14) {
                pageButton("Test", .test)
                pageButton("History", .history)
            }
        }
        // Out of the way while the words are being typed.
        .opacity(typing ? 0.12 : 1)
        .animation(.easeOut(duration: 0.25), value: typing)
    }

    private var modePicker: some View {
        HStack(spacing: 4) {
            ForEach(TypingTestMode.Kind.allCases, id: \.self) { kind in
                chip(kind.rawValue, selected: service.mode.kind == kind) {
                    guard service.mode.kind != kind else { return }
                    service.setMode(.preferred(kind))
                }
            }
            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 1, height: 14).padding(.horizontal, 6)
            if service.mode.kind == .code {
                languageMenu
            } else {
                ForEach(TypingTestMode.options(for: service.mode.kind), id: \.self) { amount in
                    chip(TypingTestMode.label(amount, for: service.mode.kind), selected: service.mode.amount == amount) {
                        service.setMode(TypingTestMode(kind: service.mode.kind, amount: amount))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }

    /// Too many languages for a row of chips: one menu, the chosen one shown.
    private var languageMenu: some View {
        let current = TypingTestLanguage(rawValue: service.mode.amount)
        return Menu {
            Button {
                service.setMode(TypingTestMode(kind: .code, amount: 0))
            } label: {
                if current == nil { Label("All Languages", systemImage: "checkmark") } else { Text("All Languages") }
            }
            Divider()
            ForEach(TypingTestLanguage.menuOrder, id: \.self) { language in
                Button {
                    service.setMode(TypingTestMode(kind: .code, amount: language.rawValue))
                } label: {
                    if current == language { Label(language.title, systemImage: "checkmark") } else { Text(language.title) }
                }
            }
        } label: {
            // A plain button style keeps the label as drawn: accent, chevron after.
            HStack(spacing: 4) {
                Text(current?.title.lowercased() ?? "all languages")
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func pageButton(_ title: String, _ page: TypingTestService.Page) -> some View {
        Button { service.page = page } label: {
            Text(title)
                .font(.system(size: 12, weight: service.page == page ? .semibold : .regular, design: .rounded))
                .foregroundStyle(service.page == page ? Color.primary : Color.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            hint("tab", "restart")
            hint("esc", "close")
            if service.lastResult != nil {
                hint("return", "next test")
            } else if service.mode.kind == .code {
                hint("space or return", "next word")
            }
        }
        // The keys belong to the test; the history has its own buttons.
        .opacity(typing || service.page != .test ? 0 : 1)
        .animation(.easeOut(duration: 0.25), value: typing)
    }

    private func hint(_ key: String, _ action: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
            Text(action).font(.system(size: 11))
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: Keys

    private func handle(_ key: TypingKey) {
        switch key {
        case .restart:
            service.restart()
        case .escape:
            service.escape()
        case .confirm:
            service.confirm()
        case .delete(let wholeWord):
            if service.page == .test { service.deleteBackward(wholeWord: wholeWord) }
        case .character(let character):
            guard service.page == .test else { return }
            service.type(character)
        }
    }
}

// MARK: - The words

/// Three lines of words, wrapped on a fixed grid since every letter of the
/// monospaced face is the same width, with the line being typed kept second
/// once the first is done.
private struct TypingTestArea: View {
    let run: TypingTestRun
    let now: Double
    let focused: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var blink = false

    private static let fontSize: CGFloat = 28
    private static let nsFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    private static let advance: CGFloat = ("m" as NSString).size(withAttributes: [.font: nsFont]).width
    private static let lineHeight: CGFloat = fontSize * 1.75
    private static let visibleLines = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(counter)
                .font(.system(size: 26, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .opacity(run.isStarted || run.mode.kind == .time ? 1 : 0.5)
                .monospacedDigit()
            GeometryReader { proxy in
                let layout = Self.layout(run, width: proxy.size.width)
                let first = max(0, layout.currentLine - 1)
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(first..<min(first + Self.visibleLines, layout.lines.count), id: \.self) { line in
                            text(for: layout.lines[line])
                                .font(Font(Self.nsFont))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(height: Self.lineHeight, alignment: .leading)
                        }
                    }
                    caret
                        .offset(x: CGFloat(layout.caretColumn) * Self.advance - 1,
                                y: CGFloat(layout.currentLine - first) * Self.lineHeight
                                    + (Self.lineHeight - Self.fontSize * 1.2) / 2)
                        .animation(.easeOut(duration: 0.09), value: layout.caretColumn)
                        .animation(.easeOut(duration: 0.12), value: layout.currentLine - first)
                }
                .blur(radius: focused ? 0 : 5)
                .overlay {
                    if !focused {
                        Label("Click to focus", systemImage: "cursorarrow.click")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: Self.lineHeight * CGFloat(Self.visibleLines))
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: 1180)
        .onAppear { blink = true }
    }

    private var counter: String {
        switch run.mode.kind {
        case .time: return "\(run.isStarted ? run.remaining(at: now) : run.mode.amount)"
        case .words, .quote, .code: return "\(run.currentIndex)/\(run.words.count)"
        }
    }

    private var caret: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(Color.accentColor)
            .frame(width: 2.5, height: Self.fontSize * 1.2)
            // Blinks while waiting for the first key, steady while typing.
            .opacity(run.isStarted ? 1 : (blink ? 0.15 : 1))
            .animation(run.isStarted ? .default : .easeInOut(duration: 0.55).repeatForever(), value: blink)
    }

    // MARK: Layout

    struct Layout {
        var lines: [[Int]] = [[]]
        var currentLine = 0
        var caretColumn = 0
    }

    /// Greedy wrapping on the character grid; a word is as wide as the more
    /// of what it says and what was typed for it.
    static func layout(_ run: TypingTestRun, width: CGFloat) -> Layout {
        let perLine = max(10, Int(width / advance))
        var layout = Layout()
        var column = 0
        let reach = min(run.words.count, run.currentIndex + 60)
        for index in 0..<reach {
            let typed = index < run.typed.count ? run.typed[index] : ""
            let length = max(run.words[index].count, typed.count)
            if column > 0, column + length > perLine {
                layout.lines.append([])
                column = 0
            }
            if index == run.currentIndex {
                layout.currentLine = layout.lines.count - 1
                layout.caretColumn = column + typed.count
            }
            layout.lines[layout.lines.count - 1].append(index)
            column += length + 1
        }
        return layout
    }

    private func text(for line: [Int]) -> Text {
        let pending = Color.primary.opacity(0.3)
        let right = Color.primary.opacity(0.92)
        let wrong = PanelMetricColor.red(for: scheme)
        var result = Text("")
        for (position, index) in line.enumerated() {
            if position > 0 { result = result + Text(" ").foregroundColor(pending) }
            let word = Array(run.words[index])
            let typed = index < run.typed.count ? Array(run.typed[index]) : []
            let done = index < run.currentIndex
            let missed = done && typed != word
            var segment = Text("")
            for letter in 0..<max(word.count, typed.count) {
                let piece: Text
                if letter < typed.count, letter < word.count {
                    piece = Text(String(word[letter])).foregroundColor(typed[letter] == word[letter] ? right : wrong)
                } else if letter < typed.count {
                    piece = Text(String(typed[letter])).foregroundColor(wrong.opacity(0.6))
                } else {
                    piece = Text(String(word[letter])).foregroundColor(pending)
                }
                segment = segment + piece
            }
            // A word passed with a mistake keeps a red underline.
            result = result + (missed ? segment.underline(true, color: wrong.opacity(0.7)) : segment)
        }
        return result
    }
}

// MARK: - Code

/// A snippet as an editor shows it: its own lines and indentation, line
/// numbers, and colors for what is still to type. Typed letters take the
/// test's own right and wrong colors. The font shrinks to fit the widest
/// line; a long snippet scrolls to keep the line being typed in view.
private struct TypingTestCodeArea: View {
    let run: TypingTestRun
    let snippet: TypingTestCodeSnippet
    let focused: Bool
    @Environment(\.colorScheme) private var scheme
    @State private var blink = false

    private static let visibleLines = 12
    /// A monospaced letter's width per point of size.
    private static let advanceRatio: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 100, weight: .regular)
        return ("m" as NSString).size(withAttributes: [.font: font]).width / 100
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(run.currentIndex)/\(run.words.count)")
                    .font(.system(size: 26, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                    .opacity(run.isStarted ? 1 : 0.5)
                    .monospacedDigit()
                Text(snippet.source)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            GeometryReader { proxy in
                let gutter = 4
                let size = min(19, proxy.size.width / (CGFloat(snippet.columns + gutter + 1) * Self.advanceRatio))
                let advance = size * Self.advanceRatio
                let lineHeight = size * 1.6
                let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
                let current = snippet.line(of: run.currentIndex)
                let shown = min(snippet.lines.count, Self.visibleLines)
                let first = max(0, min(current - 4, snippet.lines.count - shown))
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(first..<(first + shown), id: \.self) { line in
                            HStack(spacing: 0) {
                                Text(String(line + 1))
                                    .foregroundColor(Color.primary.opacity(line == current ? 0.45 : 0.18))
                                    .frame(width: CGFloat(gutter - 1) * advance, alignment: .trailing)
                                    .padding(.trailing, advance)
                                text(for: snippet.lines[line])
                            }
                            .font(Font(font))
                            .lineLimit(1)
                            .fixedSize()
                            .frame(height: lineHeight, alignment: .leading)
                        }
                    }
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.accentColor)
                        .frame(width: 2.5, height: size * 1.2)
                        .opacity(run.isStarted ? 1 : (blink ? 0.15 : 1))
                        .animation(run.isStarted ? .default : .easeInOut(duration: 0.55).repeatForever(), value: blink)
                        .offset(x: CGFloat(gutter + caretColumn(in: snippet.lines[current])) * advance - 1,
                                y: CGFloat(current - first) * lineHeight + (lineHeight - size * 1.2) / 2)
                        .animation(.easeOut(duration: 0.09), value: run.currentIndex)
                        .animation(.easeOut(duration: 0.09), value: run.typed.last)
                }
                .blur(radius: focused ? 0 : 5)
                .overlay {
                    if !focused {
                        Label("Click to focus", systemImage: "cursorarrow.click")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: 19 * 1.6 * CGFloat(min(snippet.lines.count, Self.visibleLines)))
        }
        .padding(.horizontal, 64)
        .frame(maxWidth: 1180)
        .onAppear { blink = true }
    }

    private func typed(_ word: Int) -> [Character] {
        word < run.typed.count ? Array(run.typed[word]) : []
    }

    /// Where the caret sits on its line: the indentation, the words before
    /// it at their typed width, then what was typed of the current word.
    private func caretColumn(in line: TypingTestCodeSnippet.Line) -> Int {
        var column = line.indent
        for word in line.words where word < run.currentIndex {
            column += max(run.words[word].count, typed(word).count) + 1
        }
        return column + typed(run.currentIndex).count
    }

    private func text(for line: TypingTestCodeSnippet.Line) -> Text {
        let right = Color.primary.opacity(0.92)
        let wrong = PanelMetricColor.red(for: scheme)
        var result = Text(String(repeating: " ", count: line.indent))
        for word in line.words {
            if word > line.words.lowerBound { result = result + Text(" ") }
            let letters = Array(run.words[word])
            let input = typed(word)
            let classes = snippet.syntax[word]
            var segment = Text("")
            for position in 0..<max(letters.count, input.count) {
                let piece: Text
                if position < input.count, position < letters.count {
                    piece = Text(String(letters[position]))
                        .foregroundColor(input[position] == letters[position] ? right : wrong)
                } else if position < input.count {
                    piece = Text(String(input[position])).foregroundColor(wrong.opacity(0.6))
                } else {
                    let kind = classes[position]
                    piece = Text(String(letters[position])).foregroundColor(color(kind))
                        .italic(kind == .comment)
                }
                segment = segment + piece
            }
            let missed = word < run.currentIndex && input != letters
            result = result + (missed ? segment.underline(true, color: wrong.opacity(0.7)) : segment)
        }
        return result
    }

    /// An editor's palette, a little muted so typed letters stand out.
    private func color(_ kind: TypingTestSyntax) -> Color {
        let dark = scheme == .dark
        let color: Color
        switch kind {
        case .keyword: color = dark ? Color(red: 0.98, green: 0.47, blue: 0.68) : Color(red: 0.68, green: 0.13, blue: 0.43)
        case .string: color = dark ? Color(red: 0.98, green: 0.62, blue: 0.42) : Color(red: 0.72, green: 0.27, blue: 0.08)
        case .comment: color = Color.primary.opacity(0.4)
        case .number: color = dark ? Color(red: 0.85, green: 0.78, blue: 0.47) : Color(red: 0.50, green: 0.40, blue: 0.0)
        case .type: color = dark ? Color(red: 0.42, green: 0.82, blue: 0.86) : Color(red: 0.0, green: 0.45, blue: 0.52)
        case .function: color = dark ? Color(red: 0.55, green: 0.70, blue: 1.0) : Color(red: 0.13, green: 0.35, blue: 0.80)
        case .punctuation: return Color.primary.opacity(0.42)
        case .plain: return Color.primary.opacity(0.62)
        }
        return color.opacity(dark ? 0.78 : 0.85)
    }
}

// MARK: - The result

private struct TypingTestResultView: View {
    let result: TypingTestResult
    let quote: TypingTestQuote?
    let isBest: Bool
    let kept: Bool
    let next: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 14) {
                    bigStat("wpm", Self.whole(result.wpm))
                    bigStat("acc", "\(Self.whole(result.accuracy))%")
                    if isBest {
                        Label("New personal best", systemImage: "crown.fill")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                    } else if !kept {
                        Text("Not saved: too short or too many mistakes")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 170, alignment: .leading)
                chart
                    .frame(maxWidth: .infinity, minHeight: 170, maxHeight: 220)
            }
            if let source = result.source {
                // The passage just typed, and where it is from.
                VStack(alignment: .leading, spacing: 4) {
                    if let quote { Text(quote.text).lineLimit(2).foregroundStyle(.secondary) }
                    Text("- " + source).foregroundStyle(.tertiary)
                }
                .font(.system(size: 12))
            }
            HStack(alignment: .top, spacing: 34) {
                smallStat("test type", result.mode.title)
                smallStat("raw", Self.whole(result.raw))
                smallStat("characters", "\(result.correct)/\(result.incorrect)/\(result.extra)/\(result.missed)")
                    .help("Correct / incorrect / extra / missed")
                smallStat("consistency", "\(Self.whole(result.consistency))%")
                smallStat("time", "\(Self.whole(result.seconds))s")
                Spacer()
                Button(action: next) {
                    Label("Next test", systemImage: "arrow.right")
                }
                .controlSize(.large)
                .focusable(false)
            }
        }
        .padding(.horizontal, 80)
        .frame(maxWidth: 1180)
    }

    private var chart: some View {
        Chart {
            ForEach(Array(result.rawBySecond.enumerated()), id: \.offset) { second, value in
                LineMark(x: .value("Second", second + 1), y: .value("raw", value), series: .value("Series", "raw"))
                    .foregroundStyle(Color.secondary.opacity(0.5))
                    .interpolationMethod(.monotone)
            }
            ForEach(Array(result.wpmBySecond.enumerated()), id: \.offset) { second, value in
                LineMark(x: .value("Second", second + 1), y: .value("wpm", value), series: .value("Series", "wpm"))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                    .interpolationMethod(.monotone)
            }
        }
        .chartLegend(.hidden)
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("words per minute")
    }

    private func bigStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.system(size: 18, design: .monospaced)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 56, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .monospacedDigit()
        }
    }

    private func smallStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 20, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor.opacity(0.9))
                .monospacedDigit()
        }
    }

    static func whole(_ value: Double) -> String { "\(Int(value.rounded()))" }
}

// MARK: - History

private struct TypingTestHistoryView: View {
    @ObservedObject var service: TypingTestService
    @State private var confirmsClear = false

    var body: some View {
        let summary = service.summary
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                card("tests", "\(summary.tests)")
                card("average wpm", whole(summary.averageWPM))
                card("last \(TypingTestSummary.recentCount)", whole(summary.recentWPM))
                card("best wpm", whole(summary.bestWPM))
                card("accuracy", summary.tests == 0 ? "–" : "\(whole(summary.averageAccuracy))%")
                card("time typing", duration(summary.secondsTyping))
            }
            if service.results.count > 1 {
                trend.frame(height: 110)
            }
            if service.results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "keyboard").font(.largeTitle)
                    Text("No tests yet. Finished tests show up here.")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(service.results) {
                    TableColumn("Date") { Text($0.date.formatted(date: .abbreviated, time: .shortened)) }
                        .width(min: 140, ideal: 170)
                    TableColumn("Test") { result in
                        Text(result.mode.title).monospaced().help(result.source ?? "")
                    }
                    .width(min: 80, ideal: 100)
                    TableColumn("wpm") { Text(whole($0.wpm)).monospacedDigit().foregroundStyle(Color.accentColor) }
                        .width(min: 44, ideal: 54)
                    TableColumn("raw") { Text(whole($0.raw)).monospacedDigit() }
                        .width(min: 44, ideal: 54)
                    TableColumn("acc") { Text("\(whole($0.accuracy))%").monospacedDigit() }
                        .width(min: 50, ideal: 58)
                    TableColumn("consistency") { Text("\(whole($0.consistency))%").monospacedDigit() }
                        .width(min: 70, ideal: 84)
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: TypingTestResult.ID.self) { ids in
                    Button("Delete", role: .destructive) {
                        for result in service.results where ids.contains(result.id) { service.remove(result) }
                    }
                }
                HStack {
                    Text("Right-click a test to delete it.")
                        .font(.caption).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Clear History…") { confirmsClear = true }
                        .focusable(false)
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 20)
        .confirmationDialog("Clear all \(service.results.count) tests?", isPresented: $confirmsClear) {
            Button("Clear History", role: .destructive) { service.clearHistory() }
        } message: {
            Text("Averages and bests start over. This can't be undone.")
        }
    }

    /// Speed over the last fifty tests, oldest first.
    private var trend: some View {
        let recent = Array(service.results.prefix(50).reversed())
        return Chart {
            ForEach(Array(recent.enumerated()), id: \.element.id) { index, result in
                LineMark(x: .value("Test", index + 1), y: .value("wpm", result.wpm))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                PointMark(x: .value("Test", index + 1), y: .value("wpm", result.wpm))
                    .foregroundStyle(Color.accentColor)
                    .symbolSize(14)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxisLabel("wpm")
    }

    private func card(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.accentColor)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    private func whole(_ value: Double) -> String { "\(Int(value.rounded()))" }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m \(Int(seconds) % 60)s"
    }
}

// MARK: - Keys

enum TypingKey {
    case character(Character)
    case delete(wholeWord: Bool)
    case restart
    case escape
    case confirm
}

/// Takes every key while the test page shows, so no text field ever needs
/// focus. Keys with ⌘ or ⌃ go on to the menus (⌘W still closes).
private struct TypingKeyCatcher: NSViewRepresentable {
    let active: Bool
    @Binding var focused: Bool
    let onKey: (TypingKey) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onKey = onKey
        view.onFocus = { focused in DispatchQueue.main.async { self.focused = focused } }
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onKey = onKey
        view.active = active
        if active { view.claimFocus() }
    }

    final class CatcherView: NSView {
        var onKey: ((TypingKey) -> Void)?
        var onFocus: ((Bool) -> Void)?
        var active = true
        private var observers: [NSObjectProtocol] = []

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main) { [weak self] _ in self?.reportFocus() })
            }
            claimFocus()
        }

        func claimFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.active,
                      window.firstResponder !== self else { self?.reportFocus(); return }
                window.makeFirstResponder(self)
                self.reportFocus()
            }
        }

        private func reportFocus() {
            onFocus?(window?.isKeyWindow == true && window?.firstResponder === self)
        }

        override func becomeFirstResponder() -> Bool {
            defer { DispatchQueue.main.async { [weak self] in self?.reportFocus() } }
            return true
        }

        override func resignFirstResponder() -> Bool {
            defer { DispatchQueue.main.async { [weak self] in self?.reportFocus() } }
            return true
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            reportFocus()
        }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command) || flags.contains(.control) {
                super.keyDown(with: event)
                return
            }
            switch Int(event.keyCode) {
            case 48: onKey?(.restart)                     // Tab
            case 53: onKey?(.escape)                      // Esc
            case 36, 76: onKey?(.confirm)                 // Return, Enter
            case 51: onKey?(.delete(wholeWord: flags.contains(.option)))
            default:
                guard let characters = event.characters, !characters.isEmpty else { return }
                for character in characters where !character.isNewline {
                    onKey?(.character(character))
                }
            }
        }

        // ⌘⌫ deletes the word, as in Monkeytype.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if active, window?.firstResponder === self, flags == .command, event.keyCode == 51 {
                onKey?(.delete(wholeWord: true))
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
