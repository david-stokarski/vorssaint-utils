// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

// Fork: Selection Actions, in the spirit of PopClip. Select text with the
// pointer and a small bar of actions floats above it: copy, search, open a
// link, change the case, count, translate, or ask AI to rewrite or explain
// it. Preferences, the text transforms, the trigger rules and the bar's
// placement live here, where the tests compile them; the event monitors are
// in Services/SelectionActions and the drawing in UI/SelectionActions.

extension DefaultsKey {
    static let selectionActionsEnabled = "selectionActionsEnabled"
    /// `SelectionTriggerMode` raw value.
    static let selectionActionsTrigger = "selectionActionsTrigger"
    /// Fewer characters than this never show the bar on their own.
    static let selectionActionsMinLength = "selectionActionsMinLength"
    /// `SelectionSuppressModifier` raw value: held at mouse-up, no bar.
    static let selectionActionsSuppressModifier = "selectionActionsSuppressModifier"
    /// JSON array of `SelectionActionEntry`, the bar's order and switches.
    static let selectionActionsOrder = "selectionActionsOrder"
    /// JSON array of `SelectionCustomAction`.
    static let selectionActionsCustom = "selectionActionsCustom"
    /// `SelectionSearchEngine` raw value.
    static let selectionActionsSearchEngine = "selectionActionsSearchEngine"
    /// A search address with `%s` where the text goes, for the custom engine.
    static let selectionActionsCustomSearchURL = "selectionActionsCustomSearchURL"
    /// Bundle identifiers where the bar never appears.
    static let selectionActionsExcludedApps = "selectionActionsExcludedApps"
    /// Copy with ⌘C when Accessibility can't tell what is selected.
    static let selectionActionsClipboardFallback = "selectionActionsClipboardFallback"
    /// `GlobalShortcut` storage value; empty means no shortcut.
    static let selectionActionsShortcut = "selectionActionsShortcut"
    /// BCP-47 language code to translate into; empty means the system's.
    static let selectionActionsTranslateTarget = "selectionActionsTranslateTarget"
    /// Seconds the bar waits untouched before it goes.
    static let selectionActionsDismissDelay = "selectionActionsDismissDelay"
}

// MARK: - Trigger

enum SelectionTriggerMode: String, CaseIterable {
    /// After every mouse selection, and on the shortcut.
    case automatic
    /// Only when the shortcut asks.
    case shortcutOnly
}

enum SelectionSuppressModifier: String, CaseIterable {
    case none, option, command, control, shift

    var title: String {
        switch self {
        case .none: return "None"
        case .option: return "Option (⌥)"
        case .command: return "Command (⌘)"
        case .control: return "Control (⌃)"
        case .shift: return "Shift (⇧)"
        }
    }

    /// Whether the modifier is held in a CGEvent flags value.
    func isHeld(inEventFlags flags: UInt64) -> Bool {
        switch self {
        case .none: return false
        case .option: return flags & CGEventFlags.maskAlternate.rawValue != 0
        case .command: return flags & CGEventFlags.maskCommand.rawValue != 0
        case .control: return flags & CGEventFlags.maskControl.rawValue != 0
        case .shift: return flags & CGEventFlags.maskShift.rawValue != 0
        }
    }
}

/// What a finished click says about the selection. A press and release
/// far enough apart is a drag; a double or triple click picks a word or a
/// line. A plain click only moves the caret.
enum SelectionGesture {
    static let dragThreshold: CGFloat = 4

    static func endsSelection(down: CGPoint?, up: CGPoint, clickCount: Int) -> Bool {
        if clickCount >= 2 { return true }
        guard let down else { return false }
        return hypot(up.x - down.x, up.y - down.y) >= dragThreshold
    }
}

/// Why a selection does or doesn't get a bar. Pure, so every rule is pinned
/// by a test; the service only gathers the facts.
enum SelectionGate {
    enum Decision: Equatable {
        case show
        case empty, tooShort, tooLong, excludedApp, secureInput, ownApp, modifierHeld, disabled
    }

