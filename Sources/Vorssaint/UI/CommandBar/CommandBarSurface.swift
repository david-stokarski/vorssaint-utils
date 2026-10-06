// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: the Command Bar drawn in the material chosen for it, the same
/// Black, Frosted and Glass the island and dictation offer, with a tint of
/// black over the see-through ones.
struct CommandBarSurface: View {
    let appearance: NotchSurfaceAppearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        ZStack {
            if reduceTransparency || appearance.material == .black {
                shape.fill(Color.black)
            } else {
                material
                shape.fill(Color.black.opacity(appearance.tint))
            }
        }
        .environment(\.colorScheme, .dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder private var material: some View {
        if appearance.material == .glass {
#if compiler(>=6.2)
            if #available(macOS 26, *) {
                Color.clear
                    .glassEffect(.clear, in: shape)
                    .environment(\.appearsActive, true)
            } else {
                CommandBarFrost()
            }
#else
            CommandBarFrost()
#endif
        } else {
            CommandBarFrost()
        }
    }
}

/// The system's dark behind-window blur, rounded like the bar.
private struct CommandBarFrost: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.wantsLayer = true
        view.layer?.cornerRadius = 22
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Fork: the Command Bar page's choice of material.
struct CommandBarAppearanceSection: View {
    @AppStorage(DefaultsKey.commandBarMaterial) private var material = NotchSurfaceMaterial.classic.rawValue
    @AppStorage(DefaultsKey.commandBarTint) private var tint = NotchSurfaceAppearance.defaultCommandBarTint

    var body: some View {
        Section {
            Picker("Material", selection: $material) {
                ForEach(NotchSurfaceMaterial.commandBarChoices) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if NotchSurfaceMaterial(rawValue: material)?.seeThrough == true {
                LabeledContent("Tint") {
                    HStack(spacing: 10) {
                        Slider(value: $tint, in: NotchSurfaceAppearance.tintRange) { Text("Tint") }
                            .labelsHidden()
                            .frame(width: 200)
                        Text(tint.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Classic is the bar's own look. Glass is Liquid Glass, as the island and dictation can use; Frosted blurs what's behind it. Tint darkens a see-through bar so its text stays readable.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
