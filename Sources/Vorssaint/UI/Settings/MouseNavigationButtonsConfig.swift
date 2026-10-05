// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: which mouse buttons mean Back and Forward, recorded by pressing
/// them, with a live readout of what the mouse actually sends. A mouse whose
/// own software turns its side buttons into key presses shows that here.
struct MouseNavigationButtonsConfig: View {
    @AppStorage(DefaultsKey.mouseNavigationBackButton) private var backButton = Int(MouseNavigationSupport.defaultBackButtonNumber)
    @AppStorage(DefaultsKey.mouseNavigationForwardButton) private var forwardButton = Int(MouseNavigationSupport.defaultForwardButtonNumber)
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var service = MouseNavigationService.shared
    @State private var recording: MouseNavigationDirection?
    @State private var lastSeen: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(.back, title: "Back button", number: backButton)
            row(.forward, title: "Forward button", number: forwardButton)
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

    private func row(_ direction: MouseNavigationDirection, title: String, number: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(recording == direction ? "Press the button…" : Self.name(Int64(number)))
                .foregroundStyle(recording == direction ? Color.accentColor : .secondary)
                .monospacedDigit()
            Button(recording == direction ? "Cancel" : "Record") {
                recording = recording == direction ? nil : direction
            }
            let isDefault = Int64(number) == (direction == .back ? MouseNavigationSupport.defaultBackButtonNumber
                                                                 : MouseNavigationSupport.defaultForwardButtonNumber)
            Button("Reset") { assign(direction == .back ? MouseNavigationSupport.defaultBackButtonNumber
                                                        : MouseNavigationSupport.defaultForwardButtonNumber, to: direction) }
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .keyDown]) { event in
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