    static let maximumLength = 20_000

    struct Facts {
        var text: String
        var bundleID: String?
        var ownBundleID: String?
        var secureInput: Bool
        var modifierHeld: Bool = false
        /// The shortcut asked; length and the modifier don't count then.
        var explicit: Bool = false
        var enabled: Bool = true
    }

    static func decide(_ facts: Facts, minLength: Int, excluded: Set<String>) -> Decision {
        guard facts.enabled else { return .disabled }
        if facts.secureInput { return .secureInput }
        if let bundleID = facts.bundleID {
            if bundleID == facts.ownBundleID { return .ownApp }
            if excluded.contains(bundleID) { return .excludedApp }
        }
        if !facts.explicit, facts.modifierHeld { return .modifierHeld }
        let trimmed = facts.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.count > maximumLength { return .tooLong }
        if !facts.explicit, trimmed.count < max(1, minLength) { return .tooShort }
        return .show
    }
}

/// Apps where a bar would get in the way or near a secret: password
/// managers, and terminals, where selecting copies and the bar is noise.
enum SelectionExcludedApps {
    static let defaults: [String] = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.apple.Passwords", "com.apple.keychainaccess",
        "org.keepassxc.keepassxc", "com.dashlane.dashlanephonefinal", "com.lastpass.LastPass",
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "com.mitchellh.ghostty",
        "org.alacritty", "net.kovidgoyal.kitty", "com.github.wez.wezterm",
    ]

    static func current(in defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: DefaultsKey.selectionActionsExcludedApps) ?? Self.defaults
    }
}

// MARK: - Placement

enum SelectionBarPlacement {
    static let gap: CGFloat = 14
    static let margin: CGFloat = 6

    /// The bar's frame: centered on the pointer and above it, flipped below
    /// when the top of the screen is too close, and kept fully inside the
    /// visible frame. AppKit coordinates, y up.
    static func frame(size: CGSize, pointer: CGPoint, visibleFrame: CGRect,
                      gap: CGFloat = gap, margin: CGFloat = margin) -> CGRect {
        var origin = CGPoint(x: pointer.x - size.width / 2, y: pointer.y + gap)
        if origin.y + size.height > visibleFrame.maxY - margin {
            origin.y = pointer.y - gap - size.height
        }
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - margin - size.width
        origin.x = maxX < minX ? visibleFrame.midX - size.width / 2 : min(max(origin.x, minX), maxX)
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - margin - size.height
        origin.y = maxY < minY ? visibleFrame.midY - size.height / 2 : min(max(origin.y, minY), maxY)
        return CGRect(origin: origin, size: size)
    }

    /// A frame that changed size (the bar became a result) grows from the
    /// same edge it was anchored on, then is clamped again.
    static func resized(_ frame: CGRect, to size: CGSize, pointer: CGPoint, visibleFrame: CGRect) -> CGRect {
        let wasAbove = frame.minY >= pointer.y
        var origin = CGPoint(x: frame.midX - size.width / 2,
                             y: wasAbove ? frame.minY : frame.maxY - size.height)
        let minX = visibleFrame.minX + margin
        let maxX = visibleFrame.maxX - margin - size.width
        origin.x = maxX < minX ? visibleFrame.midX - size.width / 2 : min(max(origin.x, minX), maxX)
        let minY = visibleFrame.minY + margin
        let maxY = visibleFrame.maxY - margin - size.height
        origin.y = maxY < minY ? visibleFrame.midY - size.height / 2 : min(max(origin.y, minY), maxY)
        return CGRect(origin: origin, size: size)
    }
}

// MARK: - Text transforms

enum SelectionCase: String, CaseIterable, Identifiable {
    case upper, lower, title, sentence

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upper: return "UPPERCASE"
        case .lower: return "lowercase"
        case .title: return "Title Case"
        case .sentence: return "Sentence case"
        }
    }

    var shortTitle: String {
        switch self {
        case .upper: return "AB"
        case .lower: return "ab"
        case .title: return "Ab"
        case .sentence: return "Ab."
        }
    }
}

