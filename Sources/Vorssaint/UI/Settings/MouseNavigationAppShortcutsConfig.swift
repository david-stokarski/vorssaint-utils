// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Fork: per-app keys for the side buttons, for apps like Slack whose Back
/// and Forward are keyboard shortcuts with no menu item to press.
struct MouseNavigationAppShortcutsConfig: View {
    @AppStorage(DefaultsKey.mouseNavigationAppShortcuts) private var raw = ""
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = MouseNavigationService.shared
    @State private var message: String?

    private var list: [MouseNavigationAppShortcut] { MouseNavigationAppShortcuts.decode(raw) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("App shortcuts").font(.subheadline.weight(.semibold))
                Spacer()
                addMenu
            }
            Text("For apps whose Back and Forward are keyboard shortcuts rather than menu commands, like Slack's ⌘[ and ⌘]. In these apps the buttons press the keys you set here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(list) { entry in row(entry) }
            if !list.isEmpty {
                Label(service.lastAppShortcut.map { "Last press: sent \($0)" }
                      ?? "Press a side button in one of these apps to see what it sends.",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.leading, settingsRowTextInset)
    }

    // MARK: Rows

    private func row(_ entry: MouseNavigationAppShortcut) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.icon(for: entry.bundleID))
                .resizable()
                .frame(width: 18, height: 18)
            Text(entry.name).lineLimit(1)
            Spacer(minLength: 8)
            Text("Back").font(.caption).foregroundStyle(.secondary)
            recorder(entry.back) { value in update(entry.bundleID) { $0.back = value } }
            Text("Forward").font(.caption).foregroundStyle(.secondary)
            recorder(entry.forward) { value in update(entry.bundleID) { $0.forward = value } }
            Button { remove(entry.bundleID) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove \(entry.name)")
        }
    }

    private func recorder(_ value: String, set: @escaping (String) -> Void) -> some View {
        let shortcut = GlobalShortcut(storageValue: value, requiringModifier: false)
        return ShortcutRecorderButton(
            shortcut: shortcut ?? GlobalShortcut(keyCode: 0, modifiers: [.command]),
            isEnabled: true,
            waitingTitle: l10n.s.shortcutPressKeys,
            requiresModifier: false,
            emptyTitle: shortcut == nil ? "Record" : nil,
            clearAction: { set("") },
            notCapturedAction: { message = l10n.s.shortcutNotCaptured },
            recordingChanged: { if $0 { message = nil } },
            invalidAction: { message = l10n.s.shortcutInvalid },
            captureAction: { captured in
                guard MouseNavigationAppShortcuts.isUsable(captured) else {
                    message = l10n.s.shortcutInvalid
                    return
                }
                set(captured.storageValue)
            })
            .frame(width: 96)
    }

    // MARK: Adding

    private var addMenu: some View {
        Menu("Add App") {
            let taken = Set(list.map(\.bundleID))
            let running = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier && !taken.contains($0.bundleIdentifier ?? "") }
                .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
            if !running.isEmpty {
                Section("Open apps") {
                    ForEach(running, id: \.processIdentifier) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "") {
                            add(bundleID: app.bundleIdentifier ?? "", name: app.localizedName ?? "")
                        }
                    }
                }
            }
            Divider()
            Button("Choose App…") { chooseApp() }
        }
        .fixedSize()
        .disabled(list.count >= MouseNavigationAppShortcuts.limit)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        add(bundleID: bundleID, name: FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: ""))
    }

    private func add(bundleID: String, name: String) {
        guard !bundleID.isEmpty, !list.contains(where: { $0.bundleID == bundleID }) else { return }
        save(list + [MouseNavigationAppShortcuts.suggested(bundleID: bundleID, name: name.isEmpty ? bundleID : name)])
    }

    private func update(_ bundleID: String, _ change: (inout MouseNavigationAppShortcut) -> Void) {
        var next = list
        guard let index = next.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        change(&next[index])
        save(next)
    }

    private func remove(_ bundleID: String) {
        save(list.filter { $0.bundleID != bundleID })
    }

    private func save(_ next: [MouseNavigationAppShortcut]) {
        raw = MouseNavigationAppShortcuts.encode(next)
        MouseNavigationService.shared.syncWithPreferences()
    }

    private static func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
