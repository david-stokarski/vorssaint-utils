// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import CoreGraphics

/// Fork: the Snap Wheel's input. At rest a listen-only tap reads modifier
/// changes and nothing else, so holding Control costs nothing and changes
/// nothing. Once the trigger is held a second tap watches the pointer; the
/// first movement past a few points picks the window and shows the wheel.
/// From then on a click steps through the pointed direction's list, a right
/// click or Escape cancels, and letting go places the window.
final class SnapWheelService: ObservableObject {
    static let shared = SnapWheelService()

    @Published private(set) var isRunning = false
    /// True when macOS refused the event tap (usually Accessibility).
    @Published private(set) var tapFailed = false
    /// Loop running alongside would snap the same window twice.
    @Published private(set) var waitsForLoop = false
    /// Keys held while the settings screen records a trigger.
    @Published private(set) var recordedKeys: SnapWheelTriggerKeys = []
    @Published private(set) var isRecordingTrigger = false

    private var idleTap: CFMachPort?
    private var idleSource: CFRunLoopSource?
    private var sessionTap: CFMachPort?
    private var sessionSource: CFRunLoopSource?
    private var hold: SnapWheelHold?
    private var session: Session?
    private var sessionGeneration = 0
    private var workspaceObservers: [NSObjectProtocol] = []
    private var recordMonitor: Any?
    private var recordPeak: SnapWheelTriggerKeys = []
    private var recordCompletion: ((SnapWheelTriggerKeys) -> Void)?
    private let overlay = SnapWheelOverlay.shared

    private struct Session {
        let generation: Int
        var anchor: SnapWheelAnchor
        var origin: CGPoint { anchor.origin }
        var circle = SnapWheelCircle()
        /// A circle finished before the wheel had shown; it applies on showing.
        var pendingCircle = false
        /// The preview was held back for a circle in progress.
        var heldPreview = false
        /// A circle chose the center; it holds until the hand rests and
        /// moves on, so the end of the loop cannot pick a side instead.
        var circleLock = false
        let feel: SnapWheelFeel
        var pointer: CGPoint
        let slots: [SnapWheelSlot: [String]]
        let appearance: SnapWheelAppearance
        let directionalDistance: CGFloat
        var revealRequested = false
        var shown = false
        var window: SnapWheelWindow?
        var screen: NSScreen?
        var windowPlacement: String?
        var slot: SnapWheelSlot?
        var actionID: String?
        var cycle = SnapWheelCycle()
        /// Buttons and keys whose press was taken, so their release is taken too.
        var takenButtons = Set<Int64>()
        var takenKeys = Set<Int64>()
    }

