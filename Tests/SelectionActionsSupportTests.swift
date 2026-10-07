// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Fork: Selection Actions. The text transforms do what their names say,
/// a link is told from a file name, the bar only appears where it should,
/// stays on screen, and prompts carry the selection where they ask for it.
enum SelectionActionsSupportTests {
    static func run(_ suite: TestSuite) {
        cases(suite)
        whitespace(suite)
        counts(suite)
        urls(suite)
        search(suite)
        gating(suite)
        gesture(suite)
        placement(suite)
        prompts(suite)
        order(suite)
        translation(suite)
    }

    private static func cases(_ suite: TestSuite) {
        let text = "the QUICK brown fox. it jumps! don't stop"
        suite.expect(SelectionText.changeCase(text, to: .upper) == "THE QUICK BROWN FOX. IT JUMPS! DON'T STOP",
                     "upper case raises every letter")
        suite.expect(SelectionText.changeCase(text, to: .lower) == "the quick brown fox. it jumps! don't stop",
                     "lower case lowers every letter")
        suite.expect(SelectionText.changeCase(text, to: .title) == "The Quick Brown Fox. It Jumps! Don't Stop",
                     "title case capitalizes each word and keeps an apostrophe inside it")
        suite.expect(SelectionText.changeCase(text, to: .sentence) == "The quick brown fox. It jumps! Don't stop",
                     "sentence case capitalizes after a full stop or an exclamation")
        suite.expect(SelectionText.changeCase("WHAT DO I KNOW? i'm not sure.\nnext LINE", to: .sentence)
                        == "What do I know? I'm not sure.\nNext line",
                     "sentence case puts the pronoun I back and starts each line with a capital")
        suite.expect(SelectionText.changeCase("hello-world and e.g. stuff", to: .title) == "Hello-World And E.G. Stuff",
                     "title case treats a hyphen or a dot as a word break")
        suite.expect(SelectionText.changeCase("version 2.0 is out. great", to: .sentence) == "Version 2.0 is out. Great",
                     "a dot inside a number does not start a sentence")
        suite.expect(SelectionText.changeCase("", to: .title).isEmpty, "empty text stays empty")
    }

    private static func whitespace(_ suite: TestSuite) {
        suite.expect(SelectionText.cleanWhitespace("  a   b\t\tc  ") == "a b c", "runs of spaces and tabs become one space")
        suite.expect(SelectionText.cleanWhitespace("one  \n\n\n\ntwo\r\nthree") == "one\n\ntwo\nthree",
                     "blank lines collapse to one and Windows endings become plain")
        suite.expect(SelectionText.cleanWhitespace("a\u{00A0}\u{00A0}b\u{200B}c") == "a bc",
                     "non-breaking spaces count as spaces and zero-width ones go")
        suite.expect(SelectionText.cleanWhitespace("tidy text") == "tidy text", "tidy text is left alone")
        suite.expect(!SelectionActionOrder.isApplicable(.cleanWhitespace, to: "tidy text"),
                     "clean whitespace is not offered for tidy text")
        suite.expect(SelectionActionOrder.isApplicable(.cleanWhitespace, to: "messy  text"),
                     "and is offered when there is something to clean")
    }

    private static func counts(_ suite: TestSuite) {
        let counts = SelectionText.counts("Hello, world! It's a test.\nSecond line")
        suite.expect(counts.words == 7, "words are counted the way the system breaks them (got \(counts.words))")
        suite.expect(counts.characters == 38, "characters count every visible one and the newline (got \(counts.characters))")
        suite.expect(counts.lines == 2, "lines are counted")
        suite.expect(SelectionText.countSummary("one") == "1 word · 3 characters", "a single word reads in the singular")
        suite.expect(SelectionText.countSummary("a b\nc").hasSuffix("2 lines"), "more than one line is mentioned")
    }

