// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

// Fork: the tabbed island. Everything the tabbed layout decides lives here so
// the upstream island files only carry small hooks into it.

extension DefaultsKey {
    /// Which open layout the island uses; see `NotchStyle`.
    static let notchStyle = "notchStyle"
    /// The Home page's widgets, in order, comma separated.
    static let notchHomeWidgets = "notchHomeWidgets"
}

/// `tabbed` keeps every section inside the island behind a row of tabs with a
/// Home dashboard first; `classic` is the upstream title, gallery and
/// floating buttons.
enum NotchStyle: String, CaseIterable, Identifiable {
    case tabbed, classic
    var id: String { rawValue }

    /// Unset reads as classic, so upstream behavior holds wherever the app's
    /// registered default (tabbed) is absent, such as the test harness.
    static func current(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: DefaultsKey.notchStyle) ?? "") ?? .classic
    }

    static func isTabbed(in defaults: UserDefaults = .standard) -> Bool { current(in: defaults) == .tabbed }
}

/// A card on the Home page. Each stands in for its section, so it shows only
/// while that section is part of the island.
enum NotchHomeWidget: String, CaseIterable, Identifiable {
    case music, calendar, timer
    var id: String { rawValue }

    static let maximum = 3
    static let defaultValue = "music,calendar"

    var module: NotchModule {
        switch self {
        case .music: return .music
        case .calendar: return .calendar
        case .timer: return .timer
        }
    }

    var title: String {
        switch self {
        case .music: return "Now Playing"
        case .calendar: return "Calendar"
        case .timer: return "Timer"
        }
    }

    var symbol: String { module.symbol }

    static func stored(in defaults: UserDefaults = .standard) -> [Self] {
        decode(defaults.string(forKey: DefaultsKey.notchHomeWidgets) ?? defaultValue)
    }

    static func decode(_ raw: String) -> [Self] {
        var seen = Set<Self>()
        let widgets = raw.split(separator: ",").compactMap { Self(rawValue: String($0)) }.filter { seen.insert($0).inserted }
        return Array(widgets.prefix(maximum))
    }

    static func encode(_ widgets: [Self]) -> String { widgets.map(\.rawValue).joined(separator: ",") }

    /// The stored widgets whose sections the island currently shows.
    static func current(modules: [NotchModule], in defaults: UserDefaults = .standard) -> [Self] {
        stored(in: defaults).filter { modules.contains($0.module) }
    }
}

enum NotchTabbedLayout {
    static let tabWidth: CGFloat = 32
    static let tabHeight: CGFloat = 28
    static let tabSpacing: CGFloat = 2
    /// Artwork, three text lines, the timeline and the transport.
    static let homeContentHeight: CGFloat = 132
    static let widgetMinimumWidth: CGFloat = 300
    static let widgetSpacing: CGFloat = 24

    /// The pinned set reads left to right: the left side, then the bottom,
    /// then the right, as the floating buttons were laid out.
    static func tabs(_ configuration: NotchQuickAccessConfiguration) -> [NotchQuickButton] {
        let sides: [NotchQuickAccessSide] = [.left, .bottom, .right]
        return sides.flatMap { side in configuration.buttons.filter { $0.side == side } }
    }

    /// Home plus the pinned tabs, as the header lays them out.
    static func tabStripWidth(count: Int) -> CGFloat {
        let tabs = CGFloat(count + 1)
        return tabs * tabWidth + max(0, tabs - 1) * tabSpacing
    }
}

extension NotchGeometry {
    /// Home holds its widgets side by side: the chosen island width, widened
    /// only as far as the widgets need and the display allows.
    func homeSize(widgets: Int) -> CGSize {
        let count = CGFloat(max(1, widgets))
        let needed = count * NotchTabbedLayout.widgetMinimumWidth + (count - 1) * NotchTabbedLayout.widgetSpacing
            + NotchLayout.horizontalInset * 2
        let width = max(expandedWidth, min(needed, screen.width - 24))
        let height = headerTopInset + headerChromeHeight + NotchTabbedLayout.homeContentHeight
        return CGSize(width: width, height: min(height, screen.height - 48))
    }
}
