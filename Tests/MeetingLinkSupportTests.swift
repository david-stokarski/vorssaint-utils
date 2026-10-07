// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: meeting join and alerts. Links come out of real invitation bodies,
/// through the redirects mail scanners wrap them in, named by provider and
/// ranked above any other address; Zoom and Teams links get their app form;
/// the closed island, the shortcut and the alert pick the right meeting at
/// the right moment, and snoozing brings an alert back once.
enum MeetingLinkSupportTests {
    static func run(_ suite: TestSuite) {
        invitations(suite)
        providers(suite)
        redirects(suite)
        ranking(suite)
        appLinks(suite)
        locationLabels(suite)
        settings(suite)
        island(suite)
        joinNext(suite)
        alerts(suite)
        words(suite)
    }

    // MARK: Fixtures

    static let zoomInvite = """
    David Stokarski is inviting you to a scheduled Zoom meeting.

    Join Zoom Meeting
    https://us06web.zoom.us/j/84512345678?pwd=QWxhZGRpbjpvcGVuIHNlc2FtZQ.1

    Meeting ID: 845 1234 5678
    Passcode: 123456

    ---

    One tap mobile
    +16465588656,,84512345678#,,,,*123456# US (New York)
    +13017158592,,84512345678#,,,,*123456# US (Washington DC)

    ---

    Dial by your location
    • +1 646 558 8656 US (New York)

    Find your local number: https://us06web.zoom.us/u/kbYuD6Jx2

    Join by SIP
    • 84512345678@zoomcrc.com
    """

    static let teamsInvite = """
    ________________________________________________________________________________
    Microsoft Teams meeting
    Join on your computer, mobile app or room device
    Click here to join the meeting<https://teams.microsoft.com/l/meetup-join/19%3ameeting_NmQ0ZjY2YzQtMjQ3Ny00ZWZhLWE2ZWQtYzM1YjM3YjQ5ZWE2%40thread.v2/0?context=%7b%22Tid%22%3a%2272f988bf-86f1-41af-91ab-2d7cd011db47%22%2c%22Oid%22%3a%22b3a6b1c4-1d2e-4f5a-9b8c-7d6e5f4a3b2c%22%7d>
    Meeting ID: 254 112 988 761
    Passcode: Ab3cDe
    Download Teams<https://www.microsoft.com/en-us/microsoft-teams/download-app> | Join on the web<https://www.microsoft.com/microsoft-teams/join-a-meeting>
    Learn More<https://aka.ms/JoinTeamsMeeting> | Meeting options<https://teams.microsoft.com/meetingOptions/?organizerId=b3a6b1c4&tenantId=72f988bf&threadId=19_meeting&messageId=0&language=en-US>
    ________________________________________________________________________________
    """

    static let newTeamsInvite = """
    Microsoft Teams Need help?<https://aka.ms/JoinTeamsMeeting?omkt=en-US>
    Join the meeting now<https://teams.microsoft.com/meet/2345678901234?p=AbCdEfGhIjKlMn>
    Meeting ID: 234 567 890 123 4
    Passcode: x7Yz9Q
    """

    static let meetDescription = """
    Weekly sync for the island redesign.

    -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
    Join with Google Meet: https://meet.google.com/abc-defg-hij
    Or dial: (US) +1 234-567-8901 PIN: 123456789#
    More phone numbers: https://tel.meet/abc-defg-hij?pin=1234567890123&hs=7

    Learn more about Meet at: https://support.google.com/a/users/answer/9282720

    Please do not edit this section.
    -::~:~::~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~:~::~:~::-
    """

    static func event(_ id: String, start: TimeInterval, minutes: TimeInterval = 30, link: String? = nil,
                      attendees: Int = 0, participation: MeetingParticipation = .unknown,
                      allDay: Bool = false) -> NotchCalendarEvent {
        let start = Date(timeIntervalSinceReferenceDate: start)
        var event = NotchCalendarEvent(id: id, title: id, calendar: "Work", start: start,
                                       end: start.addingTimeInterval(minutes * 60), allDay: allDay, location: "")
        event.meeting = MeetingInfo(link: link.flatMap { MeetingLinkSupport.link(url: nil, location: $0, notes: nil) },
                                    attendeeCount: attendees, participation: participation)
        return event
    }

