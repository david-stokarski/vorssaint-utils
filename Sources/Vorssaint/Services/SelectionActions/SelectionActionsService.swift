// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Fork: Selection Actions' input. A passive global monitor sees each left
/// press and release in other apps and nothing else; a release that ends a
/// drag or a double or triple click asks Accessibility what is selected,
/// and a selection that passes `SelectionGate` gets the bar. Nothing is
/// taken from the event stream, and nothing is read while the feature is
/// off: turning it off or uninstalling it removes the monitor and the
/// shortcut.
final class SelectionActionsService: ObservableObject {
    static let shared = SelectionActionsService()

    @Published private(set) var isRunning = false
    @Published private(set) var shortcutRegistrationFailed = false

    private var mouseMonitor: Any?
    private var downLocation: CGPoint?
    private var readGeneration = 0
    private let hotkey = QuickToolHotkey(id: 91)
    private let readQueue = DispatchQueue(label: "Vorssaint.SelectionActions.read", qos: .userInitiated)
    private var isReading = false

    private init() {
        hotkey.onPress = { [weak self] in self?.shortcutPressed() }
        SessionActivity.shared.onChange { [weak self] _ in
            DispatchQueue.main.async { self?.syncWithPreferences() }
        }
    }

    // MARK: - Lifecycle

    func syncWithPreferences() {
        let defaults = UserDefaults.standard
        let wanted = AppFeature.selectionActions.isAvailable
            && defaults.bool(forKey: DefaultsKey.selectionActionsEnabled)
            && SessionActivity.shared.isActive
        let trusted = AXIsProcessTrusted()
        let automatic = defaults.string(forKey: DefaultsKey.selectionActionsTrigger)
            != SelectionTriggerMode.shortcutOnly.rawValue

        if wanted, trusted, automatic { startMouseMonitor() } else { stopMouseMonitor() }

        let raw = defaults.string(forKey: DefaultsKey.selectionActionsShortcut) ?? ""
        if wanted, let shortcut = GlobalShortcut(storageValue: raw) {
            let registered = hotkey.sync(enabled: true, shortcut: shortcut,
                                         storageKey: DefaultsKey.selectionActionsShortcut)
            if shortcutRegistrationFailed == registered { shortcutRegistrationFailed = !registered }
        } else {
            hotkey.unregister()
            if shortcutRegistrationFailed { shortcutRegistrationFailed = false }
        }

        let running = wanted && trusted && (automatic || !raw.isEmpty)
        if isRunning != running { isRunning = running }
        if !wanted {
            readGeneration &+= 1
            SelectionBarController.shared.hide()
        }
    }

