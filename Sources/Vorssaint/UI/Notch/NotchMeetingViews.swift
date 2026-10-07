// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

// Fork: a meeting's Join wherever the island shows events. The closed island
// keeps the calendar strip and gives the time beside its clock to a green
// Join; the Calendar page and the Home widget put one on each meeting not
// yet over. Upstream views carry one-line hooks into these.

/// The meeting the closed island shows with its Join right now.
enum NotchMeetingIsland {
    static var meeting: NotchCalendarEvent? {
        let calendar = NotchCalendarService.shared
        guard let meeting = calendar.meetingSoon, meeting.meeting.link != nil, meeting.end > Date(),
              calendar.countdown?.event.id == meeting.id else { return nil }
        return meeting
    }

    /// Whether the closed island shows the calendar strip for a meeting,
    /// whatever the countdown's own settings say.
    static var showsActivity: Bool { meeting != nil }

    static func meeting(for countdown: NotchCalendarCountdown) -> NotchCalendarEvent? {
        meeting.flatMap { $0.id == countdown.event.id ? $0 : nil }
    }

    /// The width the right wing gives the time beside the clock, so a
    /// meeting's Join fits there instead; 0 when it is no meeting.
    static func joinWidth(_ countdown: NotchCalendarCountdown) -> CGFloat {
        meeting(for: countdown) == nil ? 0 : NotchMeetingPill.width(clock: false)
    }

    /// How much wider than the event's dot and clock a paired strip's Join is.
    static func pairedExtra(_ countdown: NotchCalendarCountdown?) -> CGFloat {
        guard let countdown, meeting(for: countdown) != nil else { return 0 }
        // The dot and clock as the hanging strip measures them.
        let clockMark = NotchCalendarSupport.stripDotWidth + NotchCalendarSupport.stripClockSpacing
            + ("00:00" as NSString).size(withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            ]).width.rounded(.up)
        return max(0, NotchMeetingPill.width(clock: true) - clockMark)
    }
}

/// The green Join: a camera and the word, or beside another activity, a
/// camera and the clock.
struct NotchMeetingPill: View {
    /// Shown in place of the word when the pill stands for the whole event.
    var clock: String?
    var ongoing = false
    var height: CGFloat = 18

    static let symbol = "video.fill"
    static let spacing: CGFloat = 3
    static let padding: CGFloat = 7
    static let symbolFont = NSFont.systemFont(ofSize: 9, weight: .bold)
    static let wordFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    static let clockFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    static let fill = Color(red: 0.19, green: 0.74, blue: 0.35)

    var body: some View {
        HStack(spacing: Self.spacing) {
            Image(systemName: Self.symbol).font(Font(Self.symbolFont as CTFont))
            Group {
                if let clock {
                    Text(clock).font(Font(Self.clockFont as CTFont))
                        .modifier(NotchRollingDigits(value: clock, countsDown: true, everySecond: false))
                } else {
                    Text(MeetingStrings.join).font(Font(Self.wordFont as CTFont))
                }
            }
            .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Self.padding)
        .frame(height: height)
        .background(Self.fill.opacity(ongoing ? 0.8 : 1), in: Capsule())
        .fixedSize()
    }

    static var clockWidth: CGFloat { measure("00:00", clockFont) }

    /// As drawn, so the strip around it keeps its size while the clock runs.
    static func width(clock: Bool) -> CGFloat {
        let symbolWidth = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: symbolFont.pointSize, weight: .bold))?
            .size.width ?? symbolFont.pointSize * 1.4
        let text = clock ? clockWidth : measure(MeetingStrings.join, wordFont)
        return (padding * 2 + symbolWidth.rounded(.up) + spacing + text).rounded(.up)
    }

    private static func measure(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up) + 1
    }
}

/// The hanging strip's row for a meeting soon or under way: the title opens
/// the Calendar page as before, the clock keeps counting and the Join joins.
struct NotchMeetingStripRow: View {
    @ObservedObject var service: NotchService
    let countdown: NotchCalendarCountdown
    let meeting: NotchCalendarEvent
    let title: String
    let remaining: String
    let geometry: NotchGeometry
    let usesFullRow: Bool

