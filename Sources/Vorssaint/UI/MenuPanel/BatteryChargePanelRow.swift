// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// Fork: the Charge Limit's line in the menu panel's Power card: what the
/// daemon is doing ("Limited at 80%", "Paused: hot"...) and a switch. It is
/// absent unless the feature is installed on a Mac with a battery.
struct BatteryChargePanelRow: View {
    @ObservedObject private var service = BatteryChargeService.shared
    @ObservedObject private var features = FeatureRuntime.shared
    @AppStorage(DefaultsKey.batteryChargeEnabled) private var enabled = false

    var body: some View {
        if AppFeature.batteryCharge.isAvailable, PowerSampler.hasInternalBattery {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "battery.75percent")
                        .font(.system(size: 11))
                        .foregroundStyle(enabled && service.helperState == .running ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(BatteryChargeSupport.title)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.primary.opacity(0.74))
                        Text(enabled ? service.stateLabel : "Off")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Toggle(BatteryChargeSupport.title, isOn: $enabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .onChange(of: enabled) { _, isOn in
                            service.syncWithPreferences()
                            if isOn, service.helperState == .notInstalled { openSettings() }
                        }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { openSettings() }
            }
            .onAppear { service.beginObserving() }
            .onDisappear { service.endObserving() }
        }
    }

    private func openSettings() {
        SettingsRouter.shared.request(FeatureSettingsDestination(.batteryCharge))
        (NSApp.delegate as? AppDelegate)?.openSettingsWindow()
    }
}