enum SelectionText {
    static func changeCase(_ text: String, to style: SelectionCase, locale: Locale = Locale(identifier: "en_US")) -> String {
        switch style {
        case .upper: return text.uppercased(with: locale)
        case .lower: return text.lowercased(with: locale)
        case .title: return titleCase(text, locale: locale)
        case .sentence: return sentenceCase(text, locale: locale)
        }
    }

    /// Every word starts with a capital and goes on in lower case. A word
    /// is a run of letters, digits and apostrophes, so "don't" stays one.
    static func titleCase(_ text: String, locale: Locale = Locale(identifier: "en_US")) -> String {
        var result = ""
        var atWordStart = true
        for character in text {
            if character.isLetter || character.isNumber {
                result += atWordStart ? String(character).uppercased(with: locale)
                                      : String(character).lowercased(with: locale)
                atWordStart = false
            } else {
                result.append(character)
                atWordStart = !(character == "'" || character == "’")
            }
        }
        return result
    }

    /// Lower case, with a capital at the start of each sentence and line,
    /// and the pronoun "I" put back.
    static func sentenceCase(_ text: String, locale: Locale = Locale(identifier: "en_US")) -> String {
        var result = ""
        var capitalizeNext = true
        var pendingEnd = false
        for character in text.lowercased(with: locale) {
            if character.isLetter || character.isNumber {
                if capitalizeNext {
                    result += String(character).uppercased(with: locale)
                    capitalizeNext = false
                } else {
                    result.append(character)
                }
                pendingEnd = false
            } else {
                result.append(character)
                if ".!?".contains(character) {
                    pendingEnd = true
                } else if character.isNewline {
                    capitalizeNext = true
                    pendingEnd = false
                } else if character.isWhitespace, pendingEnd {
                    capitalizeNext = true
                    pendingEnd = false
                } else if !(character == "\"" || character == "'" || character == ")" || character == "”") {
                    pendingEnd = false
                }
            }
        }
        return fixPronounI(result)
    }

