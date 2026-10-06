// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import Foundation

// Fork: apps whose Back and Forward live in their own keyboard shortcuts
// rather than in a menu (Slack's ⌘[ and ⌘], for one). For an app on this
// list, the side buttons send the keys chosen for it instead of looking for
// a menu command, ahead of the browsers and exceptions that otherwise keep
// the raw buttons.

extension DefaultsKey {
    /// JSON list of `MouseNavigationAppShortcut`.
    static let mouseNavigationAppShortcuts = "mouseNavigationAppShortcuts"
}

struct MouseNavigationAppShortcut: Codable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    /// `GlobalShortcut` storage values; empty leaves that button alone.
    var back: String
    var forward: String

    var id: String { bundleID }

    func shortcut(for direction: MouseNavigationDirection) -> GlobalShortcut? {
        let raw = direction == .back ? back : forward
        guard let shortcut = GlobalShortcut(storageValue: raw, requiringModifier: false),
              MouseNavigationAppShortcuts.isUsable(shortcut) else { return nil }
        return shortcut
    }
}

enum MouseNavigationAppShortcuts {
    static let limit = 30

    /// ⌘[ and ⌘], what most apps that keep history use, ready to change.
    static func suggested(bundleID: String, name: String) -> MouseNavigationAppShortcut {
        MouseNavigationAppShortcut(
            bundleID: bundleID, name: name,
            back: GlobalShortcut(keyCode: Int64(kVK_ANSI_LeftBracket), modifiers: [.command]).storageValue,
            forward: GlobalShortcut(keyCode: Int64(kVK_ANSI_RightBracket), modifiers: [.command]).storageValue)
    }

    /// Any key that types something, with or without modifiers: an app may
    /// well go back on a plain key.
    static func isUsable(_ shortcut: GlobalShortcut) -> Bool {
        shortcut.hasUsableKeyCode && (shortcut.hasPrintableKey || !shortcut.modifiers.isEmpty)
    }

    static func decode(_ raw: String?) -> [MouseNavigationAppShortcut] {
        guard let data = raw?.data(using: .utf8),
              let list = try? JSONDecoder().decode([MouseNavigationAppShortcut].self, from: data) else { return [] }
        var seen = Set<String>()
        return Array(list.filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }.prefix(limit))
    }

    static func encode(_ list: [MouseNavigationAppShortcut]) -> String {
        String(decoding: (try? JSONEncoder().encode(Array(list.prefix(limit)))) ?? Data(), as: UTF8.self)
    }

    static func stored(in defaults: UserDefaults = .standard) -> [MouseNavigationAppShortcut] {
        decode(defaults.string(forKey: DefaultsKey.mouseNavigationAppShortcuts))
    }

    /// The keys to send for a button in the app in front, or nil when the app
    /// has no entry (or none for that button) and the usual path applies.
    static func shortcut(for direction: MouseNavigationDirection, bundleID: String?,
                         in list: [MouseNavigationAppShortcut]) -> GlobalShortcut? {
        guard let bundleID else { return nil }
        return list.first { $0.bundleID == bundleID }?.shortcut(for: direction)
    }
}
