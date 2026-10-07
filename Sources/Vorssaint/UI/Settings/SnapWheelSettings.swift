// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: Settings › Snap Wheel. The trigger, what each direction does, how
/// the ring and the preview look, and a live ring to try it all on: point
/// at the preview to see a direction picked and click to step its list.
struct SnapWheelSettings: View {
    @ObservedObject private var service = SnapWheelService.shared
    @ObservedObject private var permissions = Permissions.shared
    @ObservedObject private var l10n = L10n.shared
    @AppStorage(DefaultsKey.snapWheelEnabled) private var enabled = true
    @AppStorage(DefaultsKey.snapWheelTrigger) private var triggerRaw = SnapWheelTrigger.default.keys.storageValue
    @AppStorage(DefaultsKey.snapWheelTriggerEitherSide) private var eitherSide = false
    @AppStorage(DefaultsKey.snapWheelSlots) private var slotsRaw = ""
    @AppStorage(DefaultsKey.snapWheelPlacement) private var placement = SnapWheelPlacement.pointer.rawValue
    @AppStorage(DefaultsKey.snapWheelShowsWheel) private var showsWheel = true
    @AppStorage(DefaultsKey.snapWheelSize) private var size = 100.0
    @AppStorage(DefaultsKey.snapWheelThickness) private var thickness = 22.0
    @AppStorage(DefaultsKey.snapWheelCornerRadius) private var cornerRadius = 50.0
    @AppStorage(DefaultsKey.snapWheelMaterial) private var material = SnapWheelMaterial.glass.rawValue
    @AppStorage(DefaultsKey.snapWheelColorMode) private var colorMode = SnapWheelColorMode.system.rawValue
    @AppStorage(DefaultsKey.snapWheelColor) private var color = "#0A84FF"
    @AppStorage(DefaultsKey.snapWheelGradientColor) private var gradientColor = "#64D2FF"
    @AppStorage(DefaultsKey.snapWheelPreviewEnabled) private var previewEnabled = true
    @AppStorage(DefaultsKey.snapWheelPreviewMaterial) private var previewMaterial = SnapWheelPreviewMaterial.frosted.rawValue
    @AppStorage(DefaultsKey.snapWheelPreviewPadding) private var previewPadding = 0.0
    @AppStorage(DefaultsKey.snapWheelPreviewCornerRadius) private var previewCornerRadius = 16.0
    @AppStorage(DefaultsKey.snapWheelPreviewBorder) private var previewBorder = 2.0
    @AppStorage(DefaultsKey.snapWheelPreviewTint) private var previewTint = 0.2
    @AppStorage(DefaultsKey.snapWheelPreviewStart) private var previewStart = SnapWheelPreviewStart.screenCenter.rawValue
    @AppStorage(DefaultsKey.snapWheelAnimation) private var animation = SnapWheelAnimation.fluid.rawValue
    @AppStorage(DefaultsKey.snapWheelHaptics) private var haptics = true
    @AppStorage(DefaultsKey.snapWheelTarget) private var target = SnapWheelTargetChoice.focused.rawValue
    @AppStorage(DefaultsKey.snapWheelScreen) private var screen = SnapWheelScreenChoice.pointer.rawValue
    @AppStorage(DefaultsKey.snapWheelSensitivity) private var sensitivity = 0.7
    @AppStorage(DefaultsKey.snapWheelRecenter) private var recenter = true
    @AppStorage(DefaultsKey.snapWheelRestDelay) private var restDelay = 0.3
    @AppStorage(DefaultsKey.snapWheelCircle) private var circles = true
    @AppStorage(DefaultsKey.windowLayoutWindowGap) private var windowGap = 0
    @AppStorage(DefaultsKey.windowLayoutScreenGap) private var screenGap = 0
    @State private var triggerMessage: String?
    @State private var importMessage: String?

    private var trigger: SnapWheelTrigger {
        _ = triggerRaw
        _ = eitherSide
        return SnapWheelTrigger.current()
    }

