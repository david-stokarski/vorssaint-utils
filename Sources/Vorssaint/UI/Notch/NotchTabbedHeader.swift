// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: the tabbed island's top row. Home and the pinned set as tabs on the
/// leading side; what is playing, the charge and Settings trailing.
/// A capture being edited, a detail page or the section gallery take the row
/// over the way the classic header gives them room.
struct NotchTabbedHeader: View {
    @ObservedObject var service: NotchService
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var music = NotchMusicService.shared
    @ObservedObject private var launcher = QuickLauncherService.shared
    @ObservedObject private var awake = KeepAwakeManager.shared
    @ObservedObject private var microphone = MicMuteService.shared
    @ObservedObject private var recorder = ScreenRecorderService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selection
    private var text: NotchStrings { FeatureStrings.notch(l10n.language) }

    private var showsDetail: Bool { service.showingAppPanel || service.selectedMetric != nil }

    private var editingCapture: AnyView? {
        guard service.selected == .captures, !service.showingHome, !showsDetail, !service.showingSections else { return nil }
        return service.captureActions
    }

    /// A volume or brightness change while open reads in the row, as it does
    /// in the classic header.
    private var feedback: NotchNotice? {
        guard let notice = service.notice, notice.level != nil,
              [.volume, .brightness, .keyboardLight].contains(notice.event) else { return nil }
        return notice
    }

