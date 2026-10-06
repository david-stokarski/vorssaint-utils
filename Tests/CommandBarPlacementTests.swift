// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Fork: the Command Bar's dragged spot. It snaps to the display's thirds and
/// middle, keeps off the edges, and carries to a display of another size.
enum CommandBarPlacementTests {
    static func run(_ suite: TestSuite) {
        let screen = CGRect(x: 0, y: 0, width: 3840, height: 1050)
        let size = CGSize(width: 560, height: 380)

        // Upstream's default spot is the standard placement.
        let standard = CommandBarPlacement.standard.origin(size: size, in: screen)
        let upstream = CommandBarPreferences.clampedPanelOrigin(size: size, in: screen, offset: .zero)
        suite.expect(abs(standard.x - upstream.x) < 0.5 && abs(standard.y - upstream.y) < 0.5,
                     "the standard placement is where the bar always opened")

        // Snapping.
        let nearCentre = CGPoint(x: 1920 - 280 + 9, y: 525 - 380 - 6)
        let snapped = CommandBarPlacement.snap(nearCentre, size: size, in: screen)
        suite.expect(snapped.origin.x == 1920 - 280 && snapped.origin.y + size.height == 525,
                     "a bar dropped near the middle lands centred with its top on the middle line")
        suite.expect(CommandBarPlacement.label(for: snapped.guides) == "Centred · Middle", "the landing is named")
        let free = CommandBarPlacement.snap(nearCentre, size: size, in: screen, enabled: false)
        suite.expect(free.origin == nearCentre && free.guides.isEmpty, "Option places the bar freely")
        let far = CGPoint(x: 900, y: 400)
        suite.expect(CommandBarPlacement.snap(far, size: size, in: screen).guides.isEmpty,
                     "a bar far from every guide stays where it was dropped")
        let thirdX = 3840.0 / 3
        let leftThird = CommandBarPlacement.snap(CGPoint(x: thirdX - 280 - 10, y: 400), size: size, in: screen)
        suite.expect(leftThird.guides.first?.name == "Left third" && leftThird.origin.x == thirdX - 280,
                     "the left third pulls the bar's centre onto it")
        let offscreen = CommandBarPlacement.snap(CGPoint(x: -500, y: 2000), size: size, in: screen)
        suite.expect(offscreen.origin.x == 16 && offscreen.origin.y == 1050 - 380 - 16, "the bar keeps off the edges")

        // Storage and other displays.
        let placement = CommandBarPlacement.of(CGRect(origin: snapped.origin, size: size), in: screen)
        suite.expect(CommandBarPlacement.decode(placement.encoded) == placement, "a placement round-trips")
        suite.expect(abs(placement.x - 0.5) < 0.0001 && abs(placement.y - 0.5) < 0.0001, "centred and middle as shares")
        let laptop = CGRect(x: 0, y: 0, width: 1512, height: 945)
        let there = placement.origin(size: size, in: laptop)
        suite.expect(abs(there.x + size.width / 2 - 756) < 0.5 && abs(there.y + size.height - 472.5) < 0.5,
                     "the same spot on a smaller display is still centred and in the middle")
        suite.expect(CommandBarPlacement.decode("2,0.5") == nil && CommandBarPlacement.decode("x") == nil
                        && CommandBarPlacement.decode(nil) == nil, "bad stored values are ignored")

        // The drop out of the island reaches a bar wherever it was put.
        let field = CGRect(x: 100, y: 400, width: 560, height: 50)
        let icon = CGPoint(x: field.minX + 27, y: field.midY)
        let drop = CommandBarDropletMotion.drop(edge: 10, centerX: 1200, field: field, icon: icon)
        let landed = drop.frames.first { $0.bead.midY >= field.midY - 0.5 && $0.bead.width < field.width / 2 }
        suite.expect(landed.map { abs($0.bead.midX - field.midX) < 1 } ?? false,
                     "the drop lands on a bar dragged to the side, not under the island")
        suite.expect(drop.frames.last?.bead == field && drop.frames.last?.mascot == icon,
                     "the drop ends as the bar's field with the companion in place")
        let rise = CommandBarDropletMotion.retract(edge: 10, centerX: 1200, bar: field, field: field, icon: icon)
        suite.expect(rise.frames.first.map { abs($0.bead.midX - field.midX) < 1 } ?? false
                        && rise.frames.last.map { abs($0.bead.midX - 1200) < 1 } ?? false,
                     "closing folds where the bar is and rises across to the island")
    }
}
