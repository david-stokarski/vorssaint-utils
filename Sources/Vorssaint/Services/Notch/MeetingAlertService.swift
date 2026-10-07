// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Carbon.HIToolbox
import Combine
import EventKit

/// Fork: an EventKit event read as a meeting, on the calendar reader's actor.
/// Only the link and two facts about the attendees leave it, never the notes.
enum MeetingEventReader {
    static func info(_ event: EKEvent) -> MeetingInfo {
        let attendees = event.attendees ?? []
        let participation: MeetingParticipation
        if event.organizer?.isCurrentUser == true {
            participation = .organizer
        } else if attendees.isEmpty {
            participation = .unknown
        } else {
            participation = attendees.contains { $0.isCurrentUser } ? .attending : .notInvited
        }
        let link = MeetingLinkSupport.link(url: event.url, location: event.location,
                                           notes: event.hasNotes ? event.notes : nil)
        return MeetingInfo(link: link, attendeeCount: attendees.count, participation: participation)
    }
}

/// Fork: opens a meeting the way the person chose, in the provider's app
/// when it is installed and has an app form, otherwise in the browser.
enum MeetingJoiner {
    /// Events the developer remote makes up are never dialled.
    static let previewPrefix = "vorssaint-preview:"

    @discardableResult
    static func join(_ event: NotchCalendarEvent) -> Bool {
        guard let link = event.meeting.link else { return false }
        if event.id.hasPrefix(previewPrefix) { return true }
        if MeetingSettings.current().opensInApp, let app = MeetingLinkSupport.appURL(for: link),
           NSWorkspace.shared.urlForApplication(toOpen: app) != nil, NSWorkspace.shared.open(app) {
            return true
        }
        return NSWorkspace.shared.open(link.url)
    }

    /// The meeting the shortcut and the Command Bar join, if any.
    static var nextMeeting: NotchCalendarEvent? {
        guard NotchCalendarSupport.isEnabled() else { return nil }
        return MeetingTiming.nextToJoin(NotchCalendarService.shared.currentEvents, now: Date())
    }

    static func joinNext() {
        guard let meeting = nextMeeting, join(meeting) else { NSSound.beep(); return }
    }

    /// Calendar itself shows an event without a link.
    static func openInCalendar(_ event: NotchCalendarEvent) {
        guard !event.id.hasPrefix(previewPrefix),
              let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        if let url = NotchCalendarSupport.eventURL(event) {
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.openApplication(at: application, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}

/// Fork: "Join next meeting", registered under its own signature beside the
/// app's other Carbon hotkeys, so the dispatcher hands each its own.
final class MeetingJoinHotkey {
    private static let signature: OSType = 0x564D_5447 // 'VMTG'
    private static var handler: EventHandlerRef?
    private var reference: EventHotKeyRef?
    private var shortcut: GlobalShortcut?

    /// False when macOS refused the combination.
    @discardableResult
    func sync(enabled: Bool) -> Bool {
        guard enabled else { unregister(); return true }
        let shortcut = GlobalShortcutRole.joinMeeting.savedShortcut
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
        SystemShortcutTakeover.claim(DefaultsKey.notchMeetingJoinShortcut, shortcut: shortcut)
        return true
    }

    func unregister() {
        if let reference {
            UnregisterEventHotKey(reference)
            SystemShortcutTakeover.release(DefaultsKey.notchMeetingJoinShortcut)
        }
        reference = nil
        shortcut = nil
    }

    private static func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard id.signature == MeetingJoinHotkey.signature else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MeetingJoiner.joinNext() }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

/// Fork: the alert just before a meeting, and the "Join next meeting"
/// shortcut. Both follow the calendar section: they run only while it reads
/// events, and stop with it. Nothing is stored; what was shown is
/// remembered for the session only.
final class MeetingAlertService: ObservableObject {
    static let shared = MeetingAlertService()
    @Published private(set) var shortcutRegistrationFailed = false
    private var memory = MeetingAlertMemory()
    private var timer: Timer?
    private var subscription: AnyCancellable?
    private let hotkey = MeetingJoinHotkey()
    private let alert = MeetingAlertController()

    private init() {}

    func syncWithPreferences() {
        let running = NotchCalendarSupport.isEnabled()
        let settings = MeetingSettings.current()
        let failed = !hotkey.sync(enabled: running && settings.joinShortcut)
        if shortcutRegistrationFailed != failed { shortcutRegistrationFailed = failed }
        guard running else { stop(); return }
        if subscription == nil {
            subscription = NotchCalendarService.shared.$currentEvents
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reschedule() }
        }
        reschedule()
    }

    /// With the calendar off, asleep or locked: no timer, no shortcut, no alert.
    func stop() {
        subscription = nil
        timer?.invalidate(); timer = nil
        hotkey.unregister()
        alert.dismiss()
    }

    private func reschedule() {
        timer?.invalidate(); timer = nil
        guard subscription != nil, NotchCalendarSupport.isEnabled() else { return }
        let settings = MeetingSettings.current()
        let now = Date()
        memory.prune(now: now)
        let events = NotchCalendarService.shared.currentEvents
        if !alert.isShowing, let due = MeetingAlertSchedule.due(events, now: now, settings: settings, memory: memory).first {
            memory.show(due)
            present(due, sound: settings.alertSound)
        }
        guard let next = MeetingAlertSchedule.nextDue(events, now: now, settings: settings, memory: memory) else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in self?.reschedule() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func present(_ event: NotchCalendarEvent, sound: Bool) {
        alert.show(event, sound: sound) { [weak self] action in
            guard let self else { return }
            switch action {
            case .join: MeetingJoiner.join(event)
            case .openInCalendar: MeetingJoiner.openInCalendar(event)
            case .snooze: self.memory.snooze(event, until: Date().addingTimeInterval(MeetingAlertSchedule.snoozeInterval))
            case .dismiss: break
            }
            // Another meeting due at the same moment follows.
            self.reschedule()
        }
    }

    /// The alert for a made-up Zoom meeting a minute away, from Settings and
    /// the developer remote. Its Join opens nothing; a snooze brings it back.
    func showPreview() {
        alert.show(MeetingPreview.event(startingIn: 60), sound: MeetingSettings.current().alertSound) { [weak self] action in
            guard action == .snooze else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + MeetingAlertSchedule.snoozeInterval) { self?.showPreview() }
        }
    }
}

/// A made-up meeting, so the alert and the island can be seen without
/// calendar access. Joining it opens nothing.
enum MeetingPreview {
#if VORSSAINT_DEVELOPMENT
    /// Developer builds only: shown in the closed island in place of the calendar's own.
    static var event: NotchCalendarEvent?
#endif

    static func event(startingIn seconds: TimeInterval, minutes: TimeInterval = 30) -> NotchCalendarEvent {
        let start = Date().addingTimeInterval(seconds)
        var event = NotchCalendarEvent(id: MeetingJoiner.previewPrefix + "design-review", title: "Design review",
                                       calendar: "Work", start: start, end: start.addingTimeInterval(minutes * 60),
                                       allDay: false, location: "https://us06web.zoom.us/j/84512345678?pwd=preview",
                                       color: NotchCalendarColor(red: 0.2, green: 0.55, blue: 1))
        event.meeting = MeetingInfo(link: MeetingLinkSupport.link(url: nil, location: event.location, notes: nil),
                                    attendeeCount: 6, participation: .attending)
        return event
    }
}