    private var slots: [SnapWheelSlot: [String]] {
        SnapWheelSlots.decode(slotsRaw.isEmpty ? nil : slotsRaw)
    }

    /// Everything the ring and the preview read, rebuilt on any change.
    private var appearance: SnapWheelAppearance {
        _ = (placement, showsWheel, size, thickness, cornerRadius, material, colorMode, color, gradientColor)
        _ = (previewEnabled, previewMaterial, previewPadding, previewCornerRadius, previewBorder, previewTint)
        _ = (previewStart, animation, haptics)
        return SnapWheelAppearance.current()
    }

    var body: some View {
        Form {
            Section {
                Toggle(SnapWheelSupport.title, isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                Text("Hold \(trigger.keys.displayName(eitherSide: trigger.eitherSide)) and move the pointer: a ring appears and a preview shows where the window will go. Let go to snap it there. Holding the key without moving does nothing, so its shortcuts and clicks work as before.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !permissions.accessibility { PermissionRow(kind: .accessibility) }
                if service.waitsForLoop {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Loop is running, so the Snap Wheel is waiting. Both would snap the same window.",
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Import from Loop and Quit It") { importLoop(quit: true) }
                        Text("Brings over Loop's trigger, directions, colors, ring and preview, then quits Loop. Turn off Loop's Launch at Login, or remove it, so it stays out of the way.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if service.tapFailed {
                    Label("macOS didn't let the Snap Wheel watch the keyboard. Check Accessibility for Vorssaint.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let importMessage {
                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(SnapWheelSupport.title)
            }

            Section {
                SnapWheelLivePreview(appearance: appearance,
                                     feel: SnapWheelFeel(sensitivity: sensitivity, recenters: recenter,
                                                         restDelay: restDelay),
                                     slots: slots,
                                     windowGap: CGFloat(windowGap), screenGap: CGFloat(screenGap))
                    .frame(maxWidth: .infinity)
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 12, trailing: 0))
            } footer: {
                Text("Point at the preview to try a direction. Click to step through its list.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Trigger") {
                HStack {
                    Text("Hold")
                    Spacer()
                    Button {
                        triggerMessage = nil
                        if service.isRecordingTrigger { service.cancelRecording(); return }
                        service.recordTrigger { keys in
                            guard keys.isUsableTrigger else {
                                triggerMessage = "Shift on its own can't start the wheel. Pair it with Control, Option, Command or fn."
                                return
                            }
                            triggerRaw = keys.storageValue
                            service.syncWithPreferences()
                        }
                    } label: {
                        Text(recorderTitle)
                            .frame(minWidth: 150)
                    }
                    .onDisappear { service.cancelRecording() }
                }
                Toggle("Either side", isOn: $eitherSide)
                    .onChange(of: eitherSide) { _, _ in service.syncWithPreferences() }
                Text(service.isRecordingTrigger
                     ? "Press the modifier keys you want, then let go. Esc cancels."
                     : "With Either side off, only the key on the side you recorded starts the wheel; the other stays free for shortcuts.")
                    .font(.caption).foregroundStyle(.secondary)
                if let triggerMessage {
                    Text(triggerMessage).font(.caption).foregroundStyle(.orange)
                }
            }

            Section {
                LabeledContent("Sensitivity") {
                    HStack(spacing: 8) {
                        Text("Relaxed").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $sensitivity, in: 0...1)
                        Text("Twitchy").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 300)
                }
                Toggle("Start over where the pointer rests", isOn: $recenter)
                if recenter {
                    slider("Rest for", value: $restDelay, range: SnapWheelFeel.restDelayRange, step: 0.05,
                           format: { String(format: "%.2f s", locale: .current, $0) })
                }
                Toggle("Draw a circle to pick the center", isOn: $circles)
            } header: {
                Text("Feel")
            } footer: {
                Text((recenter
                      ? "Twitchy needs only a small flick to pick a direction. Pause for a moment while holding and the ring moves to the pointer, so the next flick picks from there."
                      : "Twitchy needs only a small flick to pick a direction.")
                     + (circles ? " A big circle drawn while holding picks \(centerTitle) and holds it; pause, then flick to choose something else." : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Ring") {
                Toggle("Show the ring", isOn: $showsWheel)
                Picker("Position", selection: $placement) {
                    Text("Where the pointer is").tag(SnapWheelPlacement.pointer.rawValue)
                    Text("Center of the screen").tag(SnapWheelPlacement.screenCenter.rawValue)
                }
                Picker("Material", selection: $material) {
                    Text("Liquid Glass").tag(SnapWheelMaterial.glass.rawValue)
                    Text("Frosted").tag(SnapWheelMaterial.frosted.rawValue)
                    Text("Solid").tag(SnapWheelMaterial.solid.rawValue)
                }
                Picker("Color", selection: $colorMode) {
                    Text("Accent color").tag(SnapWheelColorMode.system.rawValue)
                    Text("Custom").tag(SnapWheelColorMode.custom.rawValue)
                    Text("Gradient").tag(SnapWheelColorMode.gradient.rawValue)
                }
                if colorMode != SnapWheelColorMode.system.rawValue {
                    ColorPicker(colorMode == SnapWheelColorMode.gradient.rawValue ? "From" : "Highlight",
                                selection: colorBinding($color), supportsOpacity: false)
                    if colorMode == SnapWheelColorMode.gradient.rawValue {
                        ColorPicker("To", selection: colorBinding($gradientColor), supportsOpacity: false)
                    }
                }
                slider("Size", value: $size, range: SnapWheelAppearance.sizeRange, unit: "pt")
                slider("Thickness", value: $thickness, range: SnapWheelAppearance.thicknessRange, unit: "pt")
                slider("Roundness", value: $cornerRadius, range: SnapWheelAppearance.cornerRadiusRange,
                       format: { "\(Int(($0 / 50 * 100).rounded()))%" })
            }

            Section("Preview") {
                Toggle("Show where the window will go", isOn: $previewEnabled)
                Group {
                    Picker("Material", selection: $previewMaterial) {
                        Text("Frosted").tag(SnapWheelPreviewMaterial.frosted.rawValue)
                        Text("Liquid Glass").tag(SnapWheelPreviewMaterial.glass.rawValue)
                        Text("Color only").tag(SnapWheelPreviewMaterial.tint.rawValue)
                    }
                    Picker("Grows from", selection: $previewStart) {
                        Text("Center of the screen").tag(SnapWheelPreviewStart.screenCenter.rawValue)
                        Text("The ring").tag(SnapWheelPreviewStart.wheel.rawValue)
                        Text("The window").tag(SnapWheelPreviewStart.window.rawValue)
                        Text("Its own place").tag(SnapWheelPreviewStart.target.rawValue)
                    }
                    slider("Tint", value: $previewTint, range: 0...1, format: { "\(Int(($0 * 100).rounded()))%" })
                    slider("Border", value: $previewBorder, range: SnapWheelAppearance.previewBorderRange, unit: "pt",
                           step: 0.5)
                    slider("Corner radius", value: $previewCornerRadius,
                           range: SnapWheelAppearance.previewCornerRadiusRange, unit: "pt")
                    slider("Padding", value: $previewPadding, range: SnapWheelAppearance.previewPaddingRange, unit: "pt")
                }
                .disabled(!previewEnabled)
            }

            Section {
                Picker("Window", selection: $target) {
                    Text("The focused window").tag(SnapWheelTargetChoice.focused.rawValue)
                    Text("The window under the pointer").tag(SnapWheelTargetChoice.underPointer.rawValue)
                }
                Picker("Screen", selection: $screen) {
                    Text("The one with the pointer").tag(SnapWheelScreenChoice.pointer.rawValue)
                    Text("The window's own").tag(SnapWheelScreenChoice.window.rawValue)
                }
                Picker("Animation", selection: $animation) {
                    Text("Fluid").tag(SnapWheelAnimation.fluid.rawValue)
                    Text("Snappy").tag(SnapWheelAnimation.snappy.rawValue)
                    Text("Instant").tag(SnapWheelAnimation.instant.rawValue)
                }
                Toggle("Haptic feedback on the trackpad", isOn: $haptics)
                gapPicker("Gap between windows", selection: $windowGap)
                gapPicker("Gap at the screen edges", selection: $screenGap)
                Text("Gaps are shared with Window Layout's shortcuts. Apps listed under Window Layout › Ignore apps are left alone. Right-click or Esc cancels a hold.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Behavior")
            }

            Section {
                ForEach(SnapWheelSlot.allCases) { slot in
                    SnapWheelSlotRow(slot: slot, actions: slots[slot] ?? [], language: l10n.language) { updated in
                        var all = slots
                        all[slot] = updated
                        slotsRaw = SnapWheelSlots.encode(all)
                    }
                }
                Button("Restore Default Directions") { slotsRaw = SnapWheelSlots.encode(SnapWheelSlots.defaults) }
            } header: {
                Text("Directions")
            } footer: {
                Text("Each direction can hold several placements. The first is picked when you point there, or the one after the window's current placement, so holding Left again goes from a half to a third. Click while holding to step through the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if SnapWheelService.hasLoopPreferences, !service.waitsForLoop {
                Section {
                    Button("Import Settings from Loop") { importLoop(quit: false) }
                    Text("Copies Loop's trigger, directions, colors, ring, preview and gaps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var centerTitle: String {
        let actions = slots[.center] ?? []
        guard !actions.isEmpty else { return "nothing set" }
        return SnapWheelActionCatalog.title(actions[0], language: l10n.language)
    }

    private var recorderTitle: String {
        if service.isRecordingTrigger {
            let held = service.recordedKeys
            return held.isEmpty ? "Press keys…" : held.displayName(eitherSide: false)
        }
        return trigger.keys.displayName(eitherSide: trigger.eitherSide)
    }

    private func importLoop(quit: Bool) {
        if service.importFromLoop(quit: quit) {
            importMessage = quit ? "Imported Loop's settings and asked Loop to quit." : "Imported Loop's settings."
        } else {
            importMessage = "Loop's settings couldn't be read."
        }
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(hexString: hex.wrappedValue) ?? .accentColor },
                set: { if let value = $0.hexString { hex.wrappedValue = value } })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String = "",
                        step: Double = 1, format: ((Double) -> String)? = nil) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: value, in: range, step: step)
                Text(format?(value.wrappedValue) ?? "\(value.wrappedValue.formatted(.number.precision(.fractionLength(step < 1 ? 1 : 0)))) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .frame(maxWidth: 260)
        }
    }

    private func gapPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(WindowLayoutGaps.presets, id: \.self) { value in
                Text(value == 0 ? "None" : "\(value) px").tag(value)
            }
        }
    }
}

// MARK: - Directions

private struct SnapWheelSlotRow: View {
    let slot: SnapWheelSlot
    let actions: [String]
    let language: AppLanguage
    let update: ([String]) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: slot.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            Text(slot.title)
                .frame(width: 84, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if actions.isEmpty {
                        Text("Nothing").foregroundStyle(.tertiary)
                    }
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        chip(action, index: index)
                    }
                }
            }
            Menu {
                ForEach(SnapWheelActionCatalog.groups, id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.actions, id: \.self) { action in
                            Button {
                                update(actions + [action])
                            } label: {
                                Label(SnapWheelActionCatalog.title(action, language: language),
                                      systemImage: SnapWheelActionCatalog.symbol(action))
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Add a placement")
        }
    }

    private func chip(_ action: String, index: Int) -> some View {
        Menu {
            Button("Move Earlier") { move(index, by: -1) }.disabled(index == 0)
            Button("Move Later") { move(index, by: 1) }.disabled(index == actions.count - 1)
            Divider()
            Button("Remove", role: .destructive) {
                var updated = actions
                updated.remove(at: index)
                update(updated)
            }
        } label: {
            Label(SnapWheelActionCatalog.title(action, language: language),
                  systemImage: SnapWheelActionCatalog.symbol(action))
                .font(.callout)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(index == 0 ? 0.12 : 0.06)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func move(_ index: Int, by offset: Int) {
        var updated = actions
        let destination = index + offset
        guard updated.indices.contains(destination) else { return }
        updated.swapAt(index, destination)
        update(updated)
    }
}

enum SnapWheelActionCatalog {
    static let groups: [(title: String, actions: [String])] = [
        ("Halves", ["leftHalf", "rightHalf", "topHalf", "bottomHalf", "centerHalf"]),
        ("Thirds", ["leftThird", "centerThird", "rightThird", "leftTwoThirds", "centerTwoThirds", "rightTwoThirds",
                    "topThird", "middleThird", "bottomThird", "topTwoThirds", "bottomTwoThirds"]),
        ("Corners and quarters", ["topLeft", "topRight", "bottomLeft", "bottomRight",
                                  "leftQuarter", "leftMiddleQuarter", "rightMiddleQuarter", "rightQuarter",
                                  "topQuarter", "upperMiddleQuarter", "lowerMiddleQuarter", "bottomQuarter"]),
        ("Sixths", ["topLeftSixth", "topCenterSixth", "topRightSixth",
                    "bottomLeftSixth", "bottomCenterSixth", "bottomRightSixth"]),
        ("Whole screen", ["maximize", "marginMaximize", "fullScreen", "center"]),
        ("Other", ["previousDisplay", "nextDisplay", "restore", SnapWheelActionID.minimize, SnapWheelActionID.hide]),
    ]

    static func title(_ action: String, language: AppLanguage) -> String {
        switch action {
        case SnapWheelActionID.minimize: return "Minimize"
        case SnapWheelActionID.hide: return "Hide App"
        default:
            return WindowLayoutAction(rawValue: action)?.title(FeatureStrings.windowLayout(language)) ?? action
        }
    }

    static func symbol(_ action: String) -> String {
        switch action {
        case SnapWheelActionID.minimize: return "minus.rectangle"
        case SnapWheelActionID.hide: return "eye.slash"
        default: return WindowLayoutAction(rawValue: action)?.symbolName ?? "questionmark"
        }
    }
}

// MARK: - Live preview

/// A small desktop with the ring in the middle. Pointing at it picks a
/// direction the way the real hold does, measured from the ring's center.
private struct SnapWheelLivePreview: View {
    let appearance: SnapWheelAppearance
    let feel: SnapWheelFeel
    let slots: [SnapWheelSlot: [String]]
    let windowGap: CGFloat
    let screenGap: CGFloat
    @StateObject private var model = SnapWheelOverlayModel()
    @State private var cycle = SnapWheelCycle()
    @State private var previewRect: CGRect?

    private static let screenSize = CGSize(width: 420, height: 250)
    /// The mini screen stands for one 1440 points wide.
    private static let scale: CGFloat = 420 / 1440

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        ZStack {
            LinearGradient(colors: [Color(red: 0.16, green: 0.22, blue: 0.42), Color(red: 0.42, green: 0.25, blue: 0.48),
                                    Color(red: 0.86, green: 0.52, blue: 0.42)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // A stand-in window, where it sits before the hold.
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.85))
                .overlay(alignment: .top) {
                    HStack(spacing: 4) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0).frame(width: 6, height: 6) }
                        Spacer()
                    }
                    .padding(6)
                }
                .frame(width: 170, height: 110)
                .offset(x: -80, y: 20)
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            if appearance.previewEnabled, let previewRect {
                SnapWheelPreviewView(appearance: scaledPreview, size: previewRect.size)
                    .frame(width: previewRect.width, height: previewRect.height)
                    .position(x: previewRect.midX, y: previewRect.midY)
                    .transition(.opacity)
            }
            if appearance.showsWheel {
                SnapWheelRingView(model: model)
            }
        }
        .environment(\.snapWheelBlurWithinWindow, true)
        .frame(width: Self.screenSize.width, height: Self.screenSize.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .contentShape(shape)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): pointed(at: point)
            case .ended: pointed(at: nil)
            }
        }
        .onTapGesture { advance() }
        .onAppear { model.appearance = appearance }
        .onChange(of: appearance) { _, value in model.appearance = value; refresh() }
    }

    /// The preview drawn at the mini screen's scale.
    private var scaledPreview: SnapWheelAppearance {
        var value = appearance
        value.previewBorder = max(1, appearance.previewBorder * 0.6)
        value.previewCornerRadius = appearance.previewCornerRadius * 0.5
        return value
    }


    private func pointed(at point: CGPoint?) {
        let center = CGPoint(x: Self.screenSize.width / 2, y: Self.screenSize.height / 2)
        let slot = point.flatMap { point in
            // Flip to y up, as the real hold measures.
            SnapWheelGeometry.slot(from: .zero, to: CGPoint(x: point.x - center.x, y: center.y - point.y),
                                   directionalDistance: feel.directionalDistance(
                                       size: appearance.size, thickness: appearance.ringThickness),
                                   showDistance: feel.showDistance)
        }
        guard slot != model.slot else { return }
        if point == nil { cycle = SnapWheelCycle() }
        let actions = slot.map { slots[$0] ?? [] } ?? []
        let action = slot.flatMap { cycle.enter($0, actions: actions, windowPlacement: nil) }
        show(slot: slot, action: action, actions: actions)
    }

    private func advance() {
        guard let slot = model.slot else { return }
        let actions = slots[slot] ?? []
        guard actions.count > 1 else { return }
        show(slot: slot, action: cycle.advance(slot, actions: actions), actions: actions)
    }

    private func refresh() {
        guard let slot = model.slot else { return }
        let actions = slots[slot] ?? []
        show(slot: slot, action: model.actionID, actions: actions)
    }

    private func show(slot: SnapWheelSlot?, action: String?, actions: [String]) {
        if model.slot?.angle == nil, let mathAngle = slot?.angle {
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { model.angle = -mathAngle }
        }
        withAnimation(appearance.animation.ring) {
            model.select(slot)
            model.actionID = action
            model.cycle = slot.flatMap { cycle.position(in: $0) }.map { ($0, actions.count) }
        }
        withAnimation(appearance.animation.preview) { previewRect = action.flatMap(rect(for:)) }
    }

    /// Where `action` would land on the mini screen, in its own coordinates.
    private func rect(for action: String) -> CGRect? {
        guard let layout = WindowLayoutAction(rawValue: action) else { return nil }
        let menuBar: CGFloat = 24 / Self.scale
        let full = CGRect(x: 0, y: 0, width: 1440, height: Self.screenSize.height / Self.scale)
        let visible = CGRect(x: 0, y: 0, width: full.width, height: full.height - menuBar)
        let current = CGRect(x: 160, y: 300, width: 580, height: 380)
        let placed: CGRect
        switch layout {
        case .fullScreen: placed = full
        case .previousDisplay, .nextDisplay, .restore: return nil
        default:
            placed = WindowLayoutGeometry.rect(for: layout, current: current, visibleFrame: visible,
                                               windowGap: windowGap, screenGap: screenGap,
                                               marginPercent: WindowLayoutMargin.percent)
        }
        let inset = SnapWheelGeometry.inset(placed, by: appearance.previewPadding)
        return CGRect(x: inset.minX * Self.scale, y: (full.height - inset.maxY) * Self.scale,
                      width: inset.width * Self.scale, height: inset.height * Self.scale)
    }
}
