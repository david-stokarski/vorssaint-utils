// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: a finished run flashes what it cost, whatever else the island is
// showing. The cost leads the notice, and a notice that cannot show yet,
// because a louder one is up or the island is open, waits its turn instead
// of passing unseen.

extension DefaultsKey {
    static let notchAgentsFinishCost = "notchAgentsFinishCost"
}

enum NotchAgentCostFlash {
    static let registeredDefaults: [String: Any] = [DefaultsKey.notchAgentsFinishCost: false]

    /// How long a waiting flash stays worth showing.
    static let patience: TimeInterval = 60

    static func isOn(in defaults: UserDefaults = .standard) -> Bool {
        NotchAgentSupport.isEnabled(in: defaults) && defaults.bool(forKey: DefaultsKey.notchAgentsFinishCost)
    }

    /// The finished notice's detail: the run's length and its cost, the cost
    /// first when it flashes. An unpriced run has no cost to show.
    static func detail(duration: String, cost: Double, flashes: Bool) -> String {
        let price = cost.isFinite && cost > 0 ? AgentFormat.cost(cost) : ""
        return (flashes ? [price, duration] : [duration, price]).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
