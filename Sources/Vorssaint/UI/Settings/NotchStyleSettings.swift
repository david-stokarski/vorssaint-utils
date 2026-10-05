// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: chooses between the tabbed and classic island, and what Home shows.
struct NotchStyleSettingsCard: View {
    @AppStorage(DefaultsKey.notchStyle) private var style = NotchStyle.tabbed.rawValue
    @AppStorage(DefaultsKey.notchHomeWidgets) private var widgets = NotchHomeWidget.defaultValue
    @ObservedObject private var notch = NotchService.shared

    private var tabbed: Bool { (NotchStyle(rawValue: style) ?? .tabbed) == .tabbed }
    private var chosen: [NotchHomeWidget] { NotchHomeWidget.decode(widgets) }

    var body: some View {
        SettingsCard(title: "Island Style") {
            Picker("Style", selection: $style) {
                Text("Tabs").tag(NotchStyle.tabbed.rawValue)
                Text("Classic").tag(NotchStyle.classic.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(tabbed
                 ? "Home and the buttons below appear as tabs inside the island. Everything else stays in All Sections, in the island's menu."
                 : "The island's title, section gallery and floating buttons.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if tabbed {
                Divider()
                Text("Home").font(.subheadline.weight(.semibold))
                VStack(spacing: 6) {
                    ForEach(chosen) { widget in row(widget, included: true) }
                    ForEach(NotchHomeWidget.allCases.filter { !chosen.contains($0) }) { widget in
                        row(widget, included: false)
                    }
                }
                Text("Up to \(NotchHomeWidget.maximum) widgets, side by side. A widget shows only while its section is part of the island.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: style) { _, _ in NotchService.shared.syncWithPreferences() }
        .onChange(of: widgets) { _, _ in NotchService.shared.syncWithPreferences() }
    }

    private func row(_ widget: NotchHomeWidget, included: Bool) -> some View {
        let index = chosen.firstIndex(of: widget)
        let available = notch.modules.contains(widget.module) || NotchSupport.modules().contains(widget.module)
        return HStack(spacing: 10) {
            Image(systemName: widget.symbol)
                .frame(width: 20)
                .foregroundStyle(.secondary)
            Text(widget.title)
            if !available {
                Text("Section off").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let index {
                Button { move(widget, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .accessibilityLabel("Move \(widget.title) left")
                Button { move(widget, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                    .disabled(index == chosen.count - 1)
                    .accessibilityLabel("Move \(widget.title) right")
            }
            Toggle(widget.title, isOn: Binding(get: { included }, set: { set(widget, included: $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!included && chosen.count >= NotchHomeWidget.maximum)
        }
    }

    private func set(_ widget: NotchHomeWidget, included: Bool) {
        var next = chosen.filter { $0 != widget }
        if included { next.append(widget) }
        widgets = NotchHomeWidget.encode(next)
    }

    private func move(_ widget: NotchHomeWidget, by offset: Int) {
        var next = chosen
        guard let index = next.firstIndex(of: widget) else { return }
        let target = index + offset
        guard next.indices.contains(target) else { return }
        next.swapAt(index, target)
        widgets = NotchHomeWidget.encode(next)
    }
}

/// Fork: how the island opens and closes. A preset fills every slider;
/// moving a slider makes the motion custom.
struct NotchAnimationSettingsCard: View {
    @AppStorage(DefaultsKey.notchAnimationPreset) private var preset = NotchAnimationTuning.Preset.liquid.rawValue
    @AppStorage(DefaultsKey.notchAnimationOpenDuration) private var openDuration = 0.52
    @AppStorage(DefaultsKey.notchAnimationOpenBounce) private var openBounce = 0.3
    @AppStorage(DefaultsKey.notchAnimationCloseDuration) private var closeDuration = 0.38
    @AppStorage(DefaultsKey.notchAnimationCloseBounce) private var closeBounce = 0.1
    @AppStorage(DefaultsKey.notchAnimationStretch) private var stretch = 0.05
    @AppStorage(DefaultsKey.notchAnimationContentBlur) private var contentBlur = 14.0
    @AppStorage(DefaultsKey.notchAnimationContentScale) private var contentScale = 0.84
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewing = false

    private typealias Tuning = NotchAnimationTuning

    var body: some View {
        SettingsCard(title: "Animation") {
            Picker("Style", selection: Binding(get: { preset }, set: choose)) {
                ForEach(Tuning.Preset.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                slider("Opening", value: $openDuration, range: Tuning.durationRange, step: 0.02) { seconds($0) }
                slider("Opening bounce", value: $openBounce, range: Tuning.bounceRange, step: 0.02) { percent($0 * 2) }
                slider("Closing", value: $closeDuration, range: Tuning.durationRange, step: 0.02) { seconds($0) }
                slider("Closing squish", value: $closeBounce, range: Tuning.closeBounceRange, step: 0.02) { percent($0 / 0.3) }
                slider("Liquid stretch", value: $stretch, range: Tuning.stretchRange, step: 0.005) { "\(Int(($0 * 1000).rounded())) ms" }
                slider("Content blur", value: $contentBlur, range: Tuning.blurRange, step: 1) { "\(Int($0.rounded())) pt" }
                slider("Content zoom", value: $contentScale, range: Tuning.scaleRange, step: 0.01) { percent($0) }
            }
            HStack {
                Text(reduceMotion
                     ? "Reduce Motion is on in System Settings, so the island moves without these springs."
                     : "Liquid stretch lets the width lead as the island opens and the height lead as it closes, so it pours open and draws back like a drop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(previewing ? "Previewing…" : "Preview", action: preview)
                    .disabled(previewing || !NotchSupport.isEnabled())
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        label: @escaping (Double) -> String) -> some View {
        let edited = Binding(get: { value.wrappedValue }, set: { next in
            value.wrappedValue = next
            if preset != Tuning.Preset.custom.rawValue { preset = Tuning.Preset.custom.rawValue }
            Tuning.reload()
        })
        return GridRow {
            Text(title).fixedSize().accessibilityHidden(true)
            Slider(value: edited, in: range, step: step) { Text(title) }.labelsHidden()
            Text(label(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }

    private func choose(_ raw: String) {
        preset = raw
        if let tuning = Tuning.Preset(rawValue: raw)?.tuning {
            openDuration = tuning.openDuration
            openBounce = tuning.openBounce
            closeDuration = tuning.closeDuration
            closeBounce = tuning.closeBounce
            stretch = tuning.stretch
            contentBlur = tuning.contentBlur
            contentScale = tuning.contentScale
        }
        Tuning.reload()
    }

    /// Opens the island and closes it again, so a change can be felt.
    private func preview() {
        Tuning.reload()
        previewing = true
        NotchService.shared.open(pinned: true, takeFocus: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1.1, openDuration + 0.8)) {
            NotchService.shared.collapse()
            DispatchQueue.main.asyncAfter(deadline: .now() + closeDuration + 0.3) { previewing = false }
        }
    }

    private func seconds(_ value: Double) -> String { "\(value.formatted(.number.precision(.fractionLength(2)))) s" }
    private func percent(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0))) }
}

/// Fork: what the island does once the pointer leaves it. The opening delay
/// sits with the opening choices above.
struct NotchHoverTimingCard: View {
    @AppStorage(DefaultsKey.notchHoverCloseDelay) private var closeDelay = NotchHoverTuning.defaultCloseDelay
    @AppStorage(DefaultsKey.notchHoverMinimumOpen) private var minimumOpen = 0.0

    var body: some View {
        SettingsCard(title: "Hover Timing") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row("Close after leaving", value: $closeDelay, range: NotchHoverTuning.closeDelayRange, step: 0.05)
                row("Stay open at least", value: $minimumOpen, range: NotchHoverTuning.minimumOpenRange, step: 0.1)
            }
            Text("Once the pointer leaves, the island waits this long before closing. \"Stay open at least\" keeps a hover-opened island up for a moment even if the pointer only brushed past; 0 turns it off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        GridRow {
            Text(title).fixedSize().accessibilityHidden(true)
            Slider(value: value, in: range, step: step) { Text(title) }.labelsHidden()
            Text(value.wrappedValue == 0 ? "Off" : "\(value.wrappedValue.formatted(.number.precision(.fractionLength(2)))) s")
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
        }
    }
}

/// Fork: the closed island's size on a display with a camera.
struct NotchClosedSizeCard: View {
    @AppStorage(DefaultsKey.notchClosedExtraWidth) private var extraWidth = 0.0
    @AppStorage(DefaultsKey.notchClosedExtraHeight) private var extraHeight = 0.0

    var body: some View {
        SettingsCard(title: "Closed Size") {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row("Extra width", value: $extraWidth, range: NotchClosedSize.widthRange, step: 2)
                row("Extra height", value: $extraHeight, range: NotchClosedSize.heightRange, step: 1)
            }
            Text(NotchSupport.hasNotchedDisplay
                 ? "How far the closed island reaches past the camera, when nothing is showing beside it. The floating capsule on a display without a camera has its own size under Capsule Fit."
                 : "Applies on a display with a camera. The floating capsule's size is under Capsule Fit.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: extraWidth) { _, _ in apply() }
        .onChange(of: extraHeight) { _, _ in apply() }
    }

    private func apply() {
        NotchClosedSize.reload()
        NotchService.shared.syncWithPreferences()
        NotchService.shared.refreshPresentation()
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double) -> some View {
        GridRow {
            Text(title).fixedSize().accessibilityHidden(true)
            Slider(value: value, in: range, step: step) { Text(title) }.labelsHidden()
            Text("\(Int(value.wrappedValue.rounded())) pt").monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
