// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: Settings › Live Wallpaper. Every scene moving in a grid, dark or
/// light or following the appearance, how fast and how strongly it drifts,
/// and whether it reaches the lock screen and the Mac's own wallpaper setting.
struct LiveWallpaperSettings: View {
    @ObservedObject private var service = LiveWallpaperService.shared
    @AppStorage(DefaultsKey.liveWallpaperEnabled) private var enabled = true
    @AppStorage(DefaultsKey.liveWallpaperMode) private var mode = LiveWallpaperMode.automatic.rawValue
    @AppStorage(DefaultsKey.liveWallpaperScene) private var scene = LiveWallpaperScene.mist.rawValue
    @AppStorage(DefaultsKey.liveWallpaperLockScreen) private var lockScreen = true
    @AppStorage(DefaultsKey.liveWallpaperSetsSystem) private var setsSystem = true
    @AppStorage(DefaultsKey.liveWallpaperSpeed) private var speed = 1.0
    @AppStorage(DefaultsKey.liveWallpaperIntensity) private var intensity = 1.0
    @AppStorage(DefaultsKey.liveWallpaperBlur) private var blur = 0.0

    private var selectedMode: LiveWallpaperMode { LiveWallpaperMode.sanitized(mode) }
    private var selectedScene: LiveWallpaperScene { LiveWallpaperScene.sanitized(scene) }
    /// The palette the tiles show: the one on screen now.
    private var shownKind: LiveWallpaperStyle.Kind {
        selectedMode.kind(darkAppearance: LiveWallpaperService.systemIsDark)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show Live Wallpaper", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                Text("A plain wallpaper with a faint drift that never repeats. It sits behind your desktop icons on every screen and Space, and holds still while it's covered, while displays sleep and in Low Power Mode.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = service.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text(LiveWallpaperSupport.title)
            }

            Section("Wallpaper") {
                Picker("Palette", selection: $mode) {
                    ForEach(LiveWallpaperMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) { _, _ in service.refreshStyle() }
                if selectedMode == .automatic {
                    Text("Black in dark mode, paper white in light mode, fading across when your Mac's appearance changes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3), spacing: 14) {
                    ForEach(LiveWallpaperScene.allCases) { tile($0) }
                }
                .padding(.vertical, 4)
            }

            Section("Look") {
                factorSlider("Speed", value: $speed, low: "Slower", high: "Faster")
                factorSlider("Intensity", value: $intensity, low: "Fainter", high: "Stronger")
                blurSlider
                if speed != 1 || intensity != 1 || blur != 0 {
                    Button("Reset to Default") {
                        speed = 1
                        intensity = 1
                        blur = 0
                        service.refreshStyle()
                    }
                }
            }

            Section("Lock screen and Mac wallpaper") {
                Toggle("Drift on the lock screen", isOn: $lockScreen)
                    .onChange(of: lockScreen) { _, _ in service.syncWithPreferences() }
                Toggle("Set as the Mac's wallpaper", isOn: $setsSystem)
                    .onChange(of: setsSystem) { _, _ in service.syncWithPreferences() }
                Text("Sets the plain color as the wallpaper of every screen and Space, so the lock screen, Mission Control and a Mac without Vorssaint running match. Your previous wallpaper comes back when Live Wallpaper is turned off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private func tile(_ option: LiveWallpaperScene) -> some View {
        let style = LiveWallpaperStyle(scene: option, kind: shownKind).adjusted(intensity: intensity, blur: blur)
        let shown = option == selectedScene
        // Not a Button: a Button whose label holds the live Metal preview
        // never receives the click. The preview is left out of hit testing
        // and the whole tile takes the tap instead.
        return VStack(spacing: 6) {
            LiveWallpaperPreview(style: style, speed: LiveWallpaperSupport.clampedFactor(speed))
                .allowsHitTesting(false)
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(shown ? Color.accentColor : Color.primary.opacity(0.12),
                                  lineWidth: shown ? 2.5 : 1))
            Text(option.title).font(.callout).foregroundStyle(shown ? .primary : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(option) }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(shown ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose(option) }
    }

    private func choose(_ option: LiveWallpaperScene) {
        guard scene != option.rawValue else { return }
        scene = option.rawValue
        service.refreshStyle()
    }

    /// Softens whichever scene shows, lines and dots into a haze at the top.
    private var blurSlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Blur")
                Spacer()
                Text(blur < 0.01 ? "Off" : "\(Int((blur * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $blur, in: 0...1) {
                EmptyView()
            } minimumValueLabel: {
                Text("Sharp").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Soft").font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: blur) { _, _ in service.refreshStyle(animated: false) }
            Text("Softens every scene, on the desktop and the lock screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func factorSlider(_ title: String, value: Binding<Double>, low: String, high: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2g×", value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: LiveWallpaperSupport.factorRange) {
                EmptyView()
            } minimumValueLabel: {
                Text(low).font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: value.wrappedValue) { _, _ in service.refreshStyle(animated: false) }
        }
    }
}

/// A small live copy of a wallpaper, on its own clock.
private struct LiveWallpaperPreview: NSViewRepresentable {
    let style: LiveWallpaperStyle
    let speed: Double

    final class Coordinator {
        let clock: LiveWallpaperClock
        init(speed: Double) { clock = LiveWallpaperClock(speed: speed) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(speed: speed) }

    func makeNSView(context: Context) -> NSView {
        guard let view = LiveWallpaperView(frame: NSRect(x: 0, y: 0, width: 320, height: 200), style: style,
                                           clock: context.coordinator.clock, opaque: true,
                                           seed: SIMD2(Float.random(in: 0..<400), Float.random(in: 0..<400)))
        else { return NSView() }
        context.coordinator.clock.run()
        view.isAnimating = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.clock.setSpeed(speed)
        (nsView as? LiveWallpaperView)?.setStyle(style, animated: false)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        (nsView as? LiveWallpaperView)?.stop()
    }
}
