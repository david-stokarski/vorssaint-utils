// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Carbon.HIToolbox
import Foundation

/// Fork: dictation's global shortcut, reporting the release as well as the
/// press so a held shortcut can mean hold-to-talk. Quick tools' hotkeys only
/// hear presses; this registers under its own signature beside them.
final class DictationHotkey {
    private static let signature: OSType = 0x5644_4943 // 'VDIC'
    private static weak var registered: DictationHotkey?
    private static var handler: EventHandlerRef?

    private var reference: EventHotKeyRef?
    private var shortcut: GlobalShortcut?
    private var claimedKey: String?
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    /// False when macOS refused the combination.
    @discardableResult
    func sync(enabled: Bool, shortcut: GlobalShortcut, storageKey: String) -> Bool {
        guard enabled else { unregister(); return true }
        if reference != nil, self.shortcut == shortcut { return true }
        unregister()
        Self.installHandlerIfNeeded()
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.carbonKeyCode, shortcut.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: 1),
                                         GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        self.reference = reference
        self.shortcut = shortcut
        claimedKey = storageKey
        Self.registered = self
        SystemShortcutTakeover.claim(storageKey, shortcut: shortcut)
        return true
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        if let claimedKey { SystemShortcutTakeover.release(claimedKey) }
        reference = nil
        shortcut = nil
        claimedKey = nil
        if Self.registered === self { Self.registered = nil }
    }

    private static func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == DictationHotkey.signature, let hotkey = DictationHotkey.registered else {
                return OSStatus(eventNotHandledErr)
            }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            DispatchQueue.main.async { pressed ? hotkey.onPress?() : hotkey.onRelease?() }
            return noErr
        }, specs.count, &specs, nil, &handler)
    }
}
