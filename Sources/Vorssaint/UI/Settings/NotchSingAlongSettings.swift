// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: the closed island sings the song's lines, under Music's lyrics.
struct NotchCompactLyricsSetting: View {
    @AppStorage(DefaultsKey.notchCompactLyrics) private var on = false

    var body: some View {
        SettingsRow(symbol: "music.mic", title: "Lyrics in the closed island",
                    caption: "After a new song's title and artist show, the closed island shows the line being sung, also beside working agents. Songs without synced lyrics keep the usual cover and bars.") {
            Toggle("Lyrics in the closed island", isOn: $on).labelsHidden().toggleStyle(.switch)
        }
    }
}

/// Fork: a finished run flashes its cost, under the agents' finish alert.
struct NotchAgentCostFlashSetting: View {
    @AppStorage(DefaultsKey.notchAgentsFinishCost) private var on = false

    var body: some View {
        SettingsRow(symbol: "dollarsign.circle", title: "Flash the run's cost",
                    caption: "Leads the finished notice with the run's estimated cost, even while music plays or other agents work. If another notice is up or the island is open, it shows as soon as it can.") {
            Toggle("Flash the run's cost", isOn: $on).labelsHidden().toggleStyle(.switch)
        }
    }
}
