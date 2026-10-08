// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: one saved Command Bar shortcut, changed or removed where it is
/// listed on the settings page instead of in the app list. Click the
/// shortcut and press a new one, or click ✕. The same checks as the app list
/// run first, and a combination macOS holds gets the usual offer to take it
/// over, under the row.
struct CommandBarShortcutRow<Label: View>: View {
    let key: String
    let shortcut: GlobalShortcut
    @ViewBuilder let label: () -> Label

    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var service = CommandBarService.shared
    @State private var message: String?
    @State private var pendingTakeOver: GlobalShortcut?

    private var text: CommandBarFeatureStrings { FeatureStrings.commandBar(l10n.language) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                label()
                Spacer(minLength: 8)
                // A combination another app already holds never fires, and a
                // row showing a dead key is worse than no key.
                if service.refusedRowShortcutKeys.contains(key) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .help(l10n.s.shortcutUnavailable)
                        .accessibilityLabel(l10n.s.shortcutUnavailable)
                }
                ShortcutRecorderButton(
                    shortcut: shortcut,
                    isEnabled: AppFeature.commandBar.isAvailable,
                    waitingTitle: l10n.s.shortcutPressKeys,
                    clearAction: remove,
                    notCapturedAction: { message = l10n.s.shortcutNotCaptured },
                    recordingChanged: { if $0 { message = nil; pendingTakeOver = nil } },
                    invalidAction: { message = l10n.s.shortcutInvalid },
                    captureAction: record)
                    .frame(width: 130)
                    .help("Click and press a new shortcut")
                    .accessibilityLabel(text.appShortcutLabel)
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(text.actionShortcutRemove)
                .accessibilityLabel(text.actionShortcutRemove)
            }
            if let pendingTakeOver {
                SystemShortcutTakeOverOffer(
                    shortcut: pendingTakeOver,
                    onAccept: {
                        self.pendingTakeOver = nil
                        guard let entry = service.settingsEntry(forStableKey: key) else { return }
                        message = service.takeOverRowShortcut(pendingTakeOver, for: entry)
                    },
                    onDismiss: {
                        self.pendingTakeOver = nil
                        message = String(format: l10n.s.shortcutConflictFormat, "macOS")
                    })
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: l10n.language) { _, _ in message = nil }
    }

    private func record(_ next: GlobalShortcut) {
        pendingTakeOver = nil
        guard next != shortcut else { message = nil; return }
        guard let entry = service.settingsEntry(forStableKey: key) else {
            // The app is gone; there is nothing left to bind to.
            message = l10n.s.shortcutUnavailable
            return
        }
        if service.rowShortcutTakeOverOffer(next, for: entry) {
            message = nil
            pendingTakeOver = next
            return
        }
        message = service.setRowShortcut(next, for: entry)
    }

    private func remove() {
        message = nil
        pendingTakeOver = nil
        service.clearRowShortcut(forStableKey: key)
    }
}
