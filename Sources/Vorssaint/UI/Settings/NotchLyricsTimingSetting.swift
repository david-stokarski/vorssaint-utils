// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: the standing lyrics offset, under Music in the island's settings.
struct NotchLyricsTimingSetting: View {
    @AppStorage(DefaultsKey.notchLyricsDefaultOffset) private var offset = 0.0

    var body: some View {
        let bounded = Binding(get: { NotchLyricsTiming.clamped(offset) },
                              set: { offset = NotchLyricsTiming.clamped($0) })
        SettingsRow(symbol: "timer", title: "Lyrics timing",
                    caption: "Shows every line earlier (−) or later (+) than the song's timing. The island's − / + buttons still adjust each song on top of this.") {
            HStack(spacing: 8) {
                Slider(value: bounded, in: NotchLyricsTiming.range, step: NotchLyricsTiming.step) {
                    Text("Lyrics timing")
                } minimumValueLabel: {
                    Text("Earlier").font(.caption2).foregroundStyle(.secondary)
                } maximumValueLabel: {
                    Text("Later").font(.caption2).foregroundStyle(.secondary)
                }
                .labelsHidden()
                .frame(width: 190)
                Button {
                    offset = 0
                } label: {
                    (Text(bounded.wrappedValue, format: .number.sign(strategy: .always(includingZero: false))
                            .precision(.fractionLength(2))) + Text(" s"))
                        .monospacedDigit()
                        .frame(minWidth: 52, alignment: .trailing)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Reset to no offset")
            }
        }
    }
}
