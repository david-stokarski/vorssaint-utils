// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AVFoundation
import SwiftUI

// Fork: the recording overlays' controls: the editor's Overlays tab, the
// Settings section that chooses what a recording captures, and the toggles in
// the recording controls. Strings are written in place, as the fork's other
// features do, rather than added to every locale catalog.

/// The editor's Overlays tab. Each part shows only when the recording carries
/// what it acts on.
struct RecorderOverlayInspector: View {
    @ObservedObject var model: RecorderEditorModel

    private var settings: RecorderOverlaySettings { model.document.overlays }
    private var input: RecorderOverlayInput { model.overlayInput }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !input.clicks.isEmpty || model.hasPointerTrack {
                clicksSection
            }
            if !input.keystrokes.isEmpty {
                Divider().opacity(0.35)
                keystrokesSection
            }
            if input.camera != nil {
                Divider().opacity(0.35)
                cameraSection
            }
            if input.isEmpty {
                Text("This recording has no clicks, keystrokes or camera. Turn them on before recording, in the recording controls or in Settings.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Clicks

    private var clicksSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Clicks")
            if !input.clicks.isEmpty {
                Toggle("Highlight clicks", isOn: binding(\.clicks.enabled))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                if settings.clicks.enabled {
                    Picker("Style", selection: binding(\.clicks.style)) {
                        Text("Ring").tag(RecorderOverlaySettings.ClickStyle.ring)
                        Text("Pulse").tag(RecorderOverlaySettings.ClickStyle.pulse)
                        Text("Ripple").tag(RecorderOverlaySettings.ClickStyle.ripple)
                    }
                    .pickerStyle(.segmented)
                    Toggle("Right click looks different", isOn: binding(\.clicks.distinctRightClick))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            }
            if model.hasPointerTrack {
                Picker("Pointer", selection: binding(\.clicks.pointerEffect)) {
                    Text("Plain").tag(RecorderOverlaySettings.PointerEffect.none)
                    Text("Halo").tag(RecorderOverlaySettings.PointerEffect.halo)
                    Text("Spotlight").tag(RecorderOverlaySettings.PointerEffect.spotlight)
                }
                .pickerStyle(.menu)
            }
            if settings.clicks.enabled && !input.clicks.isEmpty || settings.clicks.pointerEffect == .halo {
                colorRow
            }
            if settings.clicks.enabled && !input.clicks.isEmpty || settings.clicks.pointerEffect != .none {
                slider("Size", value: settings.clicks.size, range: RecorderOverlaySettings.Clicks.sizeRange,
                       format: "%.2f×") { set(\.clicks.size, $0) }
            }
        }
    }

    private var colorRow: some View {
        HStack(spacing: 7) {
            ForEach(RecorderOverlaySettings.Palette.allCases, id: \.self) { palette in
                let rgb = palette.rgb
                let selected = settings.clicks.color == palette
                Button {
                    set(\.clicks.color, palette)
                } label: {
                    Circle()
                        .fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                        .frame(width: 18, height: 18)
                        .overlay {
                            Circle().strokeBorder(Color.white.opacity(selected ? 0.95 : 0.18),
                                                  lineWidth: selected ? 2 : 1)
                        }
                }
                .buttonStyle(.plain)
                .help(palette.rawValue.capitalized)
            }
        }
    }

    // MARK: - Keystrokes

    private var keystrokesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Keystrokes")
            Toggle("Show keystrokes", isOn: binding(\.keystrokes.enabled))
                .toggleStyle(.switch)
                .controlSize(.mini)
            if settings.keystrokes.enabled {
                Picker("Show", selection: binding(\.keystrokes.mode)) {
                    Text("Shortcuts only").tag(RecorderKeystrokeCapture.shortcuts)
                    Text("All keys").tag(RecorderKeystrokeCapture.all)
                }
                .pickerStyle(.segmented)
                .disabled(input.keystrokes.capture == .shortcuts)
                if input.keystrokes.capture == .shortcuts {
                    Text("This recording kept shortcuts only; typed text was never stored.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Position", selection: binding(\.keystrokes.position)) {
                    Text("Bottom").tag(RecorderOverlaySettings.CaptionPosition.bottom)
                    Text("Top").tag(RecorderOverlaySettings.CaptionPosition.top)
                }
                .pickerStyle(.menu)
                Picker("Style", selection: binding(\.keystrokes.style)) {
                    Text("Dark").tag(RecorderOverlaySettings.CaptionStyle.dark)
                    Text("Light").tag(RecorderOverlaySettings.CaptionStyle.light)
                }
                .pickerStyle(.menu)
                slider("Size", value: settings.keystrokes.size, range: RecorderOverlaySettings.Keystrokes.sizeRange,
                       format: "%.2f×") { set(\.keystrokes.size, $0) }
            }
        }
    }

