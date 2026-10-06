// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

// Fork: the choreography of Claude's four-dot loader, one slow loop of
// moves. The dots swirl a quarter turn, fold over the diagonal (the pair
// off the fold passing behind and in front), sink back one after another,
// chase each other round a full turn, swirl home and breathe. Each move
// starts where the last one left the dots, and every move ends on the
// square, so the loop has no seam. Under it all the square drifts one slow
// turn per loop, so the dots are never quite still.
//
// Positions are in units of the square's half-width (the corners are ±1);
// depth runs from -1 (nearest) to 1 (farthest) and sets size, fade and
// which dot draws on top.

enum NotchClaudeSwirl {
    struct Pose: Equatable {
        var x: Double
        var y: Double
        var depth: Double

        /// Farther dots shrink; nearer ones grow a little.
        var scale: Double { depth > 0 ? 1 - 0.55 * depth : 1 - 0.22 * depth }
        /// Farther dots fade back; nearer ones stay solid.
        var opacity: Double { depth > 0 ? 1 - 0.78 * depth : 1 }
    }

    enum Move: Equatable {
        case swirl(clockwise: Bool)
        case fold
        case sink
        case chase
        case breathe
        case rest
    }

    /// The loop, each move with its share of seconds.
    static let moves: [(move: Move, seconds: Double)] = [
        (.swirl(clockwise: true), 1.4),
        (.rest, 0.2),
        (.fold, 1.7),
        (.rest, 0.15),
        (.sink, 2.0),
        (.chase, 2.2),
        (.rest, 0.15),
        (.swirl(clockwise: false), 1.3),
        (.breathe, 1.0),
    ]

    static var period: Double { moves.reduce(0) { $0 + $1.seconds } }

    /// Top-left, top-right, bottom-right, bottom-left.
    static let corners: [(Double, Double)] = [(-1, 1), (1, 1), (1, -1), (-1, -1)]

    /// Where dot `index` is at `phase` (0 to 1) through the loop.
    static func pose(dot index: Int, at phase: Double) -> Pose {
        let loop = phase - phase.rounded(.down)
        return drifted(choreographed(dot: index, at: loop), by: loop)
    }

    private static func choreographed(dot index: Int, at loop: Double) -> Pose {
        let corner = corners[((index % 4) + 4) % 4]
        var x = corner.0, y = corner.1
        var time = loop * period
        for (move, seconds) in moves {
            let progress = min(1, max(0, time / seconds))
            let pose = apply(move, x: x, y: y, dot: index, progress: progress)
            if time < seconds { return pose }
            x = pose.x.rounded()
            y = pose.y.rounded()
            time -= seconds
        }
        return Pose(x: x, y: y, depth: 0)
    }

    /// One slow turn against the swirl over the whole loop.
    private static func drifted(_ pose: Pose, by loop: Double) -> Pose {
        var turned = rotated(pose.x, pose.y, by: 2 * Double.pi * loop, scale: 1)
        turned.depth = pose.depth
        return turned
    }

    static func apply(_ move: Move, x: Double, y: Double, dot: Int, progress p: Double) -> Pose {
        switch move {
        case .rest:
            return Pose(x: x, y: y, depth: 0)
        case .swirl(let clockwise):
            // A quarter turn, drawing in as it speeds through the middle.
            let e = ease(p)
            let angle = (clockwise ? -1 : 1) * Double.pi / 2 * e
            let pull = 1 - 0.4 * sin(Double.pi * e)
            return rotated(x, y, by: angle, scale: pull)
        case .fold:
            // A half turn about the top-left to bottom-right diagonal: those
            // two stay on the hinge, the other two swap through the middle,
            // one passing behind and the other in front.
            let e = ease(p)
            let along = (x - y) / 2      // on the hinge, direction (1, -1)
            let across = (x + y) / 2     // off it, direction (1, 1)
            let theta = Double.pi * e
            let folded = across * cos(theta)
            return Pose(x: along + folded, y: -along + folded, depth: across * sin(theta) * 0.9)
        case .sink:
            // One after another, each dot falls back, fading as it goes, and
            // returns.
            let start = 0.17 * Double(order(of: dot))
            let local = min(1, max(0, (p - start) / 0.49))
            let depth = sin(Double.pi * ease(local))
            let draw = 1 - 0.3 * depth
            return Pose(x: x * draw, y: y * draw, depth: depth)
        case .chase:
            // A full turn where each dot sets off a little after the one
            // before, so they bunch up and spread out again.
            let start = 0.1 * Double(order(of: dot))
            let local = min(1, max(0, (p - start) / 0.7))
            let e = ease(local)
            let wobble = 1 - 0.18 * sin(Double.pi * e)
            var pose = rotated(x, y, by: -2 * Double.pi * e, scale: wobble)
            pose.depth = 0.25 * sin(2 * Double.pi * e)
            return pose
        case .breathe:
            let swell = 1 + 0.14 * sin(Double.pi * ease(p))
            return Pose(x: x * swell, y: y * swell, depth: -0.35 * sin(Double.pi * p))
        }
    }

    /// Smooth in and out, gentle enough that a move never seems to stall.
    static func ease(_ p: Double) -> Double {
        let t = min(1, max(0, p))
        return (1 - cos(Double.pi * t)) / 2
    }

    private static func order(of dot: Int) -> Int { ((dot % 4) + 4) % 4 }

    private static func rotated(_ x: Double, _ y: Double, by angle: Double, scale: Double) -> Pose {
        Pose(x: (x * cos(angle) - y * sin(angle)) * scale,
             y: (x * sin(angle) + y * cos(angle)) * scale,
             depth: 0)
    }
}