    private static func urls(_ suite: TestSuite) {
        suite.expect(SelectionURL.url(from: "https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1",
                     "a full address is a link")
        suite.expect(SelectionURL.url(from: "  example.com/path ")?.absoluteString == "https://example.com/path",
                     "a bare domain with a familiar ending opens over https")
        suite.expect(SelectionURL.url(from: "www.something.weird")?.absoluteString == "https://www.something.weird",
                     "www. makes any ending a site")
        suite.expect(SelectionURL.url(from: "<https://example.org>.")?.host == "example.org",
                     "wrapping brackets and trailing punctuation are dropped")
        suite.expect(SelectionURL.url(from: "(see.dev)")?.host == "see.dev", "parentheses around a domain are dropped")
        suite.expect(SelectionURL.url(from: "hello world") == nil, "words are not a link")
        suite.expect(SelectionURL.url(from: "notes.txt") == nil, "a file name is not a link")
        suite.expect(SelectionURL.url(from: "someone@example.com") == nil, "an email address is not a web link")
        suite.expect(SelectionURL.url(from: "javascript://alert(1)") == nil, "only web schemes open")
        suite.expect(SelectionURL.url(from: "file:///etc/passwd") == nil, "a file URL does not open")
        suite.expect(SelectionURL.url(from: "mailto:a@b.co")?.scheme == "mailto", "a mailto link opens")
        suite.expect(SelectionURL.url(from: "1.5") == nil, "a decimal number is not a link")
        suite.expect(SelectionActionOrder.isApplicable(.openURL, to: "apple.com"), "open link is offered for a domain")
        suite.expect(!SelectionActionOrder.isApplicable(.openURL, to: "apple pie"), "and not for prose")
    }

    private static func search(_ suite: TestSuite) {
        let url = SelectionSearchEngine.searchURL(for: " swift & c++ ", engine: .duckDuckGo)
        suite.expect(url?.absoluteString == "https://duckduckgo.com/?q=swift%20%26%20c%2B%2B",
                     "the query is escaped so & and + stay in it (got \(url?.absoluteString ?? "nil"))")
        let custom = SelectionSearchEngine.searchURL(for: "cats", engine: .custom,
                                                     customTemplate: "https://example.com/find?term=%s")
        suite.expect(custom?.absoluteString == "https://example.com/find?term=cats", "a custom template is filled in")
        let broken = SelectionSearchEngine.searchURL(for: "cats", engine: .custom, customTemplate: "no placeholder")
        suite.expect(broken?.host == "www.google.com", "a custom template without %s searches Google instead")
        suite.expect(!SelectionSearchEngine.isUsableTemplate("javascript:%s"), "a custom template must be a web address")
        suite.expect(SelectionSearchEngine.searchURL(for: "   ", engine: .google) == nil, "blank text searches nothing")
    }

    private static func gating(_ suite: TestSuite) {
        let excluded: Set<String> = ["com.1password.1password"]
        func decide(_ text: String, app: String? = "com.apple.Safari", secure: Bool = false, modifier: Bool = false,
                    explicit: Bool = false, minLength: Int = 3) -> SelectionGate.Decision {
            SelectionGate.decide(SelectionGate.Facts(text: text, bundleID: app, ownBundleID: "com.vorssaint.utils",
                                                     secureInput: secure, modifierHeld: modifier, explicit: explicit),
                                 minLength: minLength, excluded: excluded)
        }
        suite.expect(decide("hello") == .show, "a selection in an ordinary app shows the bar")
        suite.expect(decide("   \n ") == .empty, "whitespace alone is not a selection")
        suite.expect(decide("") == .empty, "nothing selected shows nothing")
        suite.expect(decide("ab") == .tooShort, "a selection under the minimum length shows nothing")
        suite.expect(decide("  ab  ", minLength: 3) == .tooShort, "the minimum counts without the wrapping spaces")
        suite.expect(decide("ab", explicit: true) == .show, "the shortcut shows the bar for a short selection")
        suite.expect(decide("hello", app: "com.1password.1password") == .excludedApp, "an excluded app never shows the bar")
        suite.expect(decide("hello", app: "com.1password.1password", explicit: true) == .excludedApp,
                     "not even from the shortcut")
        suite.expect(decide("hello", secure: true) == .secureInput, "secure input never shows the bar")
        suite.expect(decide("hello", secure: true, explicit: true) == .secureInput, "not even from the shortcut")
        suite.expect(decide("hello", app: "com.vorssaint.utils") == .ownApp, "the app's own windows never show it")
        suite.expect(decide("hello", modifier: true) == .modifierHeld, "the suppress modifier hides the bar")
        suite.expect(decide("hello", modifier: true, explicit: true) == .show, "but not the shortcut's")
        suite.expect(decide(String(repeating: "a", count: SelectionGate.maximumLength + 1)) == .tooLong,
                     "a whole document is not a selection to act on")
        var off = SelectionGate.Facts(text: "hello", bundleID: nil, ownBundleID: nil, secureInput: false)
        off.enabled = false
        suite.expect(SelectionGate.decide(off, minLength: 1, excluded: []) == .disabled, "a disabled feature shows nothing")
        suite.expect(SelectionExcludedApps.defaults.contains("com.1password.1password")
                        && SelectionExcludedApps.defaults.contains("com.apple.Terminal"),
                     "password managers and terminals are excluded out of the box")
        let option = CGEventFlags.maskAlternate.rawValue
        suite.expect(SelectionSuppressModifier.option.isHeld(inEventFlags: option), "option is read from event flags")
        suite.expect(!SelectionSuppressModifier.command.isHeld(inEventFlags: option), "other modifiers are not")
        suite.expect(!SelectionSuppressModifier.none.isHeld(inEventFlags: UInt64.max), "none never suppresses")
    }

    private static func gesture(_ suite: TestSuite) {
        suite.expect(SelectionGesture.endsSelection(down: CGPoint(x: 10, y: 10), up: CGPoint(x: 60, y: 12), clickCount: 1),
                     "a drag ends a selection")
        suite.expect(!SelectionGesture.endsSelection(down: CGPoint(x: 10, y: 10), up: CGPoint(x: 11, y: 11), clickCount: 1),
                     "a plain click only moves the caret")
        suite.expect(SelectionGesture.endsSelection(down: CGPoint(x: 10, y: 10), up: CGPoint(x: 10, y: 10), clickCount: 2),
                     "a double click selects a word")
        suite.expect(SelectionGesture.endsSelection(down: nil, up: .zero, clickCount: 3), "a triple click selects a line")
        suite.expect(!SelectionGesture.endsSelection(down: nil, up: .zero, clickCount: 1),
                     "a release without its press is not a selection")
    }

    private static func placement(_ suite: TestSuite) {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let size = CGSize(width: 200, height: 36)
        let middle = SelectionBarPlacement.frame(size: size, pointer: CGPoint(x: 500, y: 400), visibleFrame: screen)
        suite.expect(middle.minY > 400 && abs(middle.midX - 500) < 0.5, "the bar sits centered above the pointer")
        let top = SelectionBarPlacement.frame(size: size, pointer: CGPoint(x: 500, y: 790), visibleFrame: screen)
        suite.expect(top.maxY < 790 && screen.contains(top), "near the top it flips below the pointer")
        let left = SelectionBarPlacement.frame(size: size, pointer: CGPoint(x: 5, y: 400), visibleFrame: screen)
        suite.expect(left.minX >= screen.minX + SelectionBarPlacement.margin, "it never leaves the left edge")
        let right = SelectionBarPlacement.frame(size: size, pointer: CGPoint(x: 998, y: 400), visibleFrame: screen)
        suite.expect(right.maxX <= screen.maxX - SelectionBarPlacement.margin, "or the right edge")
        let second = CGRect(x: 1000, y: -200, width: 800, height: 600)
        let onSecond = SelectionBarPlacement.frame(size: size, pointer: CGPoint(x: 1790, y: -195), visibleFrame: second)
        suite.expect(second.contains(onSecond), "on a second display with an offset origin it stays inside that display")
        let huge = SelectionBarPlacement.frame(size: CGSize(width: 1200, height: 900), pointer: CGPoint(x: 10, y: 10),
                                               visibleFrame: screen)
        suite.expect(abs(huge.midX - screen.midX) < 0.5 && abs(huge.midY - screen.midY) < 0.5,
                     "something bigger than the screen is centered on it")
        let grown = SelectionBarPlacement.resized(middle, to: CGSize(width: 360, height: 220),
                                                  pointer: CGPoint(x: 500, y: 400), visibleFrame: screen)
        suite.expect(abs(grown.minY - middle.minY) < 0.5 && screen.contains(grown),
                     "a result above the pointer grows upward from the bar's place")
        let grownLow = SelectionBarPlacement.resized(top, to: CGSize(width: 360, height: 220),
                                                     pointer: CGPoint(x: 500, y: 790), visibleFrame: screen)
        suite.expect(abs(grownLow.maxY - top.maxY) < 0.5, "a result below the pointer grows downward")
    }

    private static func prompts(_ suite: TestSuite) {
        suite.expect(SelectionPromptTemplate.render("Summarize: {{text}}", text: "abc") == "Summarize: abc",
                     "the selection goes where {{text}} stands")
        suite.expect(SelectionPromptTemplate.render("Summarize this", text: "abc") == "Summarize this\n\nabc",
                     "a template without the placeholder gets the selection after it")
        suite.expect(SelectionPromptTemplate.render("A {{text}} B {{text}}", text: "x") == "A x B x",
                     "every placeholder is filled")
        suite.expect(SelectionPromptTemplate.render("Into {{language}}: {{text}}", text: "hola", language: "German")
                        == "Into German: hola",
                     "{{language}} becomes the translation language")
        suite.expect(SelectionPromptTemplate.render("  ", text: "abc") == "abc", "an empty template sends the text alone")
        suite.expect(SelectionPromptTemplate.render("{{text}}", text: "has {{language}} in it", language: "French")
                        == "has {{language}} in it",
                     "placeholders inside the selection are not expanded")
        suite.expect(SelectionActionID.allCases.filter(\.usesAI).allSatisfy { $0.aiPrompt?.contains("{{text}}") == true },
                     "every built-in AI action carries the selection")
        suite.expect(SelectionPromptTemplate.cleanedReply("\"Fixed text.\"") == "Fixed text.", "wrapping quotes are dropped")
        suite.expect(SelectionPromptTemplate.cleanedReply("```swift\nlet a = 1\n```") == "let a = 1",
                     "a code fence around the whole reply is dropped")
        suite.expect(SelectionPromptTemplate.cleanedReply("He said \"hi\" and \"bye\"") == "He said \"hi\" and \"bye\"",
                     "quotes inside the reply stay")
    }

    private static func order(_ suite: TestSuite) {
        let custom = SelectionCustomAction(name: "Summarize", kind: .aiPrompt, value: "Summarize {{text}}")
        let resolved = SelectionActionOrder.resolve(nil, custom: [custom])
        suite.expect(resolved.count == SelectionActionID.allCases.count + 1, "defaults plus the custom action")
        suite.expect(resolved.last?.key == custom.actionKey, "a new custom action joins at the end")
        suite.expect(resolved.first { $0.key == SelectionActionID.shorter.rawValue }?.enabled == false,
                     "the less common AI actions start off")
        let saved = SelectionActionOrder.encode([
            SelectionActionEntry(key: "explain", enabled: false),
            SelectionActionEntry(key: "copy", enabled: true),
            SelectionActionEntry(key: "copy", enabled: false),
            SelectionActionEntry(key: "gone", enabled: true),
            SelectionActionEntry(key: "custom:\(UUID().uuidString)", enabled: true),
        ])
        let merged = SelectionActionOrder.resolve(saved, custom: [])
        suite.expect(merged.prefix(2).map(\.key) == ["explain", "copy"], "the saved order comes first")
        suite.expect(merged.first?.enabled == false, "and keeps its switches")
        suite.expect(merged.filter { $0.key == "copy" }.count == 1, "a repeated key appears once")
        suite.expect(!merged.contains { $0.key == "gone" || $0.customID != nil },
                     "unknown keys and deleted custom actions go")
        suite.expect(Set(merged.map(\.key)) == Set(SelectionActionID.allCases.map(\.rawValue)),
                     "built-ins missing from an old order are added")
        let moved = SelectionActionOrder.moved(merged, from: 0, by: 1)
        suite.expect(moved.prefix(2).map(\.key) == ["copy", "explain"], "moving swaps neighbours")
        suite.expect(SelectionActionOrder.moved(merged, from: 0, by: -1) == merged, "moving past the start does nothing")
        let roundTrip = SelectionCustomAction.decode(SelectionCustomAction.encode([custom]))
        suite.expect(roundTrip == [custom], "custom actions round-trip through storage")
        suite.expect(!SelectionCustomAction(name: " ", kind: .shortcut, value: "x").isUsable, "a nameless action is unusable")
    }

    private static func translation(_ suite: TestSuite) {
        suite.expect(SelectionTranslation.targetCode(saved: "de") == "de", "a saved target wins")
        suite.expect(SelectionTranslation.targetCode(saved: "", preferred: ["fr-CA", "en"]) == "fr",
                     "otherwise the first preferred language")
        suite.expect(SelectionTranslation.targetCode(saved: nil, preferred: ["zh-Hant-TW"]) == "zh-Hant",
                     "traditional Chinese is told from simplified")
        suite.expect(SelectionTranslation.targetCode(saved: nil, preferred: []) == "en", "English when nothing is known")
        suite.expect(SelectionTranslation.name(for: "ja") == "Japanese", "languages are named in English for prompts")
        let defaults = SelectionActionsSupport.registeredDefaults
        suite.expect(defaults[DefaultsKey.selectionActionsClipboardFallback] as? Bool == false,
                     "the clipboard fallback starts off")
        suite.expect((defaults[DefaultsKey.selectionActionsExcludedApps] as? [String])?.isEmpty == false,
                     "the excluded apps have a default list")
        suite.expect(SettingsBackupSupport.exportKeys().isSuperset(of: Set(defaults.keys)),
                     "every selection preference travels in a settings backup")
    }
}
