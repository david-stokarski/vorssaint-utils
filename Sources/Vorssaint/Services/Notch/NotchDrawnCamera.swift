// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

// Fork: on a display without a camera, the hanging island draws a camera's
// gap of its own. Its width can be chosen, per display like the island's
// other sizes; automatic keeps the width that follows the menu bar's height,
// and lets the gap widen for a sung line. A chosen width stays put and a
// longer line scrolls through it.

extension DefaultsKey {
    static let notchDrawnCameraWidth = "notchDrawnCameraWidth"
}

enum NotchDrawnCamera {
    static let range: ClosedRange<Double> = 120...480
    static let step: Double = 2

    /// The chosen width, or 0 for automatic.
    static func width(in defaults: UserDefaults = .standard) -> CGFloat {
        let value = defaults.double(forKey: DefaultsKey.notchDrawnCameraWidth)
        guard value.isFinite, value > 0 else { return 0 }
        return CGFloat(min(range.upperBound, max(range.lowerBound, value)))
    }
}
