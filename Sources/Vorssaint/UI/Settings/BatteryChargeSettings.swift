// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Fork: Settings › Charge Limit. The helper's state, the limit and how it
/// is held, heat protection and a one-shot top-up, plus how it sits next to
/// the Charge Limit macOS itself offers.
struct BatteryChargeSettings: View {
    @ObservedObject private var service = BatteryChargeService.shared
    @AppStorage(DefaultsKey.batteryChargeEnabled) private var enabled = false
    @AppStorage(DefaultsKey.batteryChargeLimit) private var limit = BatteryChargeConfig.defaultLimit
    @AppStorage(DefaultsKey.batteryChargeSailing) private var sailing = BatteryChargeConfig.defaultSailing
    @AppStorage(DefaultsKey.batteryChargeHeatProtection) private var heatProtection = true
    @AppStorage(DefaultsKey.batteryChargeHeatThreshold) private var heatThreshold = BatteryChargeConfig.defaultHeatThreshold
    @AppStorage(DefaultsKey.batteryChargeDischarge) private var discharge = false
    @AppStorage(DefaultsKey.batteryChargeMagSafeLED) private var magSafeLED = false
    @AppStorage(DefaultsKey.temperatureUnit) private var temperatureUnit = TemperatureUnit.celsius.rawValue

    private var mode: BatteryChargeMode? { service.status?.mode }

    var body: some View {
        Form {
            Section {
                Toggle("Limit battery charge", isOn: $enabled)
                    .onChange(of: enabled) { _, _ in service.syncWithPreferences() }
                Text("Keeps the battery at the limit while the Mac is on its adapter, so it doesn't sit at 100% for hours. A small helper does the work, so the limit holds while Vorssaint is quit and while the Mac sleeps.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                statusRow
                helperControls
                if let message = service.message {
                    Text(message).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(BatteryChargeSupport.title)
            }

            Section("Limit") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Charge to")
                        Spacer()
                        Text("\(limit)%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: intBinding($limit), in: Double(BatteryChargeConfig.limitRange.lowerBound)...Double(BatteryChargeConfig.limitRange.upperBound), step: 1)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Sailing")
                        Spacer()
                        Text(sailing == 0 ? "Off" : "\(sailing)%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: intBinding($sailing), in: Double(BatteryChargeConfig.sailingRange.lowerBound)...Double(BatteryChargeConfig.sailingRange.upperBound), step: 1)
                    Text("Once at \(limit)%, the battery drifts down to \(max(limit - max(effectiveSailing, 1), 0))% before charging again, instead of topping up a little every few minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if mode == .adapter {
                    Text("On this Mac, macOS doesn't let apps pause the charger, so the limit holds by running the Mac from its battery down to \(max(limit - max(effectiveSailing, 1), 0))% and then switching the adapter back on. The drift is at least \(BatteryChargePolicy.adapterMinimumSailing)%.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Toggle("Discharge to the limit", isOn: $discharge)
                        .onChange(of: discharge) { _, _ in service.writeConfig() }
                    Text("When the battery is above the limit on the adapter, run the Mac from the battery until it's back at the limit.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Heat protection") {
                Toggle("Pause charging while the battery is hot", isOn: $heatProtection)
                    .onChange(of: heatProtection) { _, _ in service.writeConfig() }
                if heatProtection {
                    Stepper(value: $heatThreshold, in: BatteryChargeConfig.heatThresholdRange) {
                        HStack {
                            Text("Above")
                            Spacer()
                            Text(MetricFormat.temperature(Double(heatThreshold),
                                                          unit: TemperatureUnit(rawValue: temperatureUnit) ?? .celsius))
                                .monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: heatThreshold) { _, _ in service.writeConfig() }
                    Text(mode == .adapter
                         ? "Charging resumes once the battery is \(Int(BatteryChargePolicy.heatHysteresis)) °C cooler. On this Mac a pause runs the Mac from its battery, so it ends at \(BatteryChargePolicy.adapterHeatFloor)% even if the battery is still warm."
                         : "Charging resumes once the battery is \(Int(BatteryChargePolicy.heatHysteresis)) °C cooler.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Top up") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Charge to 100% once")
                        Text("For a long day away from the adapter. Afterwards the battery goes back to \(limit)%.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if service.isTopUpPending {
                        Button("Stop Topping Up") { service.cancelTopUp() }
                    } else {
                        Button("Charge to 100% Now") { service.topUp() }
                            .disabled(!enabled || service.helperState != .running)
                    }
                }
            }

            Section("MagSafe") {
                Toggle("Show the limit on the MagSafe light", isOn: $magSafeLED)
                    .onChange(of: magSafeLED) { _, _ in service.writeConfig() }
                Text("Green while the battery is held at the limit, amber while it charges.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("macOS Charge Limit") {
                Text("macOS 26.4 and later has a Charge Limit of its own, from 80% to 100%, in System Settings › Battery › Charging. Both work together: whichever limit is lower stops the charge. A macOS limit of 80% also keeps holding while the Mac sleeps, so it's a good backstop for this one; this one adds limits below 80%, sailing, heat protection and top-ups.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Battery Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { service.beginObserving() }
        .onDisappear { service.endObserving() }
        .onChange(of: limit) { _, _ in service.writeConfig() }
        .onChange(of: sailing) { _, _ in service.writeConfig() }
    }

    private var effectiveSailing: Int {
        mode == .adapter ? max(sailing, BatteryChargePolicy.adapterMinimumSailing) : sailing
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "battery.75percent")
                .foregroundStyle(service.helperState == .running ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(service.stateLabel)
                if let status = service.status, service.helperState == .running {
                    Text(detail(status)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func detail(_ status: BatteryChargeStatus) -> String {
        var parts: [String] = []
        if let percent = status.percent { parts.append("\(percent)%") }
        if let plugged = status.pluggedIn { parts.append(plugged ? "on the adapter" : "on battery") }
        if let temperature = status.temperature {
            parts.append(MetricFormat.temperature(temperature,
                                                  unit: TemperatureUnit(rawValue: temperatureUnit) ?? .celsius))
        }
        if let error = status.lastError { parts.append("last error: \(error)") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var helperControls: some View {
        HStack {
            switch service.helperState {
            case .notInstalled:
                Button("Install Helper…") { service.installHelper() }
                Text("Asks for an administrator password once.")
                    .font(.caption).foregroundStyle(.secondary)
            case .needsUpdate:
                Button("Update Helper…") { service.installHelper() }
            case .notResponding:
                Button("Reinstall Helper…") { service.installHelper() }
            case .running:
                EmptyView()
            }
            Spacer()
            if service.helperState != .notInstalled {
                Button("Remove Helper…") { service.removeHelper() }
            }
        }
        .disabled(service.isWorking)
    }

    private func intBinding(_ value: Binding<Int>) -> Binding<Double> {
        Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) })
    }
}