    var body: some View {
        Group {
            if usesFullRow {
                HStack(spacing: 6) {
                    Button { service.openCountdownEvent() } label: {
                        HStack(spacing: 6) {
                            dot
                            Text(title).font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            clock
                        }
                        .contentShape(Rectangle())
                    }
                    join
                }
                .padding(.horizontal, max(10, geometry.compactActivityEdgeInset(boxHeight: 9, radius: 0)))
            } else {
                let inset = geometry.compactActivityEdgeInset(boxHeight: 9, radius: 0)
                HStack(spacing: 0) {
                    Button { service.openCountdownEvent() } label: {
                        HStack(spacing: NotchCalendarSupport.stripTitleSpacing) {
                            dot
                            Text(title).font(.system(size: 11, weight: .semibold))
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .padding(.leading, inset)
                        .frame(width: geometry.compactActivityWingWidth, height: geometry.compactActivityContentHeight,
                               alignment: .trailing)
                        .clipped()
                        .contentShape(Rectangle())
                    }
                    Color.clear.frame(width: geometry.compactActivityCameraGap)
                    HStack(spacing: NotchCalendarSupport.stripClockSpacing) {
                        Button { service.openCountdownEvent() } label: { clock.contentShape(Rectangle()) }
                        join
                    }
                    .padding(.trailing, inset)
                    .frame(width: geometry.compactActivityWingWidth, height: geometry.compactActivityContentHeight,
                           alignment: .leading)
                }
            }
        }
        .frame(width: geometry.compactActivitySize.width - geometry.compactActivityHorizontalPadding * 2,
               height: geometry.compactActivityContentHeight)
        .help(title)
    }

    private var dot: some View {
        Circle().fill(meeting.color.color)
            .frame(width: NotchCalendarSupport.stripDotWidth, height: NotchCalendarSupport.stripDotWidth)
            .overlay { Circle().strokeBorder(.white.opacity(0.5), lineWidth: 0.5) }
            .accessibilityHidden(true)
    }

    private var clock: some View {
        Text(remaining)
            .font(.system(size: 13, weight: .medium)).monospacedDigit()
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(countdown.ongoing ? Color.mint : Color.white)
            .modifier(NotchRollingDigits(value: remaining, countsDown: true, everySecond: false))
            .accessibilityLabel(countdown.ongoing ? FeatureStrings.notchCalendar(L10n.shared.language).ongoing
                                : MeetingStrings.compactStart(start: meeting.start, now: Date()))
    }

    private var join: some View {
        Button { MeetingJoiner.join(meeting) } label: {
            NotchMeetingPill(ongoing: countdown.ongoing,
                             height: min(18, max(14, geometry.compactActivityContentHeight - 4)))
                .contentShape(Capsule())
        }
        .accessibilityLabel("\(MeetingStrings.join) \(meeting.meeting.link?.provider.name ?? "")")
        .help("\(MeetingStrings.join) \(meeting.meeting.link?.provider.name ?? "")")
    }
}

/// A provider's own app icon where it is installed, otherwise a camera.
struct NotchMeetingProviderIcon: View {
    let provider: MeetingProvider
    var size: CGFloat = 14

    var body: some View {
        if let icon = provider.appBundleIdentifiers.lazy.compactMap({ NotchHomeAppIcon.icon(for: $0) }).first {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "video.fill").font(.system(size: size * 0.7, weight: .semibold))
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}

/// Join on an event card, for a meeting that has not ended: green once it is
/// about to start or under way, quieter before.
struct NotchMeetingJoinButton: View {
    let event: NotchCalendarEvent
    let now: Date
    /// The room a card leaves for it at its trailing edge.
    static let width: CGFloat = 66

    static func shows(_ event: NotchCalendarEvent, now: Date) -> Bool {
        event.meeting.link != nil && !event.allDay && event.end > now
    }

    var body: some View {
        if let link = event.meeting.link, Self.shows(event, now: now) {
            let imminent = event.start.timeIntervalSince(now) <= max(MeetingSettings.current().soonLead, 5 * 60)
            Button { MeetingJoiner.join(event) } label: {
                HStack(spacing: 4) {
                    NotchMeetingProviderIcon(provider: link.provider, size: 13)
                    Text(MeetingStrings.join).font(.system(size: 11, weight: .bold)).lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(imminent ? NotchMeetingPill.fill : Color.white.opacity(0.14), in: Capsule())
                .contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(NotchButtonStyle(cornerRadius: 11))
            .help("\(MeetingStrings.join) \(link.provider.name)")
            .accessibilityLabel("\(MeetingStrings.join) \(link.provider.name)")
        }
    }
}

// MARK: - Closed island

extension NotchService {
    /// A floating capsule opens as a whole, so a click on the part where its
    /// Join is drawn joins instead; the hanging strip's Join is its own button.
    func joinsMeetingFromClick() -> Bool {
        guard geometry.floats, !expanded, compactActivity == .calendar, let meeting = NotchMeetingIsland.meeting else {
            return false
        }
        let frame = geometry.frame(for: surfaceSize)
        let pill = NotchMeetingPill.width(clock: compactCompanion != nil)
        let zone = NotchCapsuleLayout.side(geometry) + NotchCapsuleLayout.endPadding + pill + 6
        let pointer = NSEvent.mouseLocation
        guard pointer.x >= frame.maxX - zone, pointer.x <= frame.maxX + 1 else { return false }
        MeetingJoiner.join(meeting)
        return true
    }
}

extension NotchCapsuleLayout {
    /// A meeting's capsule: its dot and title, then the clock and the Join;
    /// paired, what shares the capsule, then the Join with the clock in it.
    static func meetingSurface(_ countdown: NotchCalendarCountdown, companion: NotchCompactActivity?,
                               workingAgents: Int, downloadPercent: Bool, geometry: NotchGeometry,
                               language: AppLanguage) -> CGSize? {
        guard NotchMeetingIsland.meeting(for: countdown) != nil else { return nil }
        if let companion {
            let mark = timerMarkWidth(companion: companion, workingAgents: workingAgents,
                                      downloadPercent: downloadPercent, geometry: geometry, language: language)
            return surface(content: mark + markGap(.calendar) + NotchMeetingPill.width(clock: true),
                           leading: companion == .music ? artworkInset(geometry) : endPadding,
                           maximum: Maximum.activity, geometry: geometry)
        }
        let content = calendarDotSide + spacing + width(calendarTitle(countdown, language: language), font: titleFont)
            + groupSpacing + width("00:00", font: readingFont) + markSpacing + NotchMeetingPill.width(clock: false)
        return surface(content: content, maximum: Maximum.calendar, geometry: geometry)
    }
}