    private init() {
        SessionActivity.shared.onChange { [weak self] _ in
            DispatchQueue.main.async { self?.syncWithPreferences() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == SnapWheelLoopImport.bundleID else { return }
                self?.syncWithPreferences()
            })
        }
    }

    static var isLoopRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: SnapWheelLoopImport.bundleID)
            .filter { !$0.isTerminated }.isEmpty
    }

    // MARK: - Lifecycle

    func syncWithPreferences() {
        let defaults = UserDefaults.standard
        let wanted = AppFeature.snapWheel.isAvailable && defaults.bool(forKey: DefaultsKey.snapWheelEnabled)
        let loop = wanted && Self.isLoopRunning
        if waitsForLoop != loop { waitsForLoop = loop }
        guard wanted, !loop, AXIsProcessTrusted(), SessionActivity.shared.isActive else {
            stop()
            if tapFailed { tapFailed = false }
            return
        }
        let trigger = SnapWheelTrigger.current(in: defaults)
        if hold?.trigger != trigger {
            endSession(apply: false)
            hold = SnapWheelHold(trigger: trigger, initiallyHeld: Self.heldNow())
        }
        let started = startIdleTap()
        if tapFailed == started { tapFailed = !started }
        if isRunning != started { isRunning = started }
        if started { overlay.prepare() }
    }

    func stop() {
        endSession(apply: false)
        stopIdleTap()
        hold = nil
        if isRunning { isRunning = false }
    }

    private static func heldNow() -> SnapWheelTriggerKeys {
        SnapWheelTriggerKeys(eventFlags: CGEventSource.flagsState(.combinedSessionState).rawValue)
    }

    // MARK: - Recording a trigger

    /// Records the keys pressed together, finishing when they are let go.
    func recordTrigger(_ completion: @escaping (SnapWheelTriggerKeys) -> Void) {
        cancelRecording()
        endSession(apply: false)
        isRecordingTrigger = true
        recordedKeys = []
        recordPeak = []
        recordCompletion = completion
        recordMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.cancelRecording() }  // Escape
                return nil
            }
            let held = SnapWheelTriggerKeys(eventFlags: UInt64(event.modifierFlags.rawValue))
            self.recordedKeys = held
            self.recordPeak.formUnion(held)
            if held.isEmpty, !self.recordPeak.isEmpty {
                let keys = self.recordPeak
                let completion = self.recordCompletion
                self.cancelRecording()
                completion?(keys)
            }
            return nil
        }
    }

    func cancelRecording() {
        if let recordMonitor { NSEvent.removeMonitor(recordMonitor) }
        recordMonitor = nil
        recordCompletion = nil
        if isRecordingTrigger { isRecordingTrigger = false }
        recordedKeys = []
        // The keys used to record must not arm the wheel on their way up.
        if let trigger = hold?.trigger { hold = SnapWheelHold(trigger: trigger, initiallyHeld: Self.heldNow()) }
    }

    // MARK: - Idle tap

    private func startIdleTap() -> Bool {
        if let idleTap {
            if !CGEvent.tapIsEnabled(tap: idleTap) { CGEvent.tapEnable(tap: idleTap, enable: true) }
            return true
        }
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                if let userInfo {
                    Unmanaged<SnapWheelService>.fromOpaque(userInfo).takeUnretainedValue()
                        .observeModifiers(type: type, event: event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        idleTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        idleSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopIdleTap() {
        if let idleSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), idleSource, .commonModes) }
        idleSource = nil
        if let idleTap {
            CGEvent.tapEnable(tap: idleTap, enable: false)
            CFMachPortInvalidate(idleTap)
        }
        idleTap = nil
    }

    private func observeModifiers(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let idleTap { CGEvent.tapEnable(tap: idleTap, enable: true) }
            return
        }
        guard type == .flagsChanged, !isRecordingTrigger, var hold else { return }
        let decision = hold.update(SnapWheelTriggerKeys(eventFlags: event.flags.rawValue))
        self.hold = hold
        switch decision {
        case .arm: beginSession()
        case .release: endSession(apply: true)
        case .cancel: endSession(apply: false)
        case .nothing: break
        }
    }

    // MARK: - Session

    private func beginSession() {
        guard !ShortcutCapture.isCapturing, SessionActivity.shared.isActive, AXIsProcessTrusted(),
              !Self.isAnyMouseButtonDown() else {
            _ = hold?.cancel()
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if WindowLayoutIgnoredApps.shared.contains(bundleID: frontmost?.bundleIdentifier,
                                                   executablePath: frontmost?.executableURL?.path) {
            _ = hold?.cancel()
            return
        }
        let defaults = UserDefaults.standard
        let appearance = SnapWheelAppearance.current(in: defaults)
        sessionGeneration += 1
        let origin = NSEvent.mouseLocation
        let feel = SnapWheelFeel.current(in: defaults)
        session = Session(generation: sessionGeneration,
                          anchor: SnapWheelAnchor(origin: origin, at: ProcessInfo.processInfo.systemUptime),
                          feel: feel,
                          pointer: origin,
                          slots: SnapWheelSlots.current(in: defaults),
                          appearance: appearance,
                          directionalDistance: feel.directionalDistance(
                              size: appearance.size, thickness: appearance.ringThickness))
        if !startSessionTap() {
            session = nil
            _ = hold?.cancel()
        }
    }

    /// Ends the hold. With `apply`, a wheel on screen places its window.
    private func endSession(apply: Bool) {
        stopSessionTap()
        guard let session else { return }
        self.session = nil
        // A click still held as the trigger is let go: its release must
        // not reach the app without the press it never saw.
        pendingTakenReleases.formUnion(session.takenButtons)
        pendingTakenKeys.formUnion(session.takenKeys)
        guard session.shown else { return }
        let placing = apply && session.window != nil ? session.actionID : nil
        overlay.hide(placed: placing != nil)
        if let placing, let window = session.window, let screen = session.screen {
            WindowLayoutService.shared.snapWheelApply(placing, to: window, screen: screen)
        }
    }

    /// Cancels from inside the session tap: the hold now belongs to whatever
    /// the input was for, and the tap goes once its callback has returned.
    private func cancelFromInput() {
        _ = hold?.cancel()
        if let session {
            if session.shown { overlay.hide(placed: false) }
            pendingTakenReleases.formUnion(session.takenButtons)
            pendingTakenKeys.formUnion(session.takenKeys)
        }
        session = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.session == nil else { return }
            self.stopSessionTap()
        }
    }

    private static func isAnyMouseButtonDown() -> Bool {
        (0..<5).contains { index in
            CGMouseButton(rawValue: UInt32(index)).map {
                CGEventSource.buttonState(.combinedSessionState, button: $0)
            } ?? false
        }
    }

    // MARK: - Session tap

    private func startSessionTap() -> Bool {
        guard sessionTap == nil else { return true }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<SnapWheelService>.fromOpaque(userInfo).takeUnretainedValue()
                    .handleSessionEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        sessionTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        sessionSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func stopSessionTap() {
        if let sessionSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), sessionSource, .commonModes) }
        sessionSource = nil
        if let sessionTap {
            CGEvent.tapEnable(tap: sessionTap, enable: false)
            CFMachPortInvalidate(sessionTap)
        }
        sessionTap = nil
    }

    private static let pointerTypes: Set<CGEventType> = [
        .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
    ]

    private func handleSessionEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let sessionTap, session != nil { CGEvent.tapEnable(tap: sessionTap, enable: true) }
            return pass
        }
        guard var session else { return pass }
        let shown = session.shown || session.revealRequested

        // Every pointer event carries the modifiers held, so a release the
        // idle tap missed still ends the hold instead of leaving it stuck.
        if Self.pointerTypes.contains(type), var hold, hold.isArmed {
            var held = SnapWheelTriggerKeys(eventFlags: event.flags.rawValue)
            if !hold.trigger.keys.contains(.function) { held.remove(.function) }
            if !hold.trigger.matches(held) {
                let decision = hold.update(held)
                self.hold = hold
                DispatchQueue.main.async { [weak self] in
                    self?.endSession(apply: decision == .release)
                }
                return pass
            }
        }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            session.pointer = trackedPointer(for: event, previous: session.pointer)
            // A pointer that rested and moves on starts over from where it rested.
            let recentered = session.feel.recenters
                && session.anchor.move(to: session.pointer, at: ProcessInfo.processInfo.systemUptime,
                                       restDelay: session.feel.restDelay)
            // A big circle picks the center.
            let circled = session.feel.circles
                && session.circle.add(session.pointer, at: ProcessInfo.processInfo.systemUptime)
            if recentered { session.circleLock = false }
            self.session = session
            if recentered, session.shown, session.appearance.placement == .pointer {
                overlay.moveWheel(to: session.origin)
            }
            if circled {
                if session.shown {
                    completeCircle()
                } else {
                    self.session?.pendingCircle = true
                }
            }
            // A drag whose press the wheel took is the wheel's too.
            let draggingTaken = type != .mouseMoved
                && session.takenButtons.contains(event.getIntegerValueField(.mouseEventButtonNumber))
            if session.shown {
                if !circled { updateSelection() }
            } else if !session.revealRequested,
                      hypot(session.pointer.x - session.origin.x, session.pointer.y - session.origin.y)
                        >= session.feel.showDistance {
                // Picking the window asks Accessibility, which can take a
                // moment; the pointer must never wait for it.
                self.session?.revealRequested = true
                let generation = session.generation
                DispatchQueue.main.async { [weak self] in self?.reveal(generation: generation) }
            }
            return draggingTaken ? nil : pass

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard shown else {
                // Control-click and friends: the hold was for the click.
                cancelFromInput()
                return pass
            }
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            self.session?.takenButtons.insert(button)
            if type == .leftMouseDown {
                advanceCycle()
            } else {
                cancelFromInput()
            }
            return nil

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            if session.takenButtons.remove(button) != nil {
                self.session = session
                return nil
            }
            return pass

        case .keyDown:
            guard shown else {
                cancelFromInput()
                return pass
            }
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            self.session?.takenKeys.insert(key)
            if key == 53 { cancelFromInput() }  // Escape
            return nil

        case .keyUp:
            // Only the releases of keys the wheel took; a key held from
            // before the hold still reaches its app.
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            if session.takenKeys.remove(key) != nil {
                self.session = session
                return nil
            }
            return pass

        case .scrollWheel:
            guard shown else {
                cancelFromInput()
                return pass
            }
            return nil

        default:
            return pass
        }
    }

    /// Presses the wheel took whose release comes after the session ended:
    /// the release (and a button's drags) are taken too, so no app sees half
    /// of an input.
    private var pendingTakenReleases = Set<Int64>() {
        didSet {
            guard !pendingTakenReleases.isEmpty, releaseTap == nil else { return }
            startReleaseTap()
        }
    }
    private var pendingTakenKeys = Set<Int64>() {
        didSet {
            guard !pendingTakenKeys.isEmpty, releaseTap == nil else { return }
            startReleaseTap()
        }
    }
    private var releaseTap: CFMachPort?
    private var releaseTapGeneration = 0
    private var releaseSource: CFRunLoopSource?

    private func startReleaseTap() {
        let mask = [CGEventType.leftMouseUp, .rightMouseUp, .otherMouseUp,
                    .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .keyUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                return Unmanaged<SnapWheelService>.fromOpaque(userInfo).takeUnretainedValue()
                    .handleReleaseEvent(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            pendingTakenReleases.removeAll()
            pendingTakenKeys.removeAll()
            return
        }
        releaseTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        releaseSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        // A release that never comes (the button was let go elsewhere) must
        // not leave the tap behind.
        releaseTapGeneration += 1
        let generation = releaseTapGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, generation == self.releaseTapGeneration else { return }
            self.pendingTakenReleases.removeAll()
            self.pendingTakenKeys.removeAll()
            self.stopReleaseTap()
        }
    }

    private func handleReleaseEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let releaseTap { CGEvent.tapEnable(tap: releaseTap, enable: true) }
            return pass
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            return pendingTakenReleases.contains(event.getIntegerValueField(.mouseEventButtonNumber)) ? nil : pass
        case .keyUp:
            guard pendingTakenKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil else { return pass }
        default:
            guard pendingTakenReleases.remove(event.getIntegerValueField(.mouseEventButtonNumber)) != nil
            else { return pass }
        }
        if pendingTakenReleases.isEmpty, pendingTakenKeys.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingTakenReleases.isEmpty, self.pendingTakenKeys.isEmpty else { return }
                self.stopReleaseTap()
            }
        }
        return nil
    }

    private func stopReleaseTap() {
        if let releaseSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), releaseSource, .commonModes) }
        releaseSource = nil
        if let releaseTap {
            CGEvent.tapEnable(tap: releaseTap, enable: false)
            CFMachPortInvalidate(releaseTap)
        }
        releaseTap = nil
    }

    /// AppKit coordinates, carried past a screen edge the pointer is stuck on.
    private func trackedPointer(for event: CGEvent, previous: CGPoint) -> CGPoint {
        let topY = NSScreen.screens.first?.frame.maxY ?? 0
        let location = CGPoint(x: event.location.x, y: topY - event.location.y)
        let delta = CGVector(dx: event.getDoubleValueField(.mouseEventDeltaX),
                             dy: -event.getDoubleValueField(.mouseEventDeltaY))
        let screens = NSScreen.screens.map(\.frame)
        func onScreen(_ point: CGPoint) -> Bool { screens.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(point) } }
        let pinnedX = delta.dx != 0 && !onScreen(CGPoint(x: location.x + (delta.dx > 0 ? 2 : -2), y: location.y))
        let pinnedY = delta.dy != 0 && !onScreen(CGPoint(x: location.x, y: location.y + (delta.dy > 0 ? 2 : -2)))
        return SnapWheelGeometry.trackedPointer(previous: previous, location: location, delta: delta,
                                                pinnedX: pinnedX, pinnedY: pinnedY,
                                                reach: (session?.directionalDistance ?? 40) + 30)
    }

    private func reveal(generation: Int) {
        guard let start = session, start.generation == generation, !start.shown else { return }
        let choice = UserDefaults.standard.string(forKey: DefaultsKey.snapWheelTarget)
            .flatMap(SnapWheelTargetChoice.init(rawValue:)) ?? .focused
        let window = WindowLayoutService.shared.snapWheelWindow(choice, pointer: start.origin)
        // Accessibility may have run a nested loop: the hold could be over,
        // and the live session may have changed, so it is read again.
        guard var session, session.generation == generation else { return }
        let screenChoice = UserDefaults.standard.string(forKey: DefaultsKey.snapWheelScreen)
            .flatMap(SnapWheelScreenChoice.init(rawValue:)) ?? .pointer
        let pointerScreen = NSScreen.screens.first { NSMouseInRect(session.origin, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
        let windowScreen = window.flatMap { frame in
            NSScreen.screens.max { $0.frame.intersection(frame.frame).area < $1.frame.intersection(frame.frame).area }
        }
        session.screen = screenChoice == .window ? (windowScreen ?? pointerScreen) : pointerScreen
        session.window = window
        session.windowPlacement = window.flatMap { WindowLayoutService.shared.snapWheelCurrentPlacement(of: $0) }
        session.revealRequested = false
        session.shown = true
        self.session = session
        guard let screen = session.screen else { return }
        overlay.show(origin: session.origin, screen: screen, appearance: session.appearance,
                     windowFrame: window?.frame, hasWindow: window != nil)
        if self.session?.pendingCircle == true {
            completeCircle()
            return
        }
        updateSelection()
    }

    private func updateSelection() {
        guard var session, session.shown, !session.circleLock else { return }
        let slot = SnapWheelGeometry.slot(from: session.origin, to: session.pointer,
                                          directionalDistance: session.directionalDistance,
                                          showDistance: session.feel.showDistance)
        // Mid-circle the highlight follows the hand, but the preview waits:
        // it would only flash every half of the screen in turn.
        let circling = session.feel.circles && session.circle.isCircling
        if !circling, session.heldPreview {
            session.heldPreview = false
            self.session = session
            if slot == session.slot {
                present(session, actions: session.slot.map { session.slots[$0] ?? [] } ?? [], haptic: false)
                return
            }
        }
        guard slot != session.slot else { return }
        // After a new center, the choice stays until a direction is picked
        // from it: resting near it should not fall back to nothing or to
        // the center's maximize.
        if session.anchor.hasMoved, session.slot != nil, slot == nil || slot == .center { return }
        session.slot = slot
        let actions = slot.map { session.slots[$0] ?? [] } ?? []
        let actionID = slot.flatMap { session.cycle.enter($0, actions: actions, windowPlacement: session.windowPlacement) }
        let changed = actionID != session.actionID
        session.actionID = actionID
        if circling { session.heldPreview = true }
        self.session = session
        present(session, actions: actions, haptic: changed && actionID != nil && !circling, showsPreview: !circling)
    }

    /// A circle was drawn: the center's first placement is chosen and held,
    /// and the ring moves to where the circle ended.
    private func completeCircle() {
        guard var session, session.shown else { return }
        let actions = session.slots[.center] ?? []
        guard !actions.isEmpty else { return }
        // Always the first of the list (fill the screen, as set up), whatever
        // the window wears now: a circle means one thing.
        session.slot = .center
        session.actionID = session.cycle.select(.center, index: 0, actions: actions)
        session.circleLock = true
        session.anchor.restart(at: session.pointer, time: ProcessInfo.processInfo.systemUptime)
        session.heldPreview = false
        session.pendingCircle = false
        self.session = session
        if session.appearance.placement == .pointer { overlay.moveWheel(to: session.origin) }
        present(session, actions: actions, haptic: true)
    }

    private func advanceCycle() {
        guard var session, session.shown, let slot = session.slot else { return }
        let actions = session.slots[slot] ?? []
        guard actions.count > 1 else { return }
        session.actionID = session.cycle.advance(slot, actions: actions)
        self.session = session
        present(session, actions: actions, haptic: true)
    }

    private func present(_ session: Session, actions: [String], haptic: Bool, showsPreview: Bool = true) {
        let preview: NSRect? = {
            guard showsPreview, let actionID = session.actionID, let window = session.window,
                  let screen = session.screen
            else { return nil }
            return WindowLayoutService.shared.snapWheelPreviewFrame(actionID, for: window, screen: screen)
        }()
        let position = session.slot.flatMap { session.cycle.position(in: $0) }
        overlay.update(slot: session.slot,
                       actionID: session.window == nil ? nil : session.actionID,
                       cycle: position.map { ($0, actions.count) },
                       previewFrame: preview)
        if haptic, session.appearance.haptics, session.window != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    // MARK: - Loop

    /// Copies Loop's settings over. With `quit`, Loop is asked to quit too.
    @discardableResult
    func importFromLoop(quit: Bool) -> Bool {
        guard let loop = UserDefaults(suiteName: SnapWheelLoopImport.bundleID)?
            .persistentDomain(forName: SnapWheelLoopImport.bundleID), !loop.isEmpty
        else { return false }
        let defaults = UserDefaults.standard
        for (key, value) in SnapWheelLoopImport.preferences(from: loop) { defaults.set(value, forKey: key) }
        if quit {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: SnapWheelLoopImport.bundleID) {
                app.terminate()
            }
        }
        WindowLayoutService.shared.syncWithPreferences()
        syncWithPreferences()
        return true
    }

    static var hasLoopPreferences: Bool {
        UserDefaults(suiteName: SnapWheelLoopImport.bundleID)?
            .persistentDomain(forName: SnapWheelLoopImport.bundleID)?.isEmpty == false
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }
}