    private static func found(_ notes: String?, location: String? = nil, url: String? = nil) -> MeetingLink? {
        MeetingLinkSupport.link(url: url.flatMap(URL.init(string:)), location: location, notes: notes)
    }

    // MARK: Detection

    private static func invitations(_ suite: TestSuite) {
        let zoom = found(zoomInvite)
        suite.expect(zoom?.provider == .zoom
                        && zoom?.url.absoluteString == "https://us06web.zoom.us/j/84512345678?pwd=QWxhZGRpbjpvcGVuIHNlc2FtZQ.1",
                     "a Zoom invitation's join link, not its local-numbers page or SIP address: \(String(describing: zoom))")

        let teams = found(teamsInvite, location: "Microsoft Teams Meeting")
        suite.expect(teams?.provider == .teams
                        && teams?.url.absoluteString.hasPrefix("https://teams.microsoft.com/l/meetup-join/19%3ameeting_") == true
                        && teams?.url.absoluteString.hasSuffix("%7d") == true,
                     "a Teams invitation's join link, whole, without the angle bracket: \(String(describing: teams))")
        suite.expect(found(newTeamsInvite)?.url.absoluteString == "https://teams.microsoft.com/meet/2345678901234?p=AbCdEfGhIjKlMn",
                     "the newer short Teams link")

        let meet = found(meetDescription)
        suite.expect(meet?.provider == .googleMeet && meet?.url.absoluteString == "https://meet.google.com/abc-defg-hij",
                     "Google's Meet block, not its phone-number or help pages: \(String(describing: meet))")

        suite.expect(found("Room: meet.google.com/xyz-abcd-efg (dial-in below)")?.url.absoluteString
                        == "https://meet.google.com/xyz-abcd-efg",
                     "an address written without its scheme, closing parenthesis left off")
        suite.expect(found("Call at zoom.us/j/123456789.")?.url.absoluteString == "https://zoom.us/j/123456789",
                     "a sentence's full stop is not part of the link")
        suite.expect(found("<a href=\"https://zoom.us/j/99887766554?pwd=abc&amp;uname=x\">Join</a>")?.url.absoluteString
                        == "https://zoom.us/j/99887766554?pwd=abc&uname=x",
                     "an HTML description's link, its entities read as characters")
        suite.expect(found("Email me at someone@zoom.us/j/1 or see https://example.com/zoom.us/j/1") == nil,
                     "no provider host inside an email or another site's path")
        suite.expect(found("Agenda: https://docs.google.com/document/d/1AbC/edit and https://example.com") == nil,
                     "documents and other pages are never a meeting")
        suite.expect(found(nil, location: "Conference Room 4B") == nil && found("") == nil, "plain text has no link")
    }

