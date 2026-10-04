// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: the tabbed island's Home tab, the chosen widgets side by side.
struct NotchHomeView: View {
    @ObservedObject var service: NotchService
    let size: CGSize

    var body: some View {
        let widgets = NotchHomeWidget.current(modules: service.modules)
        Group {
            if widgets.isEmpty {
                NotchEmptyView(symbol: "house",
                               message: "Add widgets to Home in Settings › Dynamic Island › Layout.")
            } else {
                HStack(alignment: .top, spacing: NotchTabbedLayout.widgetSpacing) {
                    ForEach(widgets) { widget in
                        content(widget)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    @ViewBuilder private func content(_ widget: NotchHomeWidget) -> some View {
        switch widget {
        case .music: NotchHomeMusicWidget(service: service)
        case .calendar: NotchHomeCalendarWidget(service: service)
        case .timer: NotchHomeTimerWidget(service: service)
        }
    }
}

// MARK: - Music

/// The cover with its player's icon, the track, the line being sung, the
/// timeline and the transport, tinted with the cover's own colour.
struct NotchHomeMusicWidget: View {
    @ObservedObject var service: NotchService
    @ObservedObject private var music = NotchMusicService.shared
    @ObservedObject private var lyrics = NotchLyricsService.shared
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.notchSettingsPreview) private var preview
    /// What a tap on play or pause asked for, until the player says so.
    @State private var requestedPlaying: Bool?
    private var text: RadialMenuFeatureStrings { FeatureStrings.radialMenu(l10n.language) }
    private var accent: Color { music.artworkTint?.color ?? .white }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.height, NotchTabbedLayout.homeContentHeight)
            HStack(alignment: .top, spacing: 16) {
                artwork(side: side)
                Group {
                    if let playback = music.playback {
                        details(playback)
                    } else {
                        idle
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: side, alignment: .topLeading)
            }
        }
        .onAppear {
            guard !preview else { return }
            music.refreshAutomation()
            syncLyrics()
        }
        .onChange(of: music.playback.map(NotchMusicIdentity.init)) { syncLyrics() }
        .onDisappear {
            guard !preview else { return }
            NotchLyricsService.shared.hide()
        }
    }

    private func syncLyrics() {
        guard !preview else { return }
        NotchLyricsService.shared.update(playback: music.playback, visible: music.playback != nil)
    }

    private func artwork(side: CGFloat) -> some View {
        let playing = music.playback?.isPlaying == true
        let halo = music.artworkTint?.color ?? .clear
        return ZStack(alignment: .bottomTrailing) {
            Button {
                if let playback = music.playback { RadialNowPlayingApplication.open(playback.track) }
            } label: {
                NotchArtwork(image: music.artwork, size: side)
                    .scaleEffect(playing || reduceMotion ? 1 : 0.95)
                    .shadow(color: halo.opacity(0.35), radius: 16, y: 6)
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: playing)
            }
            .buttonStyle(NotchButtonStyle(cornerRadius: side * 0.19))
            .disabled(music.playback == nil)
            .help(text.mediaNowPlaying)
            .accessibilityLabel(text.mediaNowPlaying)
            if let icon = NotchHomeAppIcon.icon(for: music.playback?.track.appBundleIdentifier) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
                    .offset(x: 6, y: 6)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: side, height: side)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(music.awaitingPlayback ? text.mediaNowPlaying : text.mediaNothingPlaying)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Text(FeatureStrings.notch(l10n.language).musicHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
    }

    private func details(_ playback: NotchPlayback) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(playback.track.title ?? text.mediaNowPlaying)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .help(playback.track.title ?? "")
            Text(music.commandFailed ? FeatureStrings.notchMusicExtras(l10n.language).playbackFailed
                 : playback.track.artist ?? playback.track.album ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(music.commandFailed ? .orange : accent)
                .lineLimit(1)
                .padding(.top, 1)
            lyricLine(playback)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .padding(.top, 3)
            Spacer(minLength: 4)
            NotchMusicTimeline(playback: playback, service: music, tint: accent)
            transport(playback)
        }
    }

    /// The line being sung when synced lyrics are loaded, otherwise the album.
    @ViewBuilder private func lyricLine(_ playback: NotchPlayback) -> some View {
        if let loaded = lyrics.lyrics, !loaded.lines.isEmpty {
            TimelineView(.explicit(loaded.changeDates(for: playback, offset: lyrics.offset, from: Date()))) { context in
                let index = loaded.activeIndex(at: playback.position(at: context.date), offset: lyrics.offset)
                Text(index.map { loaded.lines[$0].text } ?? "♪")
                    .contentTransition(.opacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: index)
            }
        } else if let album = playback.track.album, album != playback.track.title {
            Text(album)
        } else {
            Text(" ")
        }
    }

    @ViewBuilder private func transport(_ playback: NotchPlayback) -> some View {
        if !playback.canSendCommandsDirectly, music.automationAvailability?.access != .granted,
           music.automationAvailability?.access == .consent {
            Button(FeatureStrings.notchMusicExtras(l10n.language).allowPlayback) { music.requestAutomationAccess() }
                .buttonStyle(.borderless).font(.caption)
                .disabled(music.requestingAutomation)
                .frame(height: 28)
        } else {
            HStack(spacing: 14) {
                if !music.lacksTrackSkipping(.previous) {
                    control("backward.fill", title: text.mediaPrevious, command: .previous, playback)
                }
                toggle(playback)
                if !music.lacksTrackSkipping(.next) {
                    control("forward.fill", title: text.mediaNext, command: .next, playback)
                }
                Spacer(minLength: 0)
                if service.modules.contains(.music) {
                    Button { service.select(.music) } label: {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(NotchButtonStyle(cornerRadius: 8))
                    .help(NotchModule.music.title(l10n.language))
                    .accessibilityLabel(NotchModule.music.title(l10n.language))
                }
            }
            .frame(height: 28)
        }
    }

    private func toggle(_ playback: NotchPlayback) -> some View {
        let playing = requestedPlaying ?? playback.isPlaying
        return Button {
            if music.canPerform(.toggle) {
                let direct = playback.canSendCommandsDirectly
                if music.send(.toggle, context: playback.commandContext), direct { requestedPlaying = !playing }
            } else { music.requestAutomationAccess() }
        } label: {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: 22, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: playing)
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 8))
        .onChange(of: playback.isPlaying) { if playback.isPlaying == requestedPlaying { requestedPlaying = nil } }
        .onChange(of: playback.track) { requestedPlaying = nil }
        .task(id: requestedPlaying) {
            guard requestedPlaying != nil else { return }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled { requestedPlaying = nil }
        }
        .keyboardShortcut(preview ? nil : KeyboardShortcut(.space, modifiers: []))
        .accessibilityLabel(text.mediaPlayPause)
        .help(text.mediaPlayPause)
    }

