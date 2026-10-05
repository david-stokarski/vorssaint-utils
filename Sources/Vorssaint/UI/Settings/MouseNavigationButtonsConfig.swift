// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: which mouse buttons mean Back and Forward, recorded by pressing
/// them, with a live readout of what the mouse actually sends. Logi Options+
/// sends its Back and Forward buttons as swipe gestures; recording one of
/// those makes the swipe the trigger. A mouse whose own software turns a side
/// button into a key press says so.
struct MouseNavigationButtonsConfig: View {
    @AppStorage(DefaultsKey.mouseNavigationBackButton) private var backButton = Int(MouseNavigationSupport.defaultBackButtonNumber)
    @AppStorage(DefaultsKey.mouseNavigationForwardButton) private var forwardButton = Int(MouseNavigationSupport.defaultForwardButtonNumber)
    @AppStorage(DefaultsKey.mouseNavigationBackSwipe) private var backSwipe = 0
    @AppStorage(DefaultsKey.mouseNavigationForwardSwipe) private var forwardSwipe = 0
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = MouseNavigationService.shared
    @State private var recording: MouseNavigationDirection?
    @State private var lastSeen: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(.back, title: "Back button", number: backButton, swipe: backSwipe)
            row(.forward, title: "Forward button", number: forwardButton, swipe: forwardSwipe)
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.secondary)
                Text(lastSeen.map { "Last press: \($0)" } ?? "Press a side button to see what your mouse sends.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if !permissions.accessibility {
                Text("Accessibility is off for this build, so side buttons only work inside this window. Turn on Vorssaint in System Settings › Privacy & Security › Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                PermissionRow(kind: .accessibility)
            } else if !service.isRunning {
                Text("Side buttons aren't being watched yet. Turn the switch above off and on, or reopen Vorssaint.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.leading, settingsRowTextInset)
        .onAppear(perform: startMonitoring)
        .onDisappear(perform: stopMonitoring)
    }

    private func row(_ direction: MouseNavigationDirection, title: String, number: Int, swipe: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(recording == direction ? "Press the button…"
                 : swipe != 0 ? "\(Self.name(Int64(number))) or \(Self.swipeName(swipe))" : Self.name(Int64(number)))
                .foregroundStyle(recording == direction ? Color.accentColor : .secondary)
                .monospacedDigit()
            Button(recording == direction ? "Cancel" : "Record") {
                recording = recording == direction ? nil : direction
            }
            let isDefault = swipe == 0 && Int64(number) == (direction == .back ? MouseNavigationSupport.defaultBackButtonNumber
                                                                                 : MouseNavigationSupport.defaultForwardButtonNumber)
            Button("Reset") {
                if direction == .back { backSwipe = 0 } else { forwardSwipe = 0 }
                assign(direction == .back ? MouseNavigationSupport.defaultBackButtonNumber
                                          : MouseNavigationSupport.defaultForwardButtonNumber, to: direction)
            }
                .disabled(isDefault)
        }
    }

    /// People count mouse buttons from one; CoreGraphics counts from zero.
    static func name(_ number: Int64) -> String {
        switch number {
        case 2: return "Middle button (3)"
        default: return "Mouse button \(number + 1)"
        }
    }

    static func swipeName(_ sign: Int) -> String { sign > 0 ? "swipe gesture (←)" : "swipe gesture (→)" }

    /// A swipe sign for one direction; the other direction gives it up.
    private func assignSwipe(_ sign: Int, to direction: MouseNavigationDirection) {
        if direction == .back {
            if forwardSwipe == sign { forwardSwipe = 0 }
            backSwipe = sign
        } else {
            if backSwipe == sign { backSwipe = 0 }
            forwardSwipe = sign
        }
        MouseNavigationService.shared.syncWithPreferences()
    }

    private func assign(_ number: Int64, to direction: MouseNavigationDirection) {
        if direction == .back {
            if Int64(forwardButton) == number { forwardButton = backButton }
            backButton = Int(number)
        } else {
            if Int64(backButton) == number { backButton = forwardButton }
            forwardButton = Int(number)
        }
        MouseNavigationService.shared.syncWithPreferences()
    }

    /// Presses reach this window directly while it is in front, with or
    /// without Accessibility, so recording never depends on the event tap.
    private func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown, .swipe]) { event in
            if event.type == .swipe {
                let sign = MouseNavigationSupport.swipeSign(deltaX: Double(event.deltaX))
                guard sign != 0 else { return event }
                lastSeen = "\(Self.swipeName(sign)), as Logi Options+ sends its Back and Forward buttons"
                if let direction = recording {
                    assignSwipe(sign, to: direction)
                    recording = nil
                    return nil
                }
                return event
            }
            if event.type == .otherMouseDown {
                let number = Int64(event.buttonNumber)
                lastSeen = Self.name(number)
                if let direction = recording, MouseNavigationSupport.assignableButtons.contains(number) {
                    assign(number, to: direction)
                    recording = nil
                    return nil
                }
                return event
            }
            // A side button its own software remaps arrives as a key press.
            guard recording != nil else { return event }
            if event.keyCode == 53 { recording = nil; return nil }  // Escape
            lastSeen = "a key press (\(Self.describe(event))), not a mouse button. The mouse's own software is remapping it; set it back to a plain button there."
            recording = nil
            return nil
        }
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    private static func describe(_ event: NSEvent) -> String {
        var text = ""
        let flags = event.modifierFlags
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (event.charactersIgnoringModifiers?.uppercased() ?? "key \(event.keyCode)")
    }
}
