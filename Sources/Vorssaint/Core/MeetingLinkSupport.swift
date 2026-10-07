// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: joining meetings from the island, in the spirit of Dato and
// Fantastical. An event's video link is found in its URL, location and notes,
// unwrapped from the redirects mail scanners put around it and named by its
// provider. The closed island shows a meeting about to start with its Join, a
// large alert can stand in front of everything just before it, and a shortcut
// joins the next one. Everything decided here is pure, so the tests compile
// it; EventKit, the alert panel and the island's drawing live in
// Services/Notch and UI/Notch.

extension DefaultsKey {
    /// Zoom and Teams links open in their app when it is installed.
    static let notchMeetingOpensInApp = "notchMeetingOpensInApp"
    /// The closed island shows a meeting about to start, and under way, with its Join.
    static let notchMeetingSoonActivity = "notchMeetingSoonActivity"
    /// Minutes before the start the closed island begins to show it.
    static let notchMeetingSoonLead = "notchMeetingSoonLead"
    /// Minutes before the start the alert appears, 0 at the start; `MeetingAlertLead.off` for none.
    static let notchMeetingAlertLead = "notchMeetingAlertLead"
    /// Alerts for events with attendees but no link, as well as for meetings with one.
    static let notchMeetingAlertAllEvents = "notchMeetingAlertAllEvents"
    static let notchMeetingAlertSound = "notchMeetingAlertSound"
    static let notchMeetingJoinShortcut = "notchMeetingJoinShortcut"
    static let notchMeetingJoinShortcutEnabled = "notchMeetingJoinShortcutEnabled"
}

extension GlobalShortcut {
    /// J for join, on the free control-option-command layer.
    static let meetingJoinDefault = GlobalShortcut(keyCode: 0x26, modifiers: [.control, .option, .command])
}

// MARK: - Providers and links

enum MeetingProvider: String, CaseIterable, Sendable {
    case zoom, googleMeet, teams, webex, slack, around, whereby, jitsi, chime, goTo, faceTime, discord

    var name: String {
        switch self {
        case .zoom: return "Zoom"
        case .googleMeet: return "Google Meet"
        case .teams: return "Microsoft Teams"
        case .webex: return "Webex"
        case .slack: return "Slack Huddle"
        case .around: return "Around"
        case .whereby: return "Whereby"
        case .jitsi: return "Jitsi Meet"
        case .chime: return "Amazon Chime"
        case .goTo: return "GoTo Meeting"
        case .faceTime: return "FaceTime"
        case .discord: return "Discord"
        }
    }

    /// The short name a pill has room for.
    var shortName: String {
        switch self {
        case .googleMeet: return "Meet"
        case .teams: return "Teams"
        case .slack: return "Huddle"
        case .jitsi: return "Jitsi"
        case .chime: return "Chime"
        case .goTo: return "GoTo"
        default: return name
        }
    }

    /// The provider's own app, whose icon stands for it where installed.
    var appBundleIdentifiers: [String] {
        switch self {
        case .zoom: return ["us.zoom.xos"]
        case .teams: return ["com.microsoft.teams2", "com.microsoft.teams"]
        case .webex: return ["Cisco-Systems.Spark"]
        case .slack: return ["com.tinyspeck.slackmacgap"]
        case .around: return ["co.teamport.around"]
        case .chime: return ["com.amazon.Amazon-Chime"]
        case .goTo: return ["com.logmein.goto"]
        case .faceTime: return ["com.apple.FaceTime"]
        case .discord: return ["com.hnc.Discord"]
        case .googleMeet, .whereby, .jitsi: return []
        }
    }
}

struct MeetingLink: Equatable, Sendable {
    let provider: MeetingProvider
    /// The link as the invitation gives it, unwrapped from any redirect.
    let url: URL
}

/// Where the person stands in an event, as far as EventKit says.
enum MeetingParticipation: Equatable, Sendable {
    /// No attendees: a block of one's own time.
    case unknown
    /// Among the attendees, not having declined.
    case attending
    case organizer
    /// Attendees are listed and this Mac's user is not one of them, as on a
    /// colleague's shared calendar.
    case notInvited
}