    var body: some View {
        let gap = service.expandedGeometry.headerCameraGap
        let half: CGFloat? = gap > 0 ? (service.contentSize.width - gap) / 2 : nil
        HStack(spacing: 0) {
            leading
                .frame(width: half, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(feedback == nil ? 1 : 0)
                .allowsHitTesting(feedback == nil)
                .overlay(alignment: .leading) {
                    if let feedback { NotchExpandedLevelView(notice: feedback) }
                }
            if gap > 0 { Color.clear.frame(width: gap) }
            trailing
                .frame(width: half, alignment: .trailing)
        }
        .frame(height: service.expandedGeometry.headerRowHeight)
        .contentShape(Rectangle())
    }

    // MARK: Leading

    @ViewBuilder private var leading: some View {
        if showsDetail {
            HStack(spacing: 6) {
                NotchIconButton(symbol: "chevron.left", title: l10n.s.obBack, action: service.goBack)
                Text(service.detailTitle)
                    .font(Font(NotchLayout.detailTitleFont as CTFont))
                    .lineLimit(1)
            }
        } else {
            tabStrip
        }
    }

    private var selectedTab: String? {
        if service.showingSections { return NotchQuickAction.explore.id }
        if service.showingHome { return "home" }
        if showsDetail { return nil }
        return NotchQuickAction.module(service.selected).id
    }

    private var tabStrip: some View {
        HStack(spacing: NotchTabbedLayout.tabSpacing) {
            ForEach(NotchTabbedLayout.currentTabs()) { item in
                switch item {
                case .home: tab(id: "home", symbol: "house", title: "Home", action: service.showHome)
                case .action(let action): quickTab(action)
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82), value: selectedTab)
    }

    private func quickTab(_ action: NotchQuickAction) -> some View {
        var symbol = action.symbol
        var title = action.title(l10n)
        var active = false
        switch action {
        case .pin:
            active = service.pinned
            if service.pinned { symbol = "pin.fill"; title = text.unpin }
        case .control(.keepAwake):
            active = awake.isActive
            if awake.isActive { symbol = "cup.and.saucer.fill" }
        case .control(.microphone):
            active = microphone.isMuted
            if microphone.isMuted { symbol = "mic.slash.fill" }
        case .control(.recording):
            active = recorder.isRecording
            if recorder.isRecording { symbol = "stop.circle.fill" }
        default: break
        }
        return tab(id: action.id, symbol: symbol, title: title, active: active) {
            // A second click on the gallery's tab returns to the page behind it.
            service.activateQuickAction(action)
        }
    }

    /// `active` lights a toggle such as Keep Awake without making it the page.
    private func tab(id: String, symbol: String, title: String, active: Bool = false,
                     action: @escaping () -> Void) -> some View {
        let selected = selectedTab == id
        return Button(action: action) {
            Image(systemName: symbol)
                .symbolVariant(selected ? .fill : .none)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected || active ? .white : .white.opacity(0.5))
                .frame(width: NotchTabbedLayout.tabWidth, height: NotchTabbedLayout.tabHeight)
                .background {
                    if selected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(.white.opacity(0.14))
                            .matchedGeometryEffect(id: "tab", in: selection)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(NotchButtonStyle(cornerRadius: 9, lifts: false))
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("notch.tab.\(id)")
    }

    // MARK: Trailing

    @ViewBuilder private var trailing: some View {
        if let editingCapture {
            HStack(spacing: 6) {
                editingCapture.fixedSize()
                settings
            }
        } else if service.showingSections {
            HStack(spacing: 6) {
                NotchSectionSearch(service: service, maximumFieldWidth: 150)
                settings
            }
        } else {
            HStack(spacing: 10) {
                NotchUpdateControl(action: service.showUpdate, compact: true)
                nowPlaying
                battery
                pageActions
                settings
            }
        }
    }

    /// What is playing, from any tab but the player's own.
    @ViewBuilder private var nowPlaying: some View {
        if let playback = music.playback, playback.isPlaying,
           service.showingHome || service.selected != .music {
            Button {
                if service.modules.contains(.music) { service.select(.music) } else { service.showHome() }
            } label: {
                HStack(spacing: 5) {
                    if let icon = NotchHomeAppIcon.icon(for: playback.track.appBundleIdentifier) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    NotchLiveEqualizerBars(bars: 3, barWidth: 2, height: 10,
                                           tint: music.artworkTint?.color ?? .white)
                }
                .padding(.horizontal, 6)
                .frame(height: NotchTabbedLayout.tabHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(NotchButtonStyle(cornerRadius: 8, lifts: false))
            .help(playback.track.title ?? FeatureStrings.radialMenu(l10n.language).mediaNowPlaying)
            .accessibilityLabel(FeatureStrings.radialMenu(l10n.language).mediaNowPlaying)
            .transition(.opacity)
        }
    }

    @ViewBuilder private var battery: some View {
        let power = service.power
        if power.hasBattery, let percent = power.chargePercent {
            let charging = power.isCharging || (power.externalConnected && percent >= 100)
            HStack(spacing: 5) {
                Text("\(percent)%")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                Image(systemName: Self.batterySymbol(percent: percent, charging: charging))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(charging ? .green : percent <= 20 ? .red : .white)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Battery \(percent)%" + (charging ? ", charging" : ""))
        }
    }

    static func batterySymbol(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case 88...: return "battery.100percent"
        case 63..<88: return "battery.75percent"
        case 38..<63: return "battery.50percent"
        case 13..<38: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    /// A kept-open island can be let go from the row; the gear opens Settings.
    private var settings: some View {
        HStack(spacing: 2) {
            if service.pinned {
                NotchIconButton(symbol: "pin.fill", title: text.unpin, selected: true) { service.pinned = false }
            }
            NotchIconButton(symbol: "gearshape", title: l10n.s.menuSettings, action: service.openSettings)
        }
    }

    /// The tools and history pages keep their own actions in the row.
    @ViewBuilder private var pageActions: some View {
        let onPage = !service.showingHome && !service.showingSections && !showsDetail
        if onPage, service.selected == .tools, launcher.activeUtility == nil {
            NotchIconButton(symbol: launcher.isEditing ? "checkmark" : "slider.horizontal.3",
                            title: text.customizeTools, selected: launcher.isEditing) {
                withAnimation(.easeOut(duration: 0.15)) { launcher.isEditing.toggle() }
            }
        }
        if onPage, service.selected == .captures, service.captureContent == nil {
            NotchTabbedClearCapturesButton()
        }
    }
}

/// Observes the history on its own, so a new capture does not redraw the row.
private struct NotchTabbedClearCapturesButton: View {
    @ObservedObject private var history = RecentCaptureService.shared
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        NotchIconButton(symbol: "trash", title: FeatureStrings.recentCaptures(l10n.language).clear,
                        action: RecentCapturesView.confirmClearAboveIsland)
            .disabled(RecentCapturesView.visible(history.entries).isEmpty)
    }
}

/// App icons by bundle identifier, read once per app.
enum NotchHomeAppIcon {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        if let cached = cache[bundleIdentifier] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleIdentifier] = icon
        return icon
    }
}
