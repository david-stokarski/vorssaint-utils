// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

enum MeetingAlertAction: Equatable {
    case join, openInCalendar, snooze, dismiss
}

/// Fork: the alert before a meeting, over the whole display the pointer is
/// on: a dimmed screen and one card with the meeting, Join, Snooze and
/// Dismiss. It takes the keyboard without bringing the app forward, so
/// Escape dismisses it and the app underneath keeps its place. Nothing in it
/// acts on Return or Space alone, so typing into it does no harm.
final class MeetingAlertController {
    private final class Panel: OverlayPanel {
        override var canBecomeKey: Bool { true }
    }

    private var panel: Panel?
    private var keyMonitor: Any?
    private var endTimer: Timer?
    private var handler: ((MeetingAlertAction) -> Void)?
    private var sound: NSSound?

    var isShowing: Bool { panel?.isVisible == true }

    /// Shows the alert, in place of one already showing. `handler` hears
    /// what the person chose; a dismissal by the app itself is not reported.
    func show(_ event: NotchCalendarEvent, sound playsSound: Bool,
              handler: @escaping (MeetingAlertAction) -> Void) {
        dismiss()
        guard let screen = NSScreen.withMouse ?? NSScreen.screens.first else { return }
        self.handler = handler
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: false)
        let view = MeetingAlertView(event: event) { [weak self] action in self?.finish(action) }
            .environment(\.locale, L10n.shared.language.formattingLocale())
        panel.contentView = NSHostingView(rootView: view)
        panel.orderFrontRegardless()
        panel.makeKey()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if event.keyCode == 53 { self.finish(.dismiss); return nil }  // Escape
            return event
        }
        // Gone with the meeting, if nobody was there to answer it.
        let timer = Timer(fire: max(event.end, Date().addingTimeInterval(60)), interval: 0, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        RunLoop.main.add(timer, forMode: .common)
        endTimer = timer
        if playsSound {
            let tone = NSSound(named: "Glass")
            tone?.play()
            self.sound = tone
        }
    }

    func dismiss() {
        endTimer?.invalidate(); endTimer = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        sound?.stop(); sound = nil
        handler = nil
        guard let panel else { return }
        panel.orderOut(nil)
        panel.contentView = nil
    }

    private func finish(_ action: MeetingAlertAction) {
        let handler = self.handler
        dismiss()
        handler?(action)
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        panel.title = MeetingStrings.sectionTitle
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        // Above the island and ordinary windows; menus still open over it.
        panel.level = NSWindow.Level(rawValue: NotchPanel.normalLevel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.animationBehavior = .none
        return panel
    }
}

struct MeetingAlertView: View {
    let event: NotchCalendarEvent
    let act: (MeetingAlertAction) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private var title: String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? FeatureStrings.notchCalendar(L10n.shared.language).untitled : title
    }

    var body: some View {
        ZStack {
            // A click beside the card dismisses, like Escape.
            Color.black.opacity(appeared ? 0.45 : 0)
                .contentShape(Rectangle())
                .onTapGesture { act(.dismiss) }
                .accessibilityHidden(true)
            card
                .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
                .opacity(appeared ? 1 : 0)
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.34, dampingFraction: 0.82)) {
                appeared = true
            }
        }
    }

    private var card: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Circle().fill(event.color.color).frame(width: 10, height: 10).accessibilityHidden(true)
                    Text(event.calendar).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(MeetingStrings.startText(start: event.start, now: context.date))
                        .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(event.start <= context.date ? Color.mint : Color.white)
                }
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                details
                actions
            }
            .padding(28)
            .frame(width: 520, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThickMaterial)
                RoundedRectangle(cornerRadius: 24, style: .continuous).fill(event.color.color.opacity(0.12))
            }
            .overlay(alignment: .top) {
                // The calendar's color along the top edge.
                UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous)
                    .fill(event.color.color).frame(height: 4).accessibilityHidden(true)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 18)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(title), \(MeetingStrings.startText(start: event.start, now: context.date))")
        }
    }

    private var details: some View {
        HStack(spacing: 16) {
            Label {
                Text(event.start, format: .dateTime.hour().minute()) + Text(" – ")
                    + Text(event.end, format: .dateTime.hour().minute())
            } icon: {
                Image(systemName: "clock")
            }
            if let people = MeetingStrings.people(event.meeting.attendeeCount) {
                Label(people, systemImage: "person.2")
            }
            if let link = event.meeting.link {
                Label {
                    Text(link.provider.name)
                } icon: {
                    NotchMeetingProviderIcon(provider: link.provider, size: 15)
                }
            }
        }
        .font(.system(size: 14))
        .foregroundStyle(.white.opacity(0.78))
        .lineLimit(1)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if let link = event.meeting.link {
                Button { act(.join) } label: {
                    HStack(spacing: 7) {
                        NotchMeetingProviderIcon(provider: link.provider, size: 18)
                        Text(MeetingStrings.join)
                    }
                }
                .buttonStyle(MeetingAlertButtonStyle(fill: NotchMeetingPill.fill))
                .help("\(MeetingStrings.join) \(link.provider.name)")
                .accessibilityLabel("\(MeetingStrings.join) \(link.provider.name)")
            } else {
                Button(MeetingStrings.openInCalendar) { act(.openInCalendar) }
                    .buttonStyle(MeetingAlertButtonStyle(fill: .accentColor))
            }
            Button(MeetingStrings.snooze) { act(.snooze) }
                .buttonStyle(MeetingAlertButtonStyle(fill: .white.opacity(0.14)))
            Button(MeetingStrings.dismiss) { act(.dismiss) }
                .buttonStyle(MeetingAlertButtonStyle(fill: .white.opacity(0.14)))
            Spacer(minLength: 8)
            Text(MeetingStrings.escapeHint)
                .font(.system(size: 11)).foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.top, 4)
    }
}

private struct MeetingAlertButtonStyle: ButtonStyle {
    let fill: Color
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(fill.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .overlay { Capsule().fill(.white.opacity(hovered ? 0.08 : 0)).allowsHitTesting(false) }
            .contentShape(Capsule())
            .onHover { hovered = $0 }
    }
}
