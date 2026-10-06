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
        suite.expect(folded[0].depth == 0 && folded[2].depth == 0 && folded[1].depth > 0.8 && folded[3].depth < -0.8,
                     "the fold keeps its hinge and passes one dot behind, one in front")
        suite.expect(NotchClaudeSwirl.period >= 9, "the loop is slow")
    }
}