    // MARK: - Camera

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            title("Camera")
            Toggle("Show camera", isOn: binding(\.camera.enabled))
                .toggleStyle(.switch)
                .controlSize(.mini)
            if settings.camera.enabled {
                Picker("Shape", selection: binding(\.camera.shape)) {
                    Text("Circle").tag(RecorderOverlaySettings.BubbleShape.circle)
                    Text("Rounded").tag(RecorderOverlaySettings.BubbleShape.roundedRect)
                }
                .pickerStyle(.segmented)
                cornerPicker
                slider("Size", value: settings.camera.size, range: RecorderOverlaySettings.Camera.sizeRange,
                       format: "%.0f%%", scale: 100) { set(\.camera.size, $0) }
                Toggle("Mirror", isOn: binding(\.camera.mirrored))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Toggle("Border", isOn: binding(\.camera.border))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Toggle("Shadow", isOn: binding(\.camera.shadow))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
        }
    }

    private var cornerPicker: some View {
        HStack {
            Text("Corner")
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.72))
            Spacer()
            Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                GridRow {
                    cornerButton(.topLeft, symbol: "arrow.up.left")
                    cornerButton(.topRight, symbol: "arrow.up.right")
                }
                GridRow {
                    cornerButton(.bottomLeft, symbol: "arrow.down.left")
                    cornerButton(.bottomRight, symbol: "arrow.down.right")
                }
            }
        }
    }

    private func cornerButton(_ corner: RecorderOverlaySettings.Corner, symbol: String) -> some View {
        let selected = settings.camera.corner == corner
        return Button {
            set(\.camera.corner, corner)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 26, height: 20)
                .background(selected ? Color.accentColor.opacity(0.3) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Pieces

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(white: 0.62))
            .textCase(.uppercase)
            .kerning(0.4)
    }

    private func slider(_ title: String, value: Double, range: ClosedRange<Double>, format: String,
                        scale: Double = 1, onChange: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.72))
                Spacer()
                Text(String(format: format, value * scale))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Color(white: 0.86))
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range)
                .controlSize(.small)
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<RecorderOverlaySettings, Value>) -> Binding<Value> {
        Binding(get: { model.document.overlays[keyPath: path] },
                set: { set(path, $0) })
    }

    private func set<Value>(_ path: WritableKeyPath<RecorderOverlaySettings, Value>, _ value: Value) {
        var next = model.document
        next.overlays[keyPath: path] = value
        model.document = next
    }
}

/// What a recording captures for its overlays, in the recorder's Settings.
struct RecorderOverlaySettingsSection: View {
    @ObservedObject private var permissions = Permissions.shared
    @AppStorage(DefaultsKey.recorderShowClicks) private var showsClicks = false
    @AppStorage(DefaultsKey.recorderShowKeystrokes) private var showsKeystrokes = false
    @AppStorage(DefaultsKey.recorderKeystrokeCapture) private var captureRaw = RecorderKeystrokeCapture.shortcuts.rawValue
    @AppStorage(DefaultsKey.recorderCamera) private var camera = false

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show clicks", isOn: $showsClicks)
                Text("Records where each click lands, so the editor can highlight it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show keystrokes", isOn: $showsKeystrokes)
                Text("Records key presses for on-screen captions. Nothing is recorded while a password field has secure input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if showsKeystrokes {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Keys to record", selection: $captureRaw) {
                        Text("Shortcuts only").tag(RecorderKeystrokeCapture.shortcuts.rawValue)
                        Text("All keys").tag(RecorderKeystrokeCapture.all.rawValue)
                    }
                    Text(captureRaw == RecorderKeystrokeCapture.all.rawValue
                         ? "Typed text is kept with the recording. Use shortcuts only when typing anything private."
                         : "Only shortcuts and keys like ⎋ ⇥ ↩ are kept; typed text is never stored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disclosureIndent()
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Camera", isOn: $camera)
                    .onChange(of: camera) { _, enabled in
                        if enabled, permissions.camera == .undetermined { permissions.requestCamera() }
                    }
                Text("Records your camera beside the screen, for a bubble you can place in the editor. A live bubble shows while recording and is left out of the screen capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if camera, permissions.camera == .denied {
                    Button("Allow Camera in System Settings") { permissions.openCameraSettings() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        } header: {
            Text(RecorderOverlaySupport.title)
        }
    }
}

/// The three toggles beside the sound choices while an area is picked.
struct RecorderOverlayCaptureToggles: View {
    @ObservedObject var options: RecorderSelectionAudioOptions

    var body: some View {
        HStack(spacing: 4) {
            toggle($options.showsClicks, symbol: "cursorarrow.click.2", help: "Show clicks")
            toggle($options.showsKeystrokes, symbol: "keyboard", help: "Show keystrokes")
            toggle($options.camera, symbol: "web.camera", help: "Camera")
        }
    }

    private func toggle(_ isOn: Binding<Bool>, symbol: String, help: String) -> some View {
        Toggle(isOn: isOn) {
            Image(systemName: symbol)
                .accessibilityLabel(help)
        }
        .toggleStyle(.button)
        .help(help)
    }
}