    private static func fixPronounI(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}'’])i(?=$|[^\\p{L}\\p{N}]|['’](m|ll|d|ve)\\b)") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "I")
    }

    /// Spaces and tabs inside a line become one space, lines lose their
    /// trailing spaces, more than one blank line becomes one, and the whole
    /// text loses its wrapping whitespace. Non-breaking and zero-width
    /// spaces count as whitespace too; Windows line endings become plain.
    static func cleanWhitespace(_ text: String) -> String {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{2007}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        var lines: [String] = []
        var blankRun = 0
        for rawLine in normalized.components(separatedBy: "\n") {
            let collapsed = rawLine
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .joined(separator: " ")
            if collapsed.isEmpty {
                blankRun += 1
                if blankRun == 1 { lines.append("") }
            } else {
                blankRun = 0
                lines.append(collapsed)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct Counts: Equatable {
        var words: Int
        var characters: Int
        var lines: Int
    }

    static func counts(_ text: String) -> Counts {
        var words = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            words += 1
        }
        let lines = text.isEmpty ? 0 : text.components(separatedBy: .newlines).count
        return Counts(words: words, characters: text.count, lines: lines)
    }

    static func countSummary(_ text: String) -> String {
        let counts = counts(text)
        func plural(_ value: Int, _ noun: String) -> String {
            "\(value.formatted()) \(noun)\(value == 1 ? "" : "s")"
        }
        var parts = [plural(counts.words, "word"), plural(counts.characters, "character")]
        if counts.lines > 1 { parts.append(plural(counts.lines, "line")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Links and search

enum SelectionURL {
    static let maximumLength = 2048

    /// Endings common enough that "word.word" is a site, not a file name.
    static let knownTopLevelDomains: Set<String> = [
        "com", "org", "net", "io", "dev", "app", "ai", "co", "edu", "gov", "me", "info", "xyz", "tech",
        "sh", "so", "gg", "tv", "fm", "ly", "to", "us", "uk", "de", "fr", "es", "it", "nl", "be", "ch",
        "at", "se", "no", "dk", "fi", "pl", "pt", "cz", "ie", "ca", "au", "nz", "jp", "cn", "in", "br",
        "mx", "ru", "kr", "eu", "page", "site", "blog", "cloud", "link", "news",
    ]

    /// The address the selection names, when it is one and nothing else: a
    /// full address with a scheme, or a bare domain with a familiar ending.
    static func url(from text: String) -> URL? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.count <= maximumLength,
              candidate.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let wrappers: [(Character, Character)] = [("<", ">"), ("(", ")"), ("\"", "\""), ("'", "'"), ("[", "]")]
        // "<https://example.org>." loses its full stop, then its brackets.
        var changed = true
        while changed, !candidate.isEmpty {
            changed = false
            if let last = candidate.last, ".,;:!?".contains(last) || (last == ")" && !candidate.contains("(")) {
                candidate.removeLast()
                changed = true
            }
            for (open, close) in wrappers where candidate.count > 2 && candidate.first == open && candidate.last == close {
                candidate = String(candidate.dropFirst().dropLast())
                changed = true
            }
        }
        guard !candidate.isEmpty else { return nil }

        let lower = candidate.lowercased()
        if let schemeEnd = lower.range(of: "://") {
            let scheme = lower[..<schemeEnd.lowerBound]
            guard ["http", "https", "ftp"].contains(scheme),
                  let url = URL(string: candidate), let host = url.host, !host.isEmpty else { return nil }
            return url
        }
        if lower.hasPrefix("mailto:") {
            return candidate.count > 8 && candidate.contains("@") ? URL(string: candidate) : nil
        }
        guard !candidate.contains("@") else { return nil }
        let hostPart = lower.split(separator: "/", maxSplits: 1).first.map(String.init) ?? lower
        let host = hostPart.split(separator: ":", maxSplits: 1).first.map(String.init) ?? hostPart
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return nil }
        let tld = String(labels.last!)
        let isWWW = labels.first == "www"
        guard isWWW || knownTopLevelDomains.contains(tld) else { return nil }
        return URL(string: "https://" + candidate)
    }
}

enum SelectionSearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, bing, kagi, perplexity, startpage, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .kagi: return "Kagi"
        case .perplexity: return "Perplexity"
        case .startpage: return "Startpage"
        case .custom: return "Custom"
        }
    }

    var template: String {
        switch self {
        case .google: return "https://www.google.com/search?q=%s"
        case .duckDuckGo: return "https://duckduckgo.com/?q=%s"
        case .bing: return "https://www.bing.com/search?q=%s"
        case .kagi: return "https://kagi.com/search?q=%s"
        case .perplexity: return "https://www.perplexity.ai/search?q=%s"
        case .startpage: return "https://www.startpage.com/do/search?query=%s"
        case .custom: return ""
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> SelectionSearchEngine {
        defaults.string(forKey: DefaultsKey.selectionActionsSearchEngine).flatMap(Self.init(rawValue:)) ?? .google
    }

    /// A custom template is used when it holds `%s` and opens as a web
    /// address; anything else searches Google instead.
    static func searchURL(for text: String, engine: SelectionSearchEngine, customTemplate: String = "") -> URL? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        var template = engine.template
        if engine == .custom {
            let custom = customTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
            template = isUsableTemplate(custom) ? custom : SelectionSearchEngine.google.template
        }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/;:@$,")
        guard let encoded = query.prefix(2000).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    static func isUsableTemplate(_ template: String) -> Bool {
        guard template.contains("%s"),
              let url = URL(string: template.replacingOccurrences(of: "%s", with: "q")),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host?.isEmpty == false else { return false }
        return true
    }
}

// MARK: - Actions

/// The built-in actions. Raw values persist in the order list, so cases can
/// be added but never renamed.
enum SelectionActionID: String, CaseIterable, Identifiable {
    case copy, search, openURL, changeCase, cleanWhitespace, count, translate
    case rewrite, fixGrammar, shorter, friendlier, explain, sendToChat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copy: return "Copy"
        case .search: return "Search the Web"
        case .openURL: return "Open Link"
        case .changeCase: return "Change Case"
        case .cleanWhitespace: return "Clean Whitespace"
        case .count: return "Count Words"
        case .translate: return "Translate"
        case .rewrite: return "Rewrite"
        case .fixGrammar: return "Fix Grammar"
        case .shorter: return "Make Shorter"
        case .friendlier: return "Make Friendlier"
        case .explain: return "Explain"
        case .sendToChat: return "Send to AI Chat"
        }
    }

    var symbolName: String {
        switch self {
        case .copy: return "doc.on.doc"
        case .search: return "magnifyingglass"
        case .openURL: return "safari"
        case .changeCase: return "textformat"
        case .cleanWhitespace: return "text.justify.left"
        case .count: return "number"
        case .translate: return "character.bubble"
        case .rewrite: return "pencil.and.outline"
        case .fixGrammar: return "checkmark.seal"
        case .shorter: return "arrow.down.right.and.arrow.up.left"
        case .friendlier: return "face.smiling"
        case .explain: return "questionmark.bubble"
        case .sendToChat: return "bubble.left.and.bubble.right"
        }
    }

    var usesAI: Bool {
        switch self {
        case .rewrite, .fixGrammar, .shorter, .friendlier, .explain: return true
        default: return false
        }
    }

    var enabledByDefault: Bool {
        switch self {
        case .shorter, .friendlier: return false
        default: return true
        }
    }

    /// The instruction an AI action sends; the selection follows it.
    var aiPrompt: String? {
        switch self {
        case .rewrite:
            return "Rewrite the following text so it reads clearly and naturally. Keep its meaning, language and tone.\n\n{{text}}"
        case .fixGrammar:
            return "Correct the spelling, grammar and punctuation of the following text. Change nothing else, and keep its language.\n\n{{text}}"
        case .shorter:
            return "Make the following text shorter and more concise, keeping what matters and its language.\n\n{{text}}"
        case .friendlier:
            return "Rewrite the following text in a warmer, friendlier tone, keeping its meaning and language.\n\n{{text}}"
        case .explain:
            return "Explain the following text briefly and plainly. If it is a term, code or a reference, say what it means.\n\n{{text}}"
        default:
            return nil
        }
    }

    /// Whether a result of this action can stand in for the selection.
    var resultReplacesSelection: Bool { self != .explain }
}

