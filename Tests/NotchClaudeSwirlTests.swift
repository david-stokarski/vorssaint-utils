// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// Fork: Claude's loader loops without a seam: it starts and ends on the
/// square, never jumps between frames, and keeps its fades and sizes sane.
enum NotchClaudeSwirlTests {
    static func run(_ suite: TestSuite) {
        let square = Set(NotchClaudeSwirl.corners.map { "\(Int($0.0)),\(Int($0.1))" })
        func spot(_ pose: NotchClaudeSwirl.Pose) -> String {
            "\(Int(pose.x.rounded())),\(Int(pose.y.rounded()))"
        }
        let start = (0..<4).map { NotchClaudeSwirl.pose(dot: $0, at: 0) }
        suite.expect(start.map(spot) == NotchClaudeSwirl.corners.map { "\(Int($0.0)),\(Int($0.1))" }
                        && start.allSatisfy { $0.depth == 0 },
                     "the loop starts on the square, flat")
        let end = (0..<4).map { NotchClaudeSwirl.pose(dot: $0, at: 0.99999) }
        suite.expect(Set(end.map(spot)) == square
                        && end.allSatisfy { abs($0.depth) < 0.01 && abs(abs($0.x) - 1) < 0.01 && abs(abs($0.y) - 1) < 0.01 },
                     "it ends on the square too, so the repeat has no seam")

        for dot in 0..<4 {
            let first = NotchClaudeSwirl.pose(dot: dot, at: 0)
            let last = NotchClaudeSwirl.pose(dot: dot, at: 1 - 1e-7)
            let beforeLast = NotchClaudeSwirl.pose(dot: dot, at: 1 - 1e-4)
            let afterFirst = NotchClaudeSwirl.pose(dot: dot, at: 1e-4)
            suite.expect(hypot(first.x - last.x, first.y - last.y) < 1e-4 && abs(first.depth - last.depth) < 1e-4,
                         "dot \(dot) ends the loop on the corner it started from")
            // Moving the same way across the join: the step into the loop
            // matches the step out of it.
            let outX = last.x - beforeLast.x, outY = last.y - beforeLast.y
            let inX = afterFirst.x - first.x, inY = afterFirst.y - first.y
            suite.expect(hypot(outX - inX, outY - inY) < 2e-5 && hypot(inX, inY) > 1e-4, "dot \(dot) keeps its speed across the join")
        }

        let samples = 2000
        var largestStep = 0.0
        var saneLooks = true
        for dot in 0..<4 {
            var previous = NotchClaudeSwirl.pose(dot: dot, at: 0)
            for step in 1..<samples {
                let pose = NotchClaudeSwirl.pose(dot: dot, at: Double(step) / Double(samples))
                largestStep = max(largestStep, hypot(pose.x - previous.x, pose.y - previous.y),
                                  abs(pose.depth - previous.depth))
                if !(0.15...1).contains(pose.opacity) || !(0.4...1.25).contains(pose.scale)
                    || hypot(pose.x, pose.y) > 1.65 { saneLooks = false }
                previous = pose
            }
        }
        suite.expect(largestStep < 0.08, "no dot jumps between frames")
        suite.expect(saneLooks, "dots stay visible, sized sensibly and inside the loader")

        let folded = (0..<4).map { NotchClaudeSwirl.apply(.fold, x: NotchClaudeSwirl.corners[$0].0,
                                                          y: NotchClaudeSwirl.corners[$0].1, dot: $0, progress: 0.5) }
        suite.expect(folded[0].depth == 0 && folded[2].depth == 0 && abs(folded[1].x + 1) < 1e-9
                        && abs(folded[3].x - 1) < 1e-9,
                     "halfway, the fold keeps its hinge and has swapped the other two")
        let quarter = (0..<4).map { NotchClaudeSwirl.apply(.fold, x: NotchClaudeSwirl.corners[$0].0,
                                                           y: NotchClaudeSwirl.corners[$0].1, dot: $0, progress: 1.0 / 3) }
        suite.expect(quarter[1].depth > 0.8 && quarter[3].depth < -0.8,
                     "on the way one passes behind and one in front")
        suite.expect(NotchClaudeSwirl.period >= 9, "the loop is slow")
    }
}
