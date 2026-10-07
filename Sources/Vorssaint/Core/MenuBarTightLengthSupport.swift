// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: every Vorssaint menu bar item is exactly as wide as what it shows.
/// A variable-length item gets padding from macOS on both sides; a fixed
/// length that hugs the content removes it.
enum MenuBarTightLengthSupport {
    enum Layout: Equatable {
        case imageOnly, titleOnly, imageAndTitle
    }

    /// A hair of room so antialiased edges never clip.
    static let margin = 2.0
    /// What the button cell puts between a leading image and its title.
    static let imageTitleGap = 2.0

    /// The fixed length for an item, or nil when it shows nothing and should
    /// keep macOS's own sizing.
    static func length(layout: Layout, imageWidth: Double, titleWidth: Double) -> Double? {
        let content: Double
        switch layout {
        case .imageOnly: content = imageWidth
        case .titleOnly: content = titleWidth
        case .imageAndTitle:
            content = imageWidth + (titleWidth > 0 && imageWidth > 0 ? imageTitleGap : 0) + titleWidth
        }
        guard content > 0 else { return nil }
        return (content + margin).rounded(.up)
    }
}