/// A user's own action: a prompt for AI, a Shortcut from the Shortcuts app,
/// or one of the Command Bar's saved scripts.
struct SelectionCustomAction: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case aiPrompt, shortcut, script

        var title: String {
            switch self {
            case .aiPrompt: return "AI Prompt"
            case .shortcut: return "Shortcut"
            case .script: return "Command Bar Script"
            }
        }

        var symbolName: String {
            switch self {
            case .aiPrompt: return "sparkles"
            case .shortcut: return "square.2.layers.3d"
            case .script: return "terminal"
            }
        }
    }

    var id = UUID()
    var name = ""
    var kind = Kind.aiPrompt
    /// The prompt template, the Shortcut's name, or the script link's id.
    var value = ""
    /// Whether the result can be pasted over the selection.
    var replaces = true

    var actionKey: String { "custom:\(id.uuidString)" }

    var isUsable: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func decode(_ raw: String?) -> [SelectionCustomAction] {
        guard let data = raw?.data(using: .utf8),
              let actions = try? JSONDecoder().decode([SelectionCustomAction].self, from: data) else { return [] }
        return actions
    }

    static func encode(_ actions: [SelectionCustomAction]) -> String {
        guard let data = try? JSONEncoder().encode(actions) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func current(in defaults: UserDefaults = .standard) -> [SelectionCustomAction] {
        decode(defaults.string(forKey: DefaultsKey.selectionActionsCustom))
    }
}

