// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: the Meetings options, under the calendar's in the Dynamic Island
/// settings: how links open, the closed island's Join, the alert before a
/// meeting and the "Join next meeting" shortcut.
struct NotchMeetingSettings: View {
    @ObservedObject private var alerts = MeetingAlertService.shared
    @AppStorage(DefaultsKey.notchMeetingOpensInApp) private var opensInApp = true
    @AppStorage(DefaultsKey.notchMeetingSoonActivity) private var soonActivity = true
    @AppStorage(DefaultsKey.notchMeetingSoonLead) private var soonLead = MeetingSoonLead.defaultValue
    @AppStorage(DefaultsKey.notchMeetingAlertLead) private var alertLead = MeetingAlertLead.defaultValue
    @AppStorage(DefaultsKey.notchMeetingAlertAllEvents) private var alertsAllEvents = false
    @AppStorage(DefaultsKey.notchMeetingAlertSound) private var alertSound = false
    @AppStorage(DefaultsKey.notchMeetingJoinShortcutEnabled) private var shortcutEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text(MeetingStrings.sectionTitle).font(.subheadline.weight(.medium))
            Text("Video links in events become a Join button wherever the island shows them: Zoom, Google Meet, Teams, Webex, Slack huddles, FaceTime and more.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            switchRow("video", "Open in the meeting's app",
                      caption: "Zoom and Teams links open in their app when it is installed; others open in the browser.",
                      isOn: $opensInApp)
            switchRow("rectangle.topthird.inset.filled", "Show meetings in the closed island",
                      caption: "A meeting with a link shows its countdown and Join before it starts and while it runs.",
                      isOn: $soonActivity)
            if soonActivity {
                SettingsMenuRow(symbol: "clock", title: "Show from", selection: $soonLead) {
                    ForEach(MeetingSoonLead.choices, id: \.self) { Text(MeetingStrings.soonLead($0)).tag($0) }
                }
                .padding(.leading, settingsRowTextInset)
            }

            SettingsMenuRow(symbol: "bell.badge", title: "Meeting alert", selection: $alertLead) {
                ForEach(MeetingAlertLead.choices, id: \.self) { Text(MeetingStrings.alertLead($0)).tag($0) }
            }
            if alertLead != MeetingAlertLead.off {
                VStack(alignment: .leading, spacing: 12) {
                    Text("A large alert on the display with the pointer, with Join, Snooze and Dismiss. Escape dismisses it. Focus modes are not detected.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    switchRow("person.2", "Also for events with attendees",
                              caption: "Events without a video link alert too when other people are invited.",
                              isOn: $alertsAllEvents)
                    switchRow("speaker.wave.2", "Play a sound", isOn: $alertSound)
                    HStack {
                        Spacer()
                        Button("Preview Alert") { alerts.showPreview() }
                    }
                }
                .padding(.leading, settingsRowTextInset)
            }

            switchRow("keyboard", MeetingStrings.joinNext + " shortcut",
                      caption: "Joins the meeting about to start or under way, or else the next one with a link.",
                      isOn: $shortcutEnabled)
            if shortcutEnabled {
                ShortcutPreferenceRow(role: .joinMeeting, isEnabled: shortcutEnabled) {
                    alerts.syncWithPreferences()
                }
                .padding(.leading, settingsRowTextInset)
                if alerts.shortcutRegistrationFailed {
                    Text("Another app is using this shortcut.").font(.caption).foregroundStyle(.orange)
                        .padding(.leading, settingsRowTextInset)
                }
            }
        }
        .onChange(of: [String(opensInApp), String(soonActivity), String(soonLead), String(alertLead),
                       String(alertsAllEvents), String(alertSound), String(shortcutEnabled)]) { _, _ in
            NotchCalendarService.shared.meetingSettingsChanged()
        }
    }

    private func switchRow(_ symbol: String, _ title: String, caption: String? = nil, isOn: Binding<Bool>) -> some View {
        SettingsRow(symbol: symbol, title: title, caption: caption) {
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
        }
    }
}