    private func control(_ symbol: String, title: String, command: NotchMusicService.Command,
                         _ playback: NotchPlayback) -> some View {
        Button { music.send(command, context: playback.commandContext) } label: {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 8))
        .disabled(!music.canPerform(command))
        .accessibilityLabel(title)
        .help(title)
    }
}

// MARK: - Calendar

/// The month beside a week around today, and the chosen day's events.
struct NotchHomeCalendarWidget: View {
    @ObservedObject var service: NotchService
    @ObservedObject private var calendar = NotchCalendarService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var l10n = L10n.shared
    @State private var selectedDay: Date?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let today = Calendar.current.startOfDay(for: context.date)
            let day = selectedDay ?? today
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(day.formatted(.dateTime.month(.abbreviated)))
                        .font(.system(size: 15, weight: .bold))
                    Text(day.formatted(.dateTime.year()))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 42, alignment: .leading)
                .padding(.top, 6)
                VStack(spacing: 10) {
                    weekStrip(today: today, selected: day)
                    if permissions.calendarAccess == .fullAccess {
                        agenda(day: day, today: today, now: context.date)
                    } else {
                        permissionPrompt
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .onChange(of: today) { _, _ in selectedDay = nil }
        }
        .environment(\.locale, l10n.language.formattingLocale())
    }

    private func weekStrip(today: Date, selected: Date) -> some View {
        let days = (-3...3).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
        return HStack(spacing: 2) {
            ForEach(days, id: \.self) { day in
                let isSelected = Calendar.current.isDate(day, inSameDayAs: selected)
                let isToday = Calendar.current.isDate(day, inSameDayAs: today)
                Button { selectedDay = isToday ? nil : day } label: {
                    VStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.55))
                        Text(day.formatted(.dateTime.day(.twoDigits)))
                            .font(.system(size: 15, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? .white : isToday ? Color.accentColor : .white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(NotchButtonStyle(cornerRadius: 10, lifts: false))
                .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private func agenda(day: Date, today: Date, now: Date) -> some View {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let events = calendar.events.filter { $0.start < end && $0.end > start && !($0.end <= now && start == today && !$0.allDay) }
        if events.isEmpty {
            VStack(spacing: 3) {
                Image(systemName: "calendar.badge.checkmark")
                    .font(.system(size: 20, weight: .regular))
                    .padding(.bottom, 2)
                Text(start == today ? "No events today" : "No events")
                    .font(.system(size: 13, weight: .bold))
                Text("Enjoy your free time!")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(events.prefix(2)) { event in
                    Button { service.select(.calendar) } label: { row(event) }
                        .buttonStyle(NotchButtonStyle(cornerRadius: 8, lifts: false))
                }
                if events.count > 2 {
                    Text("+\(events.count - 2) more")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 11)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ event: NotchCalendarEvent) -> some View {
        HStack(spacing: 8) {
            Capsule().fill(event.color.color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title.isEmpty ? FeatureStrings.notchCalendar(l10n.language).untitled : event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(event.allDay ? "All day"
                     : "\(event.start.formatted(date: .omitted, time: .shortened)) – \(event.end.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var permissionPrompt: some View {
        VStack(spacing: 6) {
            Text("Calendar access needed")
                .font(.system(size: 12, weight: .semibold))
            Button("Set Up") { service.select(.calendar) }
                .buttonStyle(.borderless)
                .font(.system(size: 12, weight: .medium))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Timer

/// A running timer's reading and controls, or a few quick starts.
struct NotchHomeTimerWidget: View {
    @ObservedObject var service: NotchService
    @ObservedObject private var timer = NotchTimerService.shared
    @ObservedObject private var l10n = L10n.shared
    private static let presets = [5, 10, 15, 25]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { service.select(.timer) } label: {
                Label(NotchModule.timer.title(l10n.language), systemImage: "timer")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            if timer.session.hasSession { active } else { presets }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var active: some View {
        let session = timer.session
        return VStack(alignment: .leading, spacing: 10) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(session.completed ? "Done"
                     : NotchTimerSupport.compactText(for: session, at: timer.now,
                                                     locale: l10n.language.formattingLocale()))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            HStack(spacing: 8) {
                if session.canStartNext {
                    pill("Next", symbol: "forward.fill", action: timer.startNext)
                } else if !session.completed {
                    pill(session.isPaused ? "Resume" : "Pause",
                         symbol: session.isPaused ? "play.fill" : "pause.fill", action: timer.pauseOrResume)
                }
                pill(session.completed ? "Dismiss" : "Stop", symbol: "xmark", action: timer.cancel)
            }
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick start")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.self) { minutes in
                    pill("\(minutes)m", symbol: nil) { timer.start(mode: .timer, minutes: minutes) }
                }
            }
        }
    }

    private func pill(_ title: String, symbol: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
                Text(title).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(.white.opacity(0.1), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 13))
    }
}
