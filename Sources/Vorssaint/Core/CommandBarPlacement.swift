// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

// Fork: where the Command Bar opens, chosen by dragging it. The spot is kept
// as a share of the display (its centre across, its top edge down), so a bar
// snapped to "centred, upper third" opens there on any display. While it is
// dragged it snaps to the display's thirds and middle, as Raycast's does.

extension DefaultsKey {
    /// "x,y": the bar's centre across and its top edge down, as fractions of
    /// the visible frame. Empty means upstream's offset (or default) applies.
    static let commandBarPlacement = "commandBarPlacement"
}

struct CommandBarPlacement: Equatable {
    /// The bar's horizontal centre, 0 at the left edge, 1 at the right.
    var x: CGFloat
    /// The bar's top edge, 0 at the top of the visible frame, 1 at the bottom.
    var y: CGFloat

    /// Upstream's default spot: centred, the top edge 72% of the way up.
    static let standard = CommandBarPlacement(x: 0.5, y: 0.28)

    /// A line the bar can snap to while it is dragged.
    struct Guide: Equatable {
        enum Axis { case vertical, horizontal }
        var axis: Axis
        var fraction: CGFloat
        var name: String
        /// Drawn dashed and fainter: a position, not a grid line.
        var isMarker = false
    }

    static let verticalGuides: [Guide] = [
        Guide(axis: .vertical, fraction: 1.0 / 3, name: "Left third"),
        Guide(axis: .vertical, fraction: 0.5, name: "Centred"),
        Guide(axis: .vertical, fraction: 2.0 / 3, name: "Right third"),
    ]

    static let horizontalGuides: [Guide] = [
        Guide(axis: .horizontal, fraction: standard.y, name: "Default height", isMarker: true),
        Guide(axis: .horizontal, fraction: 1.0 / 3, name: "Upper third"),
        Guide(axis: .horizontal, fraction: 0.5, name: "Middle"),
        Guide(axis: .horizontal, fraction: 2.0 / 3, name: "Lower third"),
    ]

    /// How close, in points, the bar must come to a guide to land on it.
    static let snapDistance: CGFloat = 14
    /// Kept clear between the bar and the display's edges.
    static let margin: CGFloat = 16

    // MARK: - Storage

    static func decode(_ raw: String?) -> CommandBarPlacement? {
        guard let parts = raw?.split(separator: ","), parts.count == 2,
              let x = Double(parts[0]), let y = Double(parts[1]),
              x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { return nil }
        return CommandBarPlacement(x: x, y: y)
    }

    /// Stored, never shown: four places, written the same in every locale.
    var encoded: String {
        func part(_ value: CGFloat) -> String { String(Double((value * 10_000).rounded()) / 10_000) }
        return part(x) + "," + part(y)
    }

    static func stored(in defaults: UserDefaults = .standard) -> CommandBarPlacement? {
        decode(defaults.string(forKey: DefaultsKey.commandBarPlacement))
    }

    // MARK: - Geometry (AppKit coordinates, origin bottom-left)

    /// Where a bar of `size` sits for this placement on `visibleFrame`, kept
    /// off the edges.
    func origin(size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        let wanted = CGPoint(x: visibleFrame.minX + x * visibleFrame.width - size.width / 2,
                             y: visibleFrame.maxY - y * visibleFrame.height - size.height)
        return Self.clamped(wanted, size: size, in: visibleFrame)
    }

    /// The placement a bar at `frame` has on `visibleFrame`.
    static func of(_ frame: CGRect, in visibleFrame: CGRect) -> CommandBarPlacement {
        let x = (frame.midX - visibleFrame.minX) / max(1, visibleFrame.width)
        let y = (visibleFrame.maxY - frame.maxY) / max(1, visibleFrame.height)
        return CommandBarPlacement(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    static func clamped(_ origin: CGPoint, size: CGSize, in visibleFrame: CGRect) -> CGPoint {
        let minX = visibleFrame.minX + margin
        let maxX = max(minX, visibleFrame.maxX - size.width - margin)
        let minY = visibleFrame.minY + margin
        let maxY = max(minY, visibleFrame.maxY - size.height - margin)
        return CGPoint(x: min(max(origin.x, minX), maxX), y: min(max(origin.y, minY), maxY))
    }

    /// Where the bar lands: on the nearest guide on each axis within
    /// `snapDistance`, otherwise where it was dragged. Returns the guides it
    /// landed on, for the overlay to light up.
    static func snap(_ origin: CGPoint, size: CGSize, in visibleFrame: CGRect,
                     enabled: Bool = true) -> (origin: CGPoint, guides: [Guide]) {
        var result = origin
        var landed: [Guide] = []
        if enabled {
            let midX = origin.x + size.width / 2
            let nearestX = verticalGuides.min {
                abs(position(of: $0, in: visibleFrame) - midX) < abs(position(of: $1, in: visibleFrame) - midX)
            }
            if let guide = nearestX, abs(position(of: guide, in: visibleFrame) - midX) <= snapDistance {
                result.x = position(of: guide, in: visibleFrame) - size.width / 2
                landed.append(guide)
            }
            let top = origin.y + size.height
            let nearestY = horizontalGuides.min {
                abs(position(of: $0, in: visibleFrame) - top) < abs(position(of: $1, in: visibleFrame) - top)
            }
            if let guide = nearestY, abs(position(of: guide, in: visibleFrame) - top) <= snapDistance {
                result.y = position(of: guide, in: visibleFrame) - size.height
                landed.append(guide)
            }
        }
        return (clamped(result, size: size, in: visibleFrame), landed)
    }

    /// A guide's line in screen coordinates: x for vertical, y for horizontal.
    static func position(of guide: Guide, in visibleFrame: CGRect) -> CGFloat {
        switch guide.axis {
        case .vertical: return visibleFrame.minX + guide.fraction * visibleFrame.width
        case .horizontal: return visibleFrame.maxY - guide.fraction * visibleFrame.height
        }
    }

    /// "Centred · Upper third", or nil when the bar sits on no guide.
    static func label(for guides: [Guide]) -> String? {
        guides.isEmpty ? nil : guides.map(\.name).joined(separator: " · ")
    }
}

// Fork: how the bar's opening plays. The drop out of the island (and its
// rise back) can run faster or slower, or not at all.

extension DefaultsKey {
    static let commandBarAnimates = "commandBarAnimates"
    /// 1 is the drop's own pace; 2 plays it in half the time.
    static let commandBarAnimationSpeed = "commandBarAnimationSpeed"
}

enum CommandBarAnimation {
    static let speedRange: ClosedRange<Double> = 0.5...3
    static let registeredDefaults: [String: Any] = [
        DefaultsKey.commandBarAnimates: true,
        DefaultsKey.commandBarAnimationSpeed: 1.0,
    ]

    static func animates(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: DefaultsKey.commandBarAnimates) as? Bool ?? true
    }

    static func speed(in defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.object(forKey: DefaultsKey.commandBarAnimationSpeed) as? Double ?? 1
        return stored.isFinite ? min(max(stored, speedRange.lowerBound), speedRange.upperBound) : 1
    }
}

extension CommandBarDropletMotion {
    /// The same motion played `speed` times as fast.
    func scaled(by speed: Double) -> CommandBarDropletMotion {
        guard speed.isFinite, speed > 0, speed != 1 else { return self }
        var motion = self
        motion.duration /= speed
        motion.landing /= speed
        motion.reveal /= speed
        motion.opening /= speed
        return motion
    }
}