/// One slot of the bar: a built-in or custom action, and its switch.
struct SelectionActionEntry: Codable, Equatable, Identifiable {
    /// A `SelectionActionID` raw value or a custom action's `actionKey`.
    var key: String
    var enabled: Bool

    var id: String { key }

    var builtIn: SelectionActionID? { SelectionActionID(rawValue: key) }

    var customID: UUID? {
        guard key.hasPrefix("custom:") else { return nil }
        return UUID(uuidString: String(key.dropFirst("custom:".count)))
    }
}

enum SelectionActionOrder {
    static var defaults: [SelectionActionEntry] {
        SelectionActionID.allCases.map { SelectionActionEntry(key: $0.rawValue, enabled: $0.enabledByDefault) }
    }

    /// The saved order, cleaned: unknown and repeated keys go, custom
    /// actions that no longer exist go, and anything new (a built-in added
    /// by an update, a custom action just made) joins at the end, on.
    static func resolve(_ raw: String?, custom: [SelectionCustomAction]) -> [SelectionActionEntry] {
        var saved: [SelectionActionEntry] = []
        if let data = raw?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([SelectionActionEntry].self, from: data) {
            saved = decoded
        } else {
            saved = defaults
        }
        let customKeys = Set(custom.map(\.actionKey))
        var seen = Set<String>()
        var result: [SelectionActionEntry] = []
        for entry in saved where !seen.contains(entry.key) {
            guard entry.builtIn != nil || customKeys.contains(entry.key) else { continue }
            seen.insert(entry.key)
            result.append(entry)
        }
        for id in SelectionActionID.allCases where !seen.contains(id.rawValue) {
            result.append(SelectionActionEntry(key: id.rawValue, enabled: id.enabledByDefault))
            seen.insert(id.rawValue)
        }
        for action in custom where !seen.contains(action.actionKey) {
            result.append(SelectionActionEntry(key: action.actionKey, enabled: true))
            seen.insert(action.actionKey)
        }
        return result
    }

    static func encode(_ entries: [SelectionActionEntry]) -> String {
        guard let data = try? JSONEncoder().encode(entries) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func current(in defaults: UserDefaults = .standard) -> [SelectionActionEntry] {
        resolve(defaults.string(forKey: DefaultsKey.selectionActionsOrder),
                custom: SelectionCustomAction.current(in: defaults))
    }

    static func moved(_ entries: [SelectionActionEntry], from index: Int, by offset: Int) -> [SelectionActionEntry] {
        let target = index + offset
        guard entries.indices.contains(index), entries.indices.contains(target) else { return entries }
        var copy = entries
        copy.swapAt(index, target)
        return copy
    }

    /// Whether the action has anything to offer for this text: a link to
    /// open, whitespace to clean.
    static func isApplicable(_ id: SelectionActionID, to text: String) -> Bool {
        switch id {
        case .openURL: return SelectionURL.url(from: text) != nil
        case .cleanWhitespace: return SelectionText.cleanWhitespace(text) != text
        default: return true
        }
    }
}

// MARK: - Prompts

enum SelectionPromptTemplate {
    static let placeholder = "{{text}}"
    static let languagePlaceholder = "{{language}}"

    /// The prompt with the selection put where `{{text}}` stands, or after
    /// it when the template has no placeholder. `{{language}}` becomes the
    /// translation language.
    static func render(_ template: String, text: String, language: String = "English") -> String {
        var prompt = template.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = prompt.replacingOccurrences(of: languagePlaceholder, with: language)
        if prompt.contains(placeholder) {
            return prompt.replacingOccurrences(of: placeholder, with: text)
        }
        return prompt.isEmpty ? text : prompt + "\n\n" + text
    }

    static let transformSystem = """
        You transform text the user selected in another app. Reply with only the resulting text: \
        no preamble, no explanation, no quotation marks around it, and no Markdown unless the input used it.
        """

    static let explainSystem = """
        You explain text the user selected in another app. Be brief and plain: a few sentences, \
        or a short list when that is clearer.
        """

    static func translatePrompt(language: String) -> String {
        "Translate the following text into \(language). Keep its formatting.\n\n\(placeholder)"
    }

