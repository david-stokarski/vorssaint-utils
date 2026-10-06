// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices

// Fork: the app side of the clipboard in the Command Bar (see
// ClipboardCommandBarSupport).

extension ClipboardCommandBar {
    /// Whether the history opens in the bar right now: the bar has to be
    /// there to open.
    static func routes(in defaults: UserDefaults = .standard) -> Bool {
        isOn(in: defaults) && AppFeature.commandBar.isAvailable
    }

    /// The history item behind a bar row.
    static func entry(forRowID id: String) -> ClipboardHistoryEntry? {
        guard let uuid = entryID(forRowID: id) else { return nil }
        return ClipboardHistoryService.shared.entries.first { $0.id == uuid }
    }
}

/// Whether a pick should paste, decided from what has the keyboard in the
/// app in front.
enum ClipboardPasteTarget {
    /// Electron and Chromium build their accessibility tree only once asked.
    /// Asked when the bar opens, the tree is there by the time an item is
    /// picked.
    static func prepare() {
        guard let front = frontApp() else { return }
        let pid = front.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.3)
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
    }

    /// Whether the focused element of the app in front takes text. Without
    /// Accessibility nothing can be read, and nothing could be pasted either.
    static func focusAcceptsText() -> Bool {
        guard AXIsProcessTrusted(), let front = frontApp() else { return false }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        // A hung app must not hold the pick.
        AXUIElementSetMessagingTimeout(app, 0.35)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let focused = element(app, kAXFocusedUIElementAttribute) else { return false }
        return ClipboardCommandBar.acceptsText(
            role: string(focused, kAXRoleAttribute),
            subrole: string(focused, kAXSubroleAttribute),
            caretSettable: isSettable(focused, kAXSelectedTextRangeAttribute),
            valueSettable: isSettable(focused, kAXValueAttribute),
            editableAncestor: value(focused, "AXEditableAncestor") != nil)
    }

    /// Puts the item on the clipboard and says so.
    static func copy(_ entry: ClipboardHistoryEntry) {
        ClipboardHistoryService.shared.copy(entry) { copied in
            if copied {
                QuickToolHUD.show(icon: "doc.on.doc", message: "Copied to clipboard")
            } else {
                NSSound.beep()
            }
        }
    }

    private static func frontApp() -> NSRunningApplication? {
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return front
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let raw = value(element, attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }
}

