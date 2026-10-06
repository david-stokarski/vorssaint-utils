// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: how the bar opens. The drop out of the island can play faster or
/// slower, or the bar can simply appear.
struct CommandBarAnimationSection: View {
    @AppStorage(DefaultsKey.commandBarAnimates) private var animates = true
    @AppStorage(DefaultsKey.commandBarAnimationSpeed) private var speed = 1.0

    var body: some View {
        Section {
            Toggle("Animate opening and closing", isOn: $animates)
            if animates {
                LabeledContent("Speed") {
                    HStack(spacing: 10) {
                        Slider(value: $speed, in: CommandBarAnimation.speedRange, step: 0.25) {
                            Text("Speed")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise").foregroundStyle(.secondary)
                        } maximumValueLabel: {
                            Image(systemName: "hare").foregroundStyle(.secondary)
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        Text(Self.label(speed))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                        Button("Reset") { speed = 1 }
                            .controlSize(.small)
                            .disabled(speed == 1)
                    }
                }
            }
        } header: {
            Text("Opening Animation")
        } footer: {
            Text(animates
                 ? "How fast the bar drops out of the Dynamic Island and folds back into it. 2× plays it in half the time."
                 : "The bar appears and disappears at once, with no drop from the island.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    static func label(_ speed: Double) -> String {
        let rounded = (speed * 100).rounded() / 100
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        return text + "×"
    }
}