    private func startMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            self?.handle(event)
        }
    }

    private func stopMouseMonitor() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        downLocation = nil
    }

    // MARK: - Mouse

    private func handle(_ event: NSEvent) {
        let location = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            downLocation = location
            readGeneration &+= 1
        case .leftMouseUp:
            let down = downLocation
            downLocation = nil
            guard SelectionGesture.endsSelection(down: down, up: location, clickCount: event.clickCount) else { return }
            let flags = UInt64(event.cgEvent?.flags.rawValue ?? 0)
            let suppress = SelectionSuppressModifier(
                rawValue: UserDefaults.standard.string(forKey: DefaultsKey.selectionActionsSuppressModifier) ?? "")
                ?? .none
            let held = suppress.isHeld(inEventFlags: flags)
            readGeneration &+= 1
            let generation = readGeneration
            // The app settles the selection a moment after the release
            // (a double click picks the word on the way up).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.readGeneration == generation else { return }
                self.readSelection(explicit: false, modifierHeld: held, pointer: location, start: down ?? location,
                                   generation: generation)
            }
        default:
            break
        }
    }

    private func shortcutPressed() {
        guard AppFeature.selectionActions.isAvailable,
              UserDefaults.standard.bool(forKey: DefaultsKey.selectionActionsEnabled) else { return }
        guard AXIsProcessTrusted() else {
            Permissions.shared.requestAccessibility()
            return
        }
        readGeneration &+= 1
        readSelection(explicit: true, modifierHeld: false, pointer: NSEvent.mouseLocation, start: nil,
                      generation: readGeneration)
    }

    // MARK: - Reading

    private struct Read {
        var text: String
        var editable: Bool
        var secureField: Bool
        var outsideFocus = false
    }

    /// `start` is where the gesture began, in AppKit coordinates; a gesture
    /// that began outside the focused element (dragging a window by its
    /// title bar) is not the selection that element still holds.
    private func readSelection(explicit: Bool, modifierHeld: Bool, pointer: CGPoint, start: CGPoint?,
                               generation: Int) {
        let defaults = UserDefaults.standard
        let front = NSWorkspace.shared.frontmostApplication
        var facts = SelectionGate.Facts(text: "x", bundleID: front?.bundleIdentifier,
                                        ownBundleID: Bundle.main.bundleIdentifier,
                                        secureInput: IsSecureEventInputEnabled(),
                                        modifierHeld: modifierHeld, explicit: explicit)
        let excluded = Set(SelectionExcludedApps.current(in: defaults))
        let minLength = SelectionActionsSupport.minLength(in: defaults)
        // Decided once before reading anything, so an excluded app or a
        // password field is never asked what is selected.
        guard SelectionGate.decide(facts, minLength: 1, excluded: excluded) == .show else { return }
        guard !isReading, let pid = front?.processIdentifier else { return }
        isReading = true
        // Accessibility measures from the top of the primary display.
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        let startInAX = start.map { CGPoint(x: $0.x, y: primaryHeight - $0.y) }
        readQueue.async { [weak self] in
            let read = Self.readFocused(pid: pid, start: startInAX)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isReading = false
                guard self.readGeneration == generation, !read.secureField, !read.outsideFocus else { return }
                facts.text = read.text
                if read.text.isEmpty, defaults.bool(forKey: DefaultsKey.selectionActionsClipboardFallback) {
                    self.copySelection { [weak self] copied in
                        guard let self, self.readGeneration == generation, let copied else { return }
                        facts.text = copied
                        self.present(facts, editable: read.editable, pointer: pointer, app: front,
                                     minLength: minLength, excluded: excluded)
                    }
                    return
                }
                self.present(facts, editable: read.editable, pointer: pointer, app: front,
                             minLength: minLength, excluded: excluded)
            }
        }
    }

    private func present(_ facts: SelectionGate.Facts, editable: Bool, pointer: CGPoint, app: NSRunningApplication?,
                         minLength: Int, excluded: Set<String>) {
        guard SelectionGate.decide(facts, minLength: minLength, excluded: excluded) == .show,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == app?.processIdentifier else { return }
        SelectionBarController.shared.show(text: facts.text, editable: editable, pointer: pointer,
                                           sourceApp: app)
    }

    /// The focused element's selected text, read the way the Command Bar
    /// reads it, plus whether the element takes a replacement and whether
    /// it is a password field.
    private static func readFocused(pid: pid_t, start: CGPoint?) -> Read {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.35)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return Read(text: CommandBarSelectionReader.readSelectedText(), editable: false, secureField: false)
        }
        let focused = raw as! AXUIElement
        if let start, let frame = frame(of: focused), !frame.insetBy(dx: -8, dy: -8).contains(start) {
            return Read(text: "", editable: false, secureField: false, outsideFocus: true)
        }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(focused, kAXSubroleAttribute as CFString, &subrole)
        let secure = (subrole as? String) == (kAXSecureTextFieldSubrole as String)
        var settable: DarwinBoolean = false
        let editable = AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable) == .success
            && settable.boolValue
        return Read(text: secure ? "" : CommandBarSelectionReader.readSelectedText(), editable: editable,
                    secureField: secure)
    }

    /// The element's frame as Accessibility measures it (y down from the
    /// top of the primary display), or nil when it doesn't say.
    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return CGRect(origin: position, size: size)
    }

    // MARK: - Clipboard fallback

    /// Copies with ⌘C, reads what arrived and puts the clipboard back the
    /// way it was, marked transient so clipboard managers don't record the
    /// round trip. Nil when nothing was copied.
    private func copySelection(_ completion: @escaping (String?) -> Void) {
        GeneralPasteboardAccess.shared.async({ () -> (snapshot: [NSPasteboardItem], count: Int)? in
            let pasteboard = NSPasteboard.general
            var items: [NSPasteboardItem] = []
            for item in pasteboard.pasteboardItems ?? [] {
                let copy = NSPasteboardItem()
                for type in item.types {
                    guard let data = item.data(forType: type) else { return nil }
                    copy.setData(data, forType: type)
                }
                items.append(copy)
            }
            return (items, pasteboard.changeCount)
        }, then: { saved in
            guard let saved else { completion(nil); return }
            Self.postCopyShortcut()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                GeneralPasteboardAccess.shared.async({ () -> (text: String?, restored: Int?) in
                    let pasteboard = NSPasteboard.general
                    guard pasteboard.changeCount != saved.count else { return (nil, nil) }
                    let text = pasteboard.string(forType: .string)
                    pasteboard.clearContents()
                    if let first = saved.snapshot.first { first.setData(Data(), forType: TransientPaste.transientType) }
                    if !saved.snapshot.isEmpty { pasteboard.writeObjects(saved.snapshot) }
                    return (text, pasteboard.changeCount)
                }, then: { result in
                    if let restored = result.restored { ClipboardHistoryService.shared.ignoreNextChange(upTo: restored) }
                    completion(result.text)
                })
            }
        })
    }

    private static func postCopyShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