    /// AI replies sometimes wrap the answer in quotes or a code fence even
    /// when asked not to; a reply meant to replace the selection drops them.
    static func cleanedReply(_ reply: String) -> String {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count > 6 {
            text = String(text.dropFirst(3).dropLast(3))
            if let newline = text.firstIndex(of: "\n"), !text[..<newline].contains(" ") {
                text = String(text[text.index(after: newline)...])
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (open, close) in [("\"", "\""), ("“", "”")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 2 {
            let inner = String(text.dropFirst().dropLast())
            if !inner.contains(open) { text = inner }
        }
        return text
    }
}

// MARK: - Translation

enum SelectionTranslation {
    /// Languages offered as targets, by code and English name.
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("it", "Italian"),
        ("pt", "Portuguese"), ("nl", "Dutch"), ("pl", "Polish"), ("uk", "Ukrainian"), ("ru", "Russian"),
        ("tr", "Turkish"), ("ar", "Arabic"), ("hi", "Hindi"), ("id", "Indonesian"), ("th", "Thai"),
        ("vi", "Vietnamese"), ("ja", "Japanese"), ("ko", "Korean"), ("zh-Hans", "Chinese (Simplified)"),
        ("zh-Hant", "Chinese (Traditional)"),
    ]

    /// The saved target, or the first of the user's languages, or English.
    static func targetCode(saved: String?, preferred: [String] = Locale.preferredLanguages) -> String {
        if let saved, !saved.isEmpty { return saved }
        guard let first = preferred.first else { return "en" }
        let code = first.split(separator: "-").first.map(String.init) ?? first
        if code == "zh" { return first.contains("Hant") || first.contains("TW") || first.contains("HK") ? "zh-Hant" : "zh-Hans" }
        return code.isEmpty ? "en" : code
    }

    static func name(for code: String) -> String {
        languages.first { $0.code == code }?.name
            ?? Locale(identifier: "en_US").localizedString(forIdentifier: code) ?? code
    }
}

enum SelectionActionsSupport {
    static let title = "Selection Actions"
    static let hubDescription = "Select text with the pointer and a small bar offers to copy, search, open a link, change the case, translate, or have AI rewrite or explain it."

    static let defaultDismissDelay = 6.0
    static let dismissDelayRange: ClosedRange<Double> = 2...20
    static let minLengthRange: ClosedRange<Int> = 1...50

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.selectionActionsEnabled: true,
        DefaultsKey.selectionActionsTrigger: SelectionTriggerMode.automatic.rawValue,
        DefaultsKey.selectionActionsMinLength: 2,
        DefaultsKey.selectionActionsSuppressModifier: SelectionSuppressModifier.none.rawValue,
        DefaultsKey.selectionActionsOrder: SelectionActionOrder.encode(SelectionActionOrder.defaults),
        DefaultsKey.selectionActionsCustom: "[]",
        DefaultsKey.selectionActionsSearchEngine: SelectionSearchEngine.google.rawValue,
        DefaultsKey.selectionActionsCustomSearchURL: "",
        DefaultsKey.selectionActionsExcludedApps: SelectionExcludedApps.defaults,
        DefaultsKey.selectionActionsClipboardFallback: false,
        DefaultsKey.selectionActionsShortcut: "",
        DefaultsKey.selectionActionsTranslateTarget: "",
        DefaultsKey.selectionActionsDismissDelay: defaultDismissDelay,
    ]

    static func minLength(in defaults: UserDefaults = .standard) -> Int {
        let value = defaults.object(forKey: DefaultsKey.selectionActionsMinLength) as? Int ?? 2
        return min(max(value, minLengthRange.lowerBound), minLengthRange.upperBound)
    }

    static func dismissDelay(in defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.object(forKey: DefaultsKey.selectionActionsDismissDelay) as? Double ?? defaultDismissDelay
        return min(max(value, dismissDelayRange.lowerBound), dismissDelayRange.upperBound)
    }
}