/// What the island knows about an event as a meeting. Read with the event;
/// only the link and two numbers, never the notes themselves.
struct MeetingInfo: Equatable, Sendable {
    var link: MeetingLink?
    var attendeeCount = 0
    var participation: MeetingParticipation = .unknown

    /// The location line, unless it is only the link, which reads as the provider instead.
    func locationLabel(_ location: String) -> String {
        guard let link else { return location }
        let trimmed = location.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = MeetingLinkSupport.candidates(in: trimmed)
        // A bare address was found with the scheme put in front of it.
        let rest = candidates.flatMap { [$0, $0.replacingOccurrences(of: "https://", with: "")] }
            .reduce(trimmed) { $0.replacingOccurrences(of: $1, with: "") }
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        return candidates.isEmpty || !rest.isEmpty ? location : link.provider.name
    }
}

enum MeetingLinkSupport {
    /// The meeting link of an event: the strongest provider link anywhere in
    /// it, the event's own URL before its location and the location before
    /// its notes, and within one field the first. Any other web address is
    /// never offered as a meeting.
    static func link(url: URL?, location: String?, notes: String?) -> MeetingLink? {
        let fields = [url?.absoluteString, location, notes]
        var best: (link: MeetingLink, strength: Int)?
        for field in fields {
            guard let field, !field.isEmpty else { continue }
            for candidate in candidates(in: field) {
                guard let parsed = parse(candidate) else { continue }
                let unwrapped = unwrap(parsed)
                guard let provider = provider(of: unwrapped) else { continue }
                let strength = strength(of: unwrapped, provider: provider)
                if best == nil || strength > best!.strength {
                    best = (MeetingLink(provider: provider, url: unwrapped), strength)
                }
            }
        }
        return best?.link
    }

    // MARK: Finding links in text

