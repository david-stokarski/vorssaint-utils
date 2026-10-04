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