    private static func providers(_ suite: TestSuite) {
        let cases: [(String, MeetingProvider?)] = [
            ("https://zoom.us/j/123456789", .zoom),
            ("https://company.zoom.us/my/david.s", .zoom),
            ("https://zoomgov.com/j/1601234567?pwd=x", .zoom),
            ("zoommtg://zoom.us/join?action=join&confno=123", .zoom),
            ("https://zoom.us/download", nil),
            ("https://us02web.zoom.us/u/abcdef", nil),
            ("https://meet.google.com/abc-defg-hij?authuser=1", .googleMeet),
            ("https://meet.google.com/lookup/abcdefghij", .googleMeet),
            ("https://meet.google.com/", nil),
            ("https://meet.google.com/new", nil),
            ("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0", .teams),
            ("https://teams.live.com/meet/9876543210123?p=abc", .teams),
            ("https://teams.microsoft.com/dl/launcher/launcher.html?url=%2F_%23%2Fl%2Fmeetup-join%2F19", .teams),
            ("https://teams.microsoft.com/meetingOptions/?organizerId=1", nil),
            ("msteams:/l/meetup-join/19%3ameeting_abc", .teams),
            ("https://acme.webex.com/meet/jdoe", .webex),
            ("https://acme.webex.com/acme/j.php?MTID=m0123456789abcdef", .webex),
            ("https://help.webex.com/en-us/article/WBX000", nil),
            ("https://app.slack.com/huddle/T012AB3C4/C0123456789", .slack),
            ("https://app.slack.com/client/T012AB3C4/C0123456789", nil),
            ("https://around.co/r/team-standup", .around),
            ("https://meet.around.co/r/abc-123", .around),
            ("https://whereby.com/acme-standup", .whereby),
            ("https://whereby.com/information/pricing", nil),
            ("https://meet.jit.si/AcmeDailyStandup", .jitsi),
            ("https://chime.aws/1234567890", .chime),
            ("https://app.chime.aws/meetings/1234567890", .chime),
            ("https://global.gotomeeting.com/join/123456789", .goTo),
            ("https://meet.goto.com/123456789", .goTo),
            ("https://facetime.apple.com/join#v=1&p=AbCdEf&k=GhIj", .faceTime),
            ("https://discord.gg/abcDEF", .discord),
            ("https://discord.com/channels/123/456", .discord),
            ("https://discord.com/", nil),
            ("https://example.com/j/123", nil),
        ]
        for (address, provider) in cases {
            guard let url = URL(string: address) else { suite.expect(false, "parses \(address)"); continue }
            suite.expect(MeetingLinkSupport.provider(of: url) == provider,
                         "\(address) is \(provider?.rawValue ?? "no meeting"), not \(MeetingLinkSupport.provider(of: url)?.rawValue ?? "none")")
        }
        suite.expect(MeetingProvider.allCases.allSatisfy { !$0.name.isEmpty && !$0.shortName.isEmpty },
                     "every provider has a name")
    }

