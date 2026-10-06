// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: clipboard history lives in the Command Bar. The clipboard shortcut
// (and every "open clipboard history" button) opens the bar on its Clipboard
// list, the island drops its clipboard tab, and the list reads as one compact
// line per item. Picking an item pastes it when the app in front has a text
// field focused; anywhere else it is only copied.

extension DefaultsKey {
    static let clipboardInCommandBar = "clipboardInCommandBar"
}

enum ClipboardCommandBar {
    static let registeredDefaults: [String: Any] = [DefaultsKey.clipboardInCommandBar: true]

    /// Unset reads as off, so a defaults suite without the app's registered
    /// values keeps upstream's island tab and window.
    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: DefaultsKey.clipboardInCommandBar)
    }

    static let rowPrefix = "clipboard."

    static func isClipboardRow(_ id: String) -> Bool {
        id.hasPrefix(rowPrefix)
    }

    static func entryID(forRowID id: String) -> UUID? {
        guard isClipboardRow(id) else { return nil }
        return UUID(uuidString: String(id.dropFirst(rowPrefix.count)))
    }

    /// "now", "5m", "3h", "2d", then the day: short enough for the end of a
    /// one-line row.
    static func age(of date: Date, now: Date = Date(), calendar: Calendar = .current,
                    locale: Locale = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h" }
        if seconds < 7 * 86_400 { return "\(Int(seconds / 86_400))d" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }

    static let textRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXComboBox", "AXSecureTextField", "AXSearchField",
    ]

    /// A text role, an editable value with a caret, or (in web content) an
    /// editable ancestor all mean there is somewhere for ⌘V to land. A caret
    /// alone is not enough: a read-only page has one too.
    static func acceptsText(role: String?, subrole: String?, caretSettable: Bool,
                            valueSettable: Bool, editableAncestor: Bool) -> Bool {
        if let role, textRoles.contains(role) { return true }
        if subrole == "AXSearchField" { return true }
        return (caretSettable && valueSettable) || editableAncestor
    }
}
