// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit

/// Fork: sizes a status item to its button's image and title, with no
/// padding of its own. Call after the button's content changes.
enum MenuBarTightLength {
    static func apply(to item: NSStatusItem) {
        guard let button = item.button else { return }
        let imageWidth = Double(button.image?.size.width ?? 0)
        let titleWidth = button.attributedTitle.length > 0 ? Double(button.attributedTitle.size().width) : 0
        let layout: MenuBarTightLengthSupport.Layout
        switch button.imagePosition {
        case .noImage: layout = .titleOnly
        case .imageOnly: layout = .imageOnly
        default: layout = .imageAndTitle
        }
        let length = MenuBarTightLengthSupport.length(layout: layout, imageWidth: imageWidth,
                                                      titleWidth: titleWidth).map { CGFloat($0) }
            ?? NSStatusItem.variableLength
        if item.length != length {
            item.length = length
        }
    }
}
