// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: the hyper key and the app shortcuts it drives, on the Command Bar's
/// page, where a Raycast-style launcher keeps them. The key itself is the
/// Super Key feature (any chosen key held as ⌃⌥⇧⌘); the shortcuts are the
/// bar's per-app shortcuts.
struct CommandBarHyperKeySection: View {
    @ObservedObject private var features = FeatureRuntime.shared
    @ObservedObject private var superKey = SuperKeyService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.superKeyEnabled) private var enabled = false
    @AppStorage(DefaultsKey.superKeySource) private var source = SuperKeySource.capsLock.rawValue
    @AppStorage(DefaultsKey.commandBarRowShortcuts) private var shortcutsRaw = ""
    let openAppShortcuts: () -> Void

    private var isOn: Bool { AppFeature.superKey.isAvailable && enabled }

    var body: some View {
        Section {
            Toggle("Hyper key", isOn: Binding(get: { isOn }, set: setHyper))
            if isOn {
                Picker("Key", selection: $source) {
                    ForEach(SuperKeySource.allCases) { key in
                        Label(Self.name(key), systemImage: key.systemImage).tag(key.rawValue)
                    }
                }
                .onChange(of: source) { _, _ in SuperKeyService.shared.syncWithPreferences() }
                if let failure = superKey.mappingFailure {
                    Label(FeatureStrings.superKey(l10n.language).mappingFailure(failure),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !permissions.accessibility { PermissionRow(kind: .accessibility) }
            }
            Text("Holding the hyper key presses ⌃⌥⇧⌘ at once, shown as ✧ in shortcuts. Give an app a shortcut below by pressing the hyper key with a letter, so ✧A can open Chrome. Click a shortcut to change it, or ✕ to remove it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            let apps = Self.appShortcuts(CommandBarRowShortcuts.decode(shortcutsRaw))
            if !apps.isEmpty {
                ForEach(apps, id: \.key) { entry in
                    CommandBarShortcutRow(key: entry.key, shortcut: entry.binding) {
                        HStack(spacing: 8) {
                            if let icon = entry.icon {
                                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            }
                            Text(entry.name).lineLimit(1)
                        }
                    }
                }
            }
            // Changing and removing happen in the rows above; the app list is
            // where a new app gets one, with names and pins beside it.
            Button("Add App Shortcut…", action: openAppShortcuts)
        } header: {
            Text("Hyper Key & App Shortcuts")
        }
    }

    private func setHyper(_ on: Bool) {
        if on, !AppFeature.superKey.isAvailable {
            FeatureRuntime.shared.setAvailable([.superKey], true)
        }
        enabled = on
        SuperKeyService.shared.syncWithPreferences()
        if on, !permissions.accessibility { permissions.requestAccessibility() }
    }

    static func name(_ key: SuperKeySource) -> String {
        switch key {
        case .capsLock: return "Caps Lock"
        case .rightCommand: return "Right ⌘"
        case .rightOption: return "Right ⌥"
        case .rightControl: return "Right ⌃"
        case .rightShift: return "Right ⇧"
        }
    }

    struct AppShortcut {
        let key: String
        let name: String
        let icon: NSImage?
        let shortcut: String
        let binding: GlobalShortcut
    }

    /// The shortcuts bound to apps, by name, with ⌃⌥⇧⌘ read as Hyper.
    static func appShortcuts(_ shortcuts: [String: GlobalShortcut]) -> [AppShortcut] {
        shortcuts.compactMap { key, shortcut -> AppShortcut? in
            guard key.hasPrefix("app.bundle.") else { return nil }
            let bundleID = String(key.dropFirst("app.bundle.".count))
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            let name = url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
                ?? bundleID
            return AppShortcut(key: key, name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                               shortcut: display(shortcut), binding: shortcut)
        }
        .sorted { $0.shortcut.localizedStandardCompare($1.shortcut) == .orderedAscending }
    }

    static func display(_ shortcut: GlobalShortcut) -> String { shortcut.displayString }
}