    private static let addressCharacters = #"[^\s<>"'\[\]{}|\\^`]"#
    private static let schemeExpression = try! NSRegularExpression(
        pattern: #"(?i)(?:https?://|zoommtg://|zoomus://|msteams:/{0,2})"# + addressCharacters + "+")
    /// Invitations often write a provider's address without its scheme.
    private static let bareExpression = try! NSRegularExpression(
        pattern: #"(?i)(?<![\w./@:%-])(?:[a-z0-9-]+\.)*(?:zoom\.us|zoomgov\.com|meet\.google\.com|teams\.microsoft\.com"#
            + #"|teams\.live\.com|webex\.com|whereby\.com|around\.co|meet\.jit\.si|chime\.aws|gotomeeting\.com"#
            + #"|meet\.goto\.com|facetime\.apple\.com|discord\.gg|discord\.com|slack\.com)/"# + addressCharacters + "+")

    /// Every address in the text, in order: with a scheme, or a provider's
    /// host without one. HTML entities are read as their characters and
    /// punctuation a sentence put after an address is left off.
    static func candidates(in text: String) -> [String] {
        let text = decodingEntities(text)
        let range = NSRange(text.startIndex..., in: text)
        var found: [(Int, String)] = []
        for (expression, prefix) in [(schemeExpression, ""), (bareExpression, "https://")] {
            for match in expression.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let trimmed = trimmingTrailingPunctuation(String(text[swiftRange]))
                guard !trimmed.isEmpty else { continue }
                found.append((match.range.location, prefix + trimmed))
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    private static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        return [("&amp;", "&"), ("&#38;", "&"), ("&#x3D;", "="), ("&#x3d;", "="), ("&#61;", "="),
                ("&quot;", "\""), ("&#34;", "\""), ("&lt;", "<"), ("&gt;", ">"), ("&#x2F;", "/"), ("&#47;", "/")]
            .reduce(text) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    private static func trimmingTrailingPunctuation(_ address: String) -> String {
        var address = Substring(address)
        while let last = address.last, ".,;:!?)>*".contains(last) {
            // A closing parenthesis the address opened itself belongs to it.
            if last == ")", address.filter({ $0 == "(" }).count >= address.filter({ $0 == ")" }).count { break }
            address = address.dropLast()
        }
        return String(address)
    }

    private static func parse(_ candidate: String) -> URL? {
        if let url = URL(string: candidate), url.scheme != nil { return url }
        let allowed = CharacterSet.urlFragmentAllowed.union(.urlQueryAllowed).union(CharacterSet(charactersIn: "#%"))
        return candidate.addingPercentEncoding(withAllowedCharacters: allowed).flatMap(URL.init(string:))
    }

    // MARK: Redirects

    /// The address behind the redirects mail scanners and calendars put
    /// around links: Outlook SafeLinks, Google's redirect, Proofpoint and
    /// Slack's. Wrapping inside wrapping is followed a few levels deep.
    static func unwrap(_ url: URL) -> URL {
        var url = url
        for _ in 0..<4 {
            guard let inner = unwrappedOnce(url) else { break }
            url = inner
        }
        return url
    }

    private static func unwrappedOnce(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let items = components.queryItems ?? []
        func item(_ name: String) -> URL? {
            items.first { $0.name.lowercased() == name }?.value.flatMap(parse)
        }
        if host.hasSuffix("safelinks.protection.outlook.com") { return item("url") }
        if (host == "google.com" || host.hasSuffix(".google.com")), url.path == "/url" { return item("q") ?? item("url") }
        if host == "slack-redir.net" || host.hasSuffix(".slack-redir.net") { return item("url") }
        if host == "urldefense.com", url.absoluteString.contains("/v3/__") {
            let text = url.absoluteString
            guard let start = text.range(of: "/v3/__")?.upperBound,
                  let end = text.range(of: "__;", range: start..<text.endIndex)?.lowerBound else { return nil }
            return parse(String(text[start..<end]))
        }
        if host == "urldefense.proofpoint.com", url.path.hasPrefix("/v2/url"),
           let raw = items.first(where: { $0.name == "u" })?.value {
            // Version 2 writes percent signs as dashes and slashes as underscores.
            let decoded = raw.replacingOccurrences(of: "-", with: "%").replacingOccurrences(of: "_", with: "/")
            return decoded.removingPercentEncoding.flatMap(parse)
        }
        return nil
    }

    // MARK: Providers

    /// The provider whose meeting the address joins, or nil for any other page,
    /// including the provider's own help, download and phone-number pages.
    static func provider(of url: URL) -> MeetingProvider? {
        let scheme = url.scheme?.lowercased() ?? ""
        switch scheme {
        case "zoommtg", "zoomus": return .zoom
        case "msteams": return .teams
        case "http", "https": break
        default: return nil
        }
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = url.path.lowercased()
        let parts = path.split(separator: "/").map(String.init)
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

        if on("zoom.us") || on("zoomgov.com") {
            return ["j", "my", "w", "s", "wc"].contains(parts.first ?? "") && parts.count >= 2 ? .zoom : nil
        }
        if host == "meet.google.com" {
            let code = parts.first == "_meet" ? parts.dropFirst().first : parts.first
            if parts.first == "lookup", parts.count >= 2 { return .googleMeet }
            return code.map(isMeetCode) == true ? .googleMeet : nil
        }
        if host == "teams.microsoft.com" || host == "teams.live.com" || on("teams.microsoft.us")
            || host == "teams.cloud.microsoft" {
            let joins = path.hasPrefix("/l/meetup-join/") || path.hasPrefix("/meet/") || path.hasPrefix("/dl/launcher/")
                || path.hasPrefix("/l/meeting/")
            return joins ? .teams : nil
        }
        if on("webex.com") {
            let reserved: Set<String> = ["webex.com", "help.webex.com", "cart.webex.com", "blog.webex.com",
                                         "status.webex.com", "pricing.webex.com"]
            return !reserved.contains(host) && !parts.isEmpty ? .webex : nil
        }
        if on("slack.com") { return parts.contains("huddle") ? .slack : nil }
        if on("around.co") {
            return (parts.first == "r" && parts.count >= 2) || (host == "meet.around.co" && !parts.isEmpty) ? .around : nil
        }
        if on("whereby.com") {
            let reserved: Set<String> = ["information", "pricing", "login", "user", "org", "blog", "download", "support"]
            return parts.count >= 1 && !reserved.contains(parts[0]) ? .whereby : nil
        }
        if host == "meet.jit.si" || host == "8x8.vc" { return parts.isEmpty ? nil : .jitsi }
        if host == "chime.aws" { return parts.first.map { $0.allSatisfy(\.isNumber) } == true ? .chime : nil }
        if host == "app.chime.aws" { return parts.first == "meetings" && parts.count >= 2 ? .chime : nil }
        if on("gotomeeting.com") { return parts.first == "join" && parts.count >= 2 ? .goTo : nil }
        if host == "meet.goto.com" { return parts.isEmpty ? nil : .goTo }
        if host == "app.goto.com" { return parts.first == "meeting" && parts.count >= 2 ? .goTo : nil }
        if host == "facetime.apple.com" { return parts.first == "join" ? .faceTime : nil }
        if host == "discord.gg" { return parts.isEmpty ? nil : .discord }
        if host == "discord.com" || host == "discordapp.com" {
            return ["channels", "invite", "events"].contains(parts.first ?? "") && parts.count >= 2 ? .discord : nil
        }
        return nil
    }

    /// Meet's codes are three groups of letters, "abc-defg-hij".
    private static func isMeetCode(_ code: String) -> Bool {
        let groups = code.split(separator: "-", omittingEmptySubsequences: false)
        return groups.count == 3 && groups.allSatisfy { (3...5).contains($0.count) && $0.allSatisfy(\.isLetter) }
    }

    /// A link to one meeting outranks a personal room or a start link, so a
    /// signature's "my room" never takes the place of the meeting itself.
    private static func strength(of url: URL, provider: MeetingProvider) -> Int {
        guard provider == .zoom, url.scheme?.lowercased().hasPrefix("http") == true else { return 2 }
        let first = url.path.lowercased().split(separator: "/").first.map(String.init) ?? ""
        return ["j", "w", "wc"].contains(first) ? 2 : 1
    }

    // MARK: Apps

    /// The address that opens the meeting in the provider's app rather than a
    /// browser: Zoom's `zoommtg:` join with the meeting number and passcode,
    /// or Teams' `msteams:`. Nil when the link has no app form, or already is one.
    static func appURL(for link: MeetingLink) -> URL? {
        guard let scheme = link.url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = link.url.host else { return nil }
        switch link.provider {
        case .zoom:
            let parts = link.url.path.split(separator: "/").map(String.init)
            // /j/123, /w/123 and the web client's /wc/join/123 or /wc/123/join.
            let number: String?
            switch parts.first?.lowercased() {
            case "j", "w": number = parts.dropFirst().first
            case "wc": number = parts.dropFirst().first { $0.allSatisfy(\.isNumber) }
            default: number = nil
            }
            guard let number, !number.isEmpty, number.allSatisfy(\.isNumber) else { return nil }
            var components = URLComponents()
            components.scheme = "zoommtg"
            components.host = host
            components.path = "/join"
            let query = URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            components.queryItems = [URLQueryItem(name: "action", value: "join"), URLQueryItem(name: "confno", value: number)]
                + query.filter { ["pwd", "tk", "uname"].contains($0.name) }
            return components.url
        case .teams:
            guard host.lowercased() == "teams.microsoft.com" else { return nil }
            let text = link.url.absoluteString
            guard let range = text.range(of: "://") else { return nil }
            return URL(string: "msteams" + text[range.lowerBound...])
        default:
            return nil
        }
    }
}

// MARK: - Preferences

/// The choices of the alert's lead, in minutes before the start.
enum MeetingAlertLead {
    static let off = -1
    static let choices = [off, 0, 1, 2, 5]
    static let defaultValue = 1
}

enum MeetingSoonLead {
    static let choices = [1, 2, 5, 10, 15]
    static let defaultValue = 5
}

struct MeetingSettings: Equatable {
    var opensInApp = true
    var soonActivity = true
    /// Seconds before the start the closed island shows the meeting.
    var soonLead: TimeInterval = TimeInterval(MeetingSoonLead.defaultValue * 60)
    /// Seconds before the start the alert appears, or nil for no alert.
    var alertLead: TimeInterval? = TimeInterval(MeetingAlertLead.defaultValue * 60)
    var alertsAllEvents = false
    var alertSound = false
    var joinShortcut = false

    static func current(in defaults: UserDefaults = .standard) -> MeetingSettings {
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
        let soon = defaults.object(forKey: DefaultsKey.notchMeetingSoonLead) as? Int ?? MeetingSoonLead.defaultValue
        let alert = defaults.object(forKey: DefaultsKey.notchMeetingAlertLead) as? Int ?? MeetingAlertLead.defaultValue
        return MeetingSettings(
            opensInApp: bool(DefaultsKey.notchMeetingOpensInApp, true),
            soonActivity: bool(DefaultsKey.notchMeetingSoonActivity, true),
            soonLead: TimeInterval(MeetingSoonLead.choices.contains(soon) ? soon : MeetingSoonLead.defaultValue) * 60,
            alertLead: alert < 0 ? nil : TimeInterval(min(alert, 60)) * 60,
            alertsAllEvents: bool(DefaultsKey.notchMeetingAlertAllEvents, false),
            alertSound: bool(DefaultsKey.notchMeetingAlertSound, false),
            joinShortcut: bool(DefaultsKey.notchMeetingJoinShortcutEnabled, false))
    }

    /// Whether anything here needs this week's events read while the
    /// Calendar page shows another month.
    var needsCurrentWeek: Bool { soonActivity || alertLead != nil || joinShortcut }

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.notchMeetingOpensInApp: true,
        DefaultsKey.notchMeetingSoonActivity: true,
        DefaultsKey.notchMeetingSoonLead: MeetingSoonLead.defaultValue,
        DefaultsKey.notchMeetingAlertLead: MeetingAlertLead.defaultValue,
        DefaultsKey.notchMeetingAlertAllEvents: false,
        DefaultsKey.notchMeetingAlertSound: false,
        DefaultsKey.notchMeetingJoinShortcut: GlobalShortcut.meetingJoinDefault.storageValue,
        DefaultsKey.notchMeetingJoinShortcutEnabled: false,
    ]
}

// MARK: - Timing

enum MeetingTiming {
    /// The meeting the closed island shows with its Join: one with a link
    /// starting within `lead`, the soonest, or else the one under way that
    /// began last. A meeting about to start outranks the one being sat in,
    /// which is the one to leave for.
    static func soonMeeting(_ events: [NotchCalendarEvent], now: Date, lead: TimeInterval) -> NotchCalendarEvent? {
        let meetings = NotchCalendarSupport.ordered(events).filter { !$0.allDay && $0.meeting.link != nil && $0.end > now }
        if let upcoming = meetings.first(where: { $0.start > now && $0.start.timeIntervalSince(now) <= lead }) {
            return upcoming
        }
        return meetings.filter { $0.start <= now }.max { $0.start < $1.start }
    }

    /// When `soonMeeting` can next change: a window opening, a start, an end.
    static func soonTransition(_ events: [NotchCalendarEvent], now: Date, lead: TimeInterval) -> Date? {
        NotchCalendarSupport.ordered(events).filter { !$0.allDay && $0.meeting.link != nil }
            .flatMap { [$0.start.addingTimeInterval(-lead), $0.start, $0.end] }
            .filter { $0 > now }.min()
    }

    /// The meeting "Join next meeting" joins: the one the island shows, or
    /// else the next with a link that has not ended, today or later in the
    /// week read.
    static func nextToJoin(_ events: [NotchCalendarEvent], now: Date,
                           lead: TimeInterval = 10 * 60) -> NotchCalendarEvent? {
        soonMeeting(events, now: now, lead: lead)
            ?? NotchCalendarSupport.ordered(events).first { !$0.allDay && $0.meeting.link != nil && $0.start > now }
    }
}

// MARK: - Alerts

/// What the alert has already done this session: events shown, by id, until
/// they end, and snoozed ones with when they come back. Never stored.
struct MeetingAlertMemory: Equatable {
    var shown: [String: Date] = [:]
    var snoozed: [String: Date] = [:]

    mutating func show(_ event: NotchCalendarEvent) {
        shown[event.id] = event.end
        snoozed[event.id] = nil
    }

    mutating func snooze(_ event: NotchCalendarEvent, until date: Date) {
        shown[event.id] = nil
        snoozed[event.id] = min(date, event.end)
    }

    /// Forgets events that have ended, so memory stays the size of a day.
    mutating func prune(now: Date) {
        shown = shown.filter { $0.value > now }
        snoozed = snoozed.filter { $0.value > now.addingTimeInterval(-24 * 60 * 60) }
    }
}

enum MeetingAlertSchedule {
    /// An alert shown late, after waking or unlocking, still helps for a
    /// few minutes into the meeting; after that the moment has passed.
    static let lateWindow: TimeInterval = 5 * 60
    static let snoozeInterval: TimeInterval = 60

    /// Timed events with a link or, when asked, with attendees, that the
    /// person takes part in. Declined events never reach the island.
    static func qualifies(_ event: NotchCalendarEvent, allEvents: Bool) -> Bool {
        guard !event.allDay, event.meeting.participation != .notInvited else { return false }
        return event.meeting.link != nil || (allEvents && event.meeting.attendeeCount > 0)
    }

    /// When the alert for the event is due, and until when it still makes
    /// sense; nil once it has been shown, or when it never will be.
    static func window(for event: NotchCalendarEvent, settings: MeetingSettings,
                       memory: MeetingAlertMemory) -> DateInterval? {
        guard let lead = settings.alertLead, qualifies(event, allEvents: settings.alertsAllEvents),
              memory.shown[event.id] == nil else { return nil }
        if let snoozed = memory.snoozed[event.id] {
            return snoozed < event.end ? DateInterval(start: snoozed, end: event.end) : nil
        }
        let start = event.start.addingTimeInterval(-lead)
        let end = min(event.end, event.start.addingTimeInterval(lateWindow))
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    /// The alerts due now, the soonest start first.
    static func due(_ events: [NotchCalendarEvent], now: Date, settings: MeetingSettings,
                    memory: MeetingAlertMemory) -> [NotchCalendarEvent] {
        NotchCalendarSupport.ordered(events).filter { event in
            guard let window = window(for: event, settings: settings, memory: memory) else { return false }
            return window.start <= now && now < window.end
        }
    }

    /// The next moment an alert becomes due.
    static func nextDue(_ events: [NotchCalendarEvent], now: Date, settings: MeetingSettings,
                        memory: MeetingAlertMemory) -> Date? {
        events.compactMap { window(for: $0, settings: settings, memory: memory)?.start }.filter { $0 > now }.min()
    }
}

// MARK: - Words

enum MeetingStrings {
    static let sectionTitle = "Meetings"
    static let join = "Join"
    static let joinNext = "Join Next Meeting"
    static let snooze = "Snooze 1 min"
    static let dismiss = "Dismiss"
    static let openInCalendar = "Open in Calendar"
    static let noMeeting = "No upcoming meeting with a video link"
    static let escapeHint = "Esc to dismiss"

    /// "Starts in 3 min", "Starting now", "Started 4 min ago".
    static func startText(start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if abs(seconds) < 30 { return "Starting now" }
        let minutes = max(1, Int((abs(seconds) / 60).rounded()))
        let amount = minutes >= 60 ? hours(minutes) : "\(minutes) min"
        return seconds > 0 ? "Starts in \(amount)" : "Started \(amount) ago"
    }

    private static func hours(_ minutes: Int) -> String {
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// The closed island's short reading: "in 3m", "now", "live".
    static func compactStart(start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        if seconds <= 0 { return "live" }
        if seconds < 60 { return "now" }
        return "in \(Int(ceil(seconds / 60)))m"
    }

    /// "Zoom · Design review · 10:30", for the Command Bar's row.
    static func summary(_ event: NotchCalendarEvent, now: Date, locale: Locale) -> String {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let time = event.start <= now ? "now"
            : NotchCalendarSupport.tileStartText(event.start, now: now, locale: locale)
        return [event.meeting.link?.provider.name, title.isEmpty ? nil : title, time]
            .compactMap { $0 }.joined(separator: " · ")
    }

    static func people(_ count: Int) -> String? {
        count <= 0 ? nil : count == 1 ? "1 person" : "\(count) people"
    }

    static func alertLead(_ minutes: Int) -> String {
        switch minutes {
        case MeetingAlertLead.off: return "Off"
        case 0: return "At start"
        default: return "\(minutes) min before"
        }
    }

    static func soonLead(_ minutes: Int) -> String { "\(minutes) min before" }
}