    private static func redirects(_ suite: TestSuite) {
        let safeLinks = "https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fus02web.zoom.us%2Fj%2F81234567890%3Fpwd%3DdEf123&data=05%7C01%7Cdavid%40example.com%7C1234%7C0&sdata=AbC%3D&reserved=0"
        let zoom = found("Join: " + safeLinks)
        suite.expect(zoom?.provider == .zoom && zoom?.url.absoluteString == "https://us02web.zoom.us/j/81234567890?pwd=dEf123",
                     "Outlook SafeLinks are unwrapped: \(String(describing: zoom))")
        let newerSafeLinks = "https://nam10.safelinks.protection.outlook.com/ap/t-59584e83/?url=https%3A%2F%2Fteams.microsoft.com%2Fl%2Fmeetup-join%2F19%253ameeting_X%2540thread.v2%2F0&data=05&reserved=0"
        suite.expect(found(newerSafeLinks)?.url.absoluteString == "https://teams.microsoft.com/l/meetup-join/19%3ameeting_X%40thread.v2/0",
                     "the newer SafeLinks path, keeping the link's own encoding")
        let google = "https://www.google.com/url?q=https://meet.google.com/abc-defg-hij&sa=D&source=calendar&ust=1700000000000000&usg=AOvVaw"
        suite.expect(found(google)?.url.absoluteString == "https://meet.google.com/abc-defg-hij",
                     "Google's redirect is unwrapped")
        let nested = "https://nam12.safelinks.protection.outlook.com/?url=" + "https://www.google.com/url?q=https://zoom.us/j/111222333"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)! + "&reserved=0"
        suite.expect(found(nested)?.url.absoluteString == "https://zoom.us/j/111222333", "redirect inside redirect")
        let proofpointV3 = "https://urldefense.com/v3/__https://zoom.us/j/5551234567?pwd=xyz__;!!ABC123!def$"
        suite.expect(found(proofpointV3)?.url.absoluteString == "https://zoom.us/j/5551234567?pwd=xyz",
                     "Proofpoint's third version")
        let proofpointV2 = "https://urldefense.proofpoint.com/v2/url?u=https-3A__meet.google.com_abc-2Ddefg-2Dhij&d=DwMF&c=x&r=y"
        suite.expect(found(proofpointV2)?.url.absoluteString == "https://meet.google.com/abc-defg-hij",
                     "Proofpoint's second version")
        suite.expect(found("https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fexample.com&data=1") == nil,
                     "a wrapped page that is not a meeting stays none")
    }

    private static func ranking(_ suite: TestSuite) {
        let both = found(meetDescription, location: "https://us02web.zoom.us/j/81234567890?pwd=x")
        suite.expect(both?.provider == .zoom, "the location's link before the notes' one")
        let fromURL = found(zoomInvite, url: "https://meet.google.com/abc-defg-hij")
        suite.expect(fromURL?.provider == .googleMeet, "the event's own URL before anything written")
        let randomURL = found(zoomInvite, url: "https://www.google.com/calendar/event?eid=abc123")
        suite.expect(randomURL?.provider == .zoom, "a provider link beats the event's own random URL")
        let room = found("My room: https://zoom.us/my/david\nToday's meeting: https://zoom.us/j/123456789")
        suite.expect(room?.url.absoluteString == "https://zoom.us/j/123456789",
                     "a meeting's link outranks a personal room mentioned first")
        let personal = found(nil, location: "https://zoom.us/my/david")
        suite.expect(personal?.url.absoluteString == "https://zoom.us/my/david", "a personal room alone is still joinable")
        let two = found("Primary: https://meet.google.com/aaa-bbbb-ccc backup: https://zoom.us/j/123")
        suite.expect(two?.provider == .googleMeet, "within one field the first link wins")
    }

    private static func appLinks(_ suite: TestSuite) {
        func app(_ address: String) -> String? {
            URL(string: address).flatMap { url in
                MeetingLinkSupport.provider(of: url).map { MeetingLink(provider: $0, url: url) }
            }.flatMap(MeetingLinkSupport.appURL(for:))?.absoluteString
        }
        suite.expect(app("https://us06web.zoom.us/j/84512345678?pwd=QWxhZGRpbjpvcGVuIHNlc2FtZQ.1")
                        == "zoommtg://us06web.zoom.us/join?action=join&confno=84512345678&pwd=QWxhZGRpbjpvcGVuIHNlc2FtZQ.1",
                     "a Zoom link opens in Zoom with its number and passcode: \(app("https://us06web.zoom.us/j/84512345678?pwd=QWxhZGRpbjpvcGVuIHNlc2FtZQ.1") ?? "nil")")
        suite.expect(app("https://zoom.us/j/123456789") == "zoommtg://zoom.us/join?action=join&confno=123456789",
                     "without a passcode")
        suite.expect(app("https://zoom.us/w/99911122233?tk=abc&uuid=x") == "zoommtg://zoom.us/join?action=join&confno=99911122233&tk=abc",
                     "a webinar keeps its registration token, nothing else")
        suite.expect(app("https://zoom.us/wc/join/123456789") == "zoommtg://zoom.us/join?action=join&confno=123456789",
                     "the web client's join")
        suite.expect(app("https://zoomgov.com/j/1601234567") == "zoommtg://zoomgov.com/join?action=join&confno=1601234567",
                     "ZoomGov keeps its host")
        suite.expect(app("https://zoom.us/my/david") == nil, "a personal room's name cannot become a number")
        suite.expect(app("https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d")
                        == "msteams://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=%7b%7d",
                     "Teams opens in Teams")
        suite.expect(app("https://meet.google.com/abc-defg-hij") == nil, "Meet has no app")
        suite.expect(app("zoommtg://zoom.us/join?confno=1") == nil, "an app link already is one")
    }

    private static func locationLabels(_ suite: TestSuite) {
        let zoom = MeetingInfo(link: found(nil, location: "https://zoom.us/j/123456789"))
        suite.expect(zoom.locationLabel("https://zoom.us/j/123456789") == "Zoom", "a location that is only the link names the provider")
        suite.expect(zoom.locationLabel(" zoom.us/j/123456789 ") == "Zoom", "even without its scheme")
        suite.expect(zoom.locationLabel("HQ 4B; https://zoom.us/j/123456789") == "HQ 4B; https://zoom.us/j/123456789",
                     "a room beside the link stays as written")
        suite.expect(MeetingInfo().locationLabel("https://zoom.us/j/1") == "https://zoom.us/j/1", "no link, no change")
    }

    // MARK: Preferences

    private static func settings(_ suite: TestSuite) {
        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.meetings")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.meetings")
        defer { defaults.removePersistentDomain(forName: "com.vorssaint.tests.meetings") }
        let initial = MeetingSettings.current(in: defaults)
        suite.expect(initial == MeetingSettings(), "nothing stored reads as the defaults")
        suite.expect(initial.opensInApp && initial.soonActivity && initial.soonLead == 300 && initial.alertLead == 60
                        && !initial.alertsAllEvents && !initial.alertSound && !initial.joinShortcut,
                     "Zoom in its app, the island five minutes ahead, the alert a minute ahead, no sound or shortcut")
        defaults.set(MeetingAlertLead.off, forKey: DefaultsKey.notchMeetingAlertLead)
        defaults.set(7, forKey: DefaultsKey.notchMeetingSoonLead)
        defaults.set(false, forKey: DefaultsKey.notchMeetingSoonActivity)
        let changed = MeetingSettings.current(in: defaults)
        suite.expect(changed.alertLead == nil && changed.soonLead == 300 && !changed.soonActivity,
                     "off turns the alert off and a lead that is not offered falls back")
        suite.expect(!changed.needsCurrentWeek, "nothing on, nothing to read")
        defaults.set(0, forKey: DefaultsKey.notchMeetingAlertLead)
        suite.expect(MeetingSettings.current(in: defaults).alertLead == 0, "at the start")
        let registered = MeetingSettings.registeredDefaults
        suite.expect(registered.count == 8 && registered.keys.allSatisfy { $0.hasPrefix("notchMeeting") },
                     "every preference is registered, so settings backup carries it")
        suite.expect(registered[DefaultsKey.notchMeetingJoinShortcut] as? String == GlobalShortcut.meetingJoinDefault.storageValue
                        && GlobalShortcut.meetingJoinDefault.isValid,
                     "the shortcut's default is a valid combination")
        suite.expect(GlobalShortcutRole.joinMeeting.storageKey == DefaultsKey.notchMeetingJoinShortcut
                        && GlobalShortcutRole.joinMeeting.defaultShortcut == .meetingJoinDefault
                        && GlobalShortcutRole.joinMeeting.requiredEnableKeys == [DefaultsKey.notchMeetingJoinShortcutEnabled]
                        && GlobalShortcutRole.joinMeeting.feature == .notchCalendar,
                     "the shortcut is a role with its own switch, under the calendar")
        suite.expect(GlobalShortcutRole.conflict(for: .meetingJoinDefault, excluding: .joinMeeting,
                                                 isOn: { _ in true }, isAvailable: { _ in true },
                                                 radialMenuShortcuts: { [] }) == nil,
                     "⌃⌥⌘J is free among the other shortcuts")
    }

    // MARK: Timing

    private static func island(_ suite: TestSuite) {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        let lead: TimeInterval = 5 * 60
        let zoom = "https://zoom.us/j/123456789"
        let soon = event("soon", start: 10_000 + 180, link: zoom)
        let later = event("later", start: 10_000 + 600, link: zoom)
        let plain = event("plain", start: 10_000 + 60)
        let running = event("running", start: 10_000 - 1_200, minutes: 60, link: zoom)
        let allDay = event("allDay", start: 10_000 - 3_600, minutes: 24 * 60, link: zoom, allDay: true)

        suite.expect(MeetingTiming.soonMeeting([later, plain], now: now, lead: lead) == nil,
                     "a meeting ten minutes off, or an event without a link, is not shown")
        suite.expect(MeetingTiming.soonMeeting([later, soon, plain], now: now, lead: lead)?.id == "soon",
                     "a meeting three minutes off is")
        suite.expect(MeetingTiming.soonMeeting([running], now: now, lead: lead)?.id == "running",
                     "a meeting under way stays, for its whole length")
        suite.expect(MeetingTiming.soonMeeting([running, soon], now: now, lead: lead)?.id == "soon",
                     "the next meeting outranks the one being left")
        let earlier = event("earlier", start: 10_000 - 3_000, minutes: 90, link: zoom)
        suite.expect(MeetingTiming.soonMeeting([earlier, running], now: now, lead: lead)?.id == "running",
                     "of two under way, the one begun last")
        suite.expect(MeetingTiming.soonMeeting([allDay], now: now, lead: lead) == nil, "all-day events never")
        let ended = event("ended", start: 10_000 - 1_800, minutes: 30, link: zoom)
        suite.expect(MeetingTiming.soonMeeting([ended], now: now, lead: lead) == nil, "an ended meeting goes")

        suite.expect(MeetingTiming.soonTransition([later], now: now, lead: lead) == later.start.addingTimeInterval(-lead),
                     "the island wakes when the lead opens")
        suite.expect(MeetingTiming.soonTransition([soon], now: now, lead: lead) == soon.start, "then at the start")
        suite.expect(MeetingTiming.soonTransition([running], now: now, lead: lead) == running.end, "then at the end")
        suite.expect(MeetingTiming.soonTransition([plain, allDay], now: now, lead: lead) == nil,
                     "events without a link never wake it")
    }

    private static func joinNext(_ suite: TestSuite) {
        let now = Date(timeIntervalSinceReferenceDate: 50_000)
        let zoom = "https://zoom.us/j/123456789"
        let afternoon = event("afternoon", start: 50_000 + 4 * 3_600, link: zoom)
        let running = event("running", start: 50_000 - 600, link: zoom)
        let imminent = event("imminent", start: 50_000 + 420, link: zoom)
        let plain = event("plain", start: 50_000 + 60)
        suite.expect(MeetingTiming.nextToJoin([afternoon, plain], now: now)?.id == "afternoon",
                     "the next meeting with a link, however far ahead")
        suite.expect(MeetingTiming.nextToJoin([afternoon, running], now: now)?.id == "running",
                     "the meeting under way before a later one")
        suite.expect(MeetingTiming.nextToJoin([running, imminent, afternoon], now: now)?.id == "imminent",
                     "the one about to start before the one under way")
        suite.expect(MeetingTiming.nextToJoin([plain], now: now) == nil, "nothing to join")
    }

    private static func alerts(_ suite: TestSuite) {
        let zoom = "https://zoom.us/j/123456789"
        let standup = event("standup", start: 100_000, link: zoom, attendees: 6, participation: .attending)
        let review = event("review", start: 100_000, attendees: 3, participation: .attending)
        let focus = event("focus", start: 100_000)
        let shared = event("shared", start: 100_000, link: zoom, attendees: 4, participation: .notInvited)
        let holiday = event("holiday", start: 100_000, minutes: 24 * 60, link: zoom, allDay: true)
        var settings = MeetingSettings()
        var memory = MeetingAlertMemory()
        let all = [standup, review, focus, shared, holiday]
        func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: 100_000 + offset) }

        suite.expect(MeetingAlertSchedule.due(all, now: at(-61), settings: settings, memory: memory).isEmpty,
                     "nothing before the minute")
        suite.expect(MeetingAlertSchedule.due(all, now: at(-60), settings: settings, memory: memory).map(\.id) == ["standup"],
                     "a minute ahead, only the meeting with a link the person attends")
        suite.expect(MeetingAlertSchedule.nextDue(all, now: at(-600), settings: settings, memory: memory) == at(-60),
                     "the next alert is a minute before the start")
        settings.alertsAllEvents = true
        suite.expect(Set(MeetingAlertSchedule.due(all, now: at(-30), settings: settings, memory: memory).map(\.id))
                        == ["standup", "review"],
                     "asked for, events with attendees too, never a private block, a colleague's event or an all-day one")
        settings.alertsAllEvents = false
        settings.alertLead = 0
        suite.expect(MeetingAlertSchedule.due([standup], now: at(-1), settings: settings, memory: memory).isEmpty
                        && MeetingAlertSchedule.due([standup], now: at(0), settings: settings, memory: memory).count == 1,
                     "at the start means at the start")
        settings.alertLead = 120
        suite.expect(MeetingAlertSchedule.due([standup], now: at(-120), settings: settings, memory: memory).count == 1,
                     "two minutes ahead")
        settings.alertLead = nil
        suite.expect(MeetingAlertSchedule.due([standup], now: at(0), settings: settings, memory: memory).isEmpty
                        && MeetingAlertSchedule.nextDue([standup], now: at(-600), settings: settings, memory: memory) == nil,
                     "off is off")
        settings.alertLead = 60

        suite.expect(MeetingAlertSchedule.due([standup], now: at(299), settings: settings, memory: memory).count == 1,
                     "shown late, after waking, within five minutes of the start")
        suite.expect(MeetingAlertSchedule.due([standup], now: at(300), settings: settings, memory: memory).isEmpty,
                     "and not later, when the moment has passed")

        memory.show(standup)
        suite.expect(MeetingAlertSchedule.due([standup], now: at(-30), settings: settings, memory: memory).isEmpty
                        && MeetingAlertSchedule.nextDue([standup], now: at(-600), settings: settings, memory: memory) == nil,
                     "an alert shown is not shown again")
        memory.snooze(standup, until: at(30))
        suite.expect(MeetingAlertSchedule.due([standup], now: at(29), settings: settings, memory: memory).isEmpty
                        && MeetingAlertSchedule.nextDue([standup], now: at(0), settings: settings, memory: memory) == at(30),
                     "snoozed, it waits its minute")
        suite.expect(MeetingAlertSchedule.due([standup], now: at(30), settings: settings, memory: memory).count == 1,
                     "and comes back")
        suite.expect(MeetingAlertSchedule.due([standup], now: at(900), settings: settings, memory: memory).count == 1,
                     "a snooze still comes back late, while the meeting lasts")
        suite.expect(MeetingAlertSchedule.due([standup], now: at(1_800), settings: settings, memory: memory).isEmpty,
                     "but not once it has ended")
        memory.snooze(standup, until: at(5_000))
        suite.expect(memory.snoozed[standup.id] == standup.end
                        && MeetingAlertSchedule.window(for: standup, settings: settings, memory: memory) == nil,
                     "a snooze past the end never comes back")
        memory.show(standup)
        memory.prune(now: at(1_801))
        suite.expect(memory.shown.isEmpty, "ended meetings are forgotten")

        let short = event("short", start: 100_000, minutes: 2, link: zoom)
        suite.expect(MeetingAlertSchedule.window(for: short, settings: settings, memory: MeetingAlertMemory())?.end == short.end,
                     "a short meeting's late window ends with it")
    }

    private static func words(_ suite: TestSuite) {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        func start(_ seconds: TimeInterval) -> String { MeetingStrings.startText(start: now.addingTimeInterval(seconds), now: now) }
        suite.expect(start(60) == "Starts in 1 min" && start(170) == "Starts in 3 min", "minutes ahead")
        suite.expect(start(10) == "Starting now" && start(-20) == "Starting now", "around the start")
        suite.expect(start(-240) == "Started 4 min ago", "minutes after")
        suite.expect(start(90 * 60) == "Starts in 1 h 30 min" && start(120 * 60) == "Starts in 2 h", "hours")
        func compact(_ seconds: TimeInterval) -> String { MeetingStrings.compactStart(start: now.addingTimeInterval(seconds), now: now) }
        suite.expect(compact(170) == "in 3m" && compact(30) == "now" && compact(-5) == "live", "the island's short reading")
        suite.expect(MeetingStrings.people(0) == nil && MeetingStrings.people(1) == "1 person"
                        && MeetingStrings.people(6) == "6 people", "attendees")
        suite.expect(MeetingAlertLead.choices.map(MeetingStrings.alertLead)
                        == ["Off", "At start", "1 min before", "2 min before", "5 min before"],
                     "the alert's choices, off through five minutes")
    }
}
