// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Fork: the Snap Wheel. The trigger tells sides apart, a hold arms only on
/// exactly its keys and gives way to anything else, the pointer picks the
/// directions Loop's ring does, lists step the way Loop's cycles do, and
/// Loop's own preferences come over.
enum SnapWheelSupportTests {
    static func run(_ suite: TestSuite) {
        trigger(suite)
        hold(suite)
        geometry(suite)
        cycle(suite)
        slots(suite)
        loopImport(suite)
        feel(suite)
    }

    private static func feel(_ suite: TestSuite) {
        let relaxed = SnapWheelFeel(sensitivity: 0, recenters: true, restDelay: 0.3)
        let twitchy = SnapWheelFeel(sensitivity: 1, recenters: true, restDelay: 0.3)
        suite.expect(twitchy.showDistance < relaxed.showDistance, "twitchy shows the ring sooner")
        suite.expect(twitchy.directionalDistance(size: 100, thickness: 10)
                        < relaxed.directionalDistance(size: 100, thickness: 10) / 2,
                     "twitchy picks a direction with under half the movement")
        suite.expect(twitchy.directionalDistance(size: 100, thickness: 10) > twitchy.showDistance,
                     "the center is still reachable before a direction")
        let flick = CGPoint(x: 20, y: 0)
        suite.expect(SnapWheelGeometry.slot(from: .zero, to: flick,
                                            directionalDistance: twitchy.directionalDistance(size: 100, thickness: 10),
                                            showDistance: twitchy.showDistance) == .right,
                     "a 20-point flick picks a direction when twitchy")
        suite.expect(SnapWheelGeometry.slot(from: .zero, to: flick,
                                            directionalDistance: relaxed.directionalDistance(size: 100, thickness: 10),
                                            showDistance: relaxed.showDistance) == .center,
                     "and is still the center when relaxed")

        var anchor = SnapWheelAnchor(origin: .zero, at: 0)
        suite.expect(!anchor.move(to: CGPoint(x: 30, y: 0), at: 0.05, restDelay: 0.3), "moving on keeps the center")
        suite.expect(!anchor.move(to: CGPoint(x: 60, y: 0), at: 0.10, restDelay: 0.3), "still moving")
        suite.expect(!anchor.move(to: CGPoint(x: 61, y: 0.5), at: 0.80, restDelay: 0.3), "a tremor is not movement")
        suite.expect(anchor.move(to: CGPoint(x: 60, y: 30), at: 0.90, restDelay: 0.3),
                     "moving on after a rest starts over")
        suite.expect(anchor.origin == CGPoint(x: 60, y: 0) && anchor.hasMoved, "from where the pointer rested")
        var still = SnapWheelAnchor(origin: .zero, at: 0)
        suite.expect(!still.move(to: CGPoint(x: 0, y: 40), at: 2, restDelay: 0.3),
                     "resting where the hold began changes nothing")

        // Circles.
        func draw(_ points: [CGPoint], step: TimeInterval = 0.01) -> Int {
            var circle = SnapWheelCircle()
            var found = 0
            for (index, point) in points.enumerated() where circle.add(point, at: Double(index) * step) { found += 1 }
            return found
        }
        func loop(radius: CGFloat, turns: Double = 1.05, clockwise: Bool = false, squash: CGFloat = 1) -> [CGPoint] {
            let count = Int(120 * turns)
            return (0...count).map { i in
                let angle = Double(i) / 120 * 2 * .pi * (clockwise ? -1 : 1)
                return CGPoint(x: 500 + radius * CGFloat(cos(angle)), y: 400 + radius * squash * CGFloat(sin(angle)))
            }
        }
        suite.expect(draw(loop(radius: 80)) == 1, "a big circle is noticed")
        suite.expect(draw(loop(radius: 80, clockwise: true)) == 1, "either way round")
        suite.expect(draw(loop(radius: 80, turns: 2.1)) == 2, "two circles are two")
        suite.expect(draw(loop(radius: 25)) == 0, "a small loop is not")
        // A hand-drawn loop: wobbling radius, uneven speed, a little short of closing.
        var seed: UInt64 = 7
        let wobbly: [CGPoint] = (0...95).map { i in
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = CGFloat(Int(seed >> 59) - 16) * 0.6
            let angle = Double(i) / 108 * 2 * .pi + 0.3 * sin(Double(i) / 9)
            let radius = 60 + 12 * CGFloat(sin(Double(i) / 7)) + noise
            return CGPoint(x: 500 + radius * CGFloat(cos(angle)), y: 400 + radius * 0.8 * CGFloat(sin(angle)))
        }
        suite.expect(draw(wobbly) == 1, "a wobbly, uneven, not quite closed loop is noticed")
        var cycle = SnapWheelCycle()
        _ = cycle.enter(.center, actions: ["maximize", "center"], windowPlacement: "maximize")
        suite.expect(cycle.select(.center, index: 0, actions: ["maximize", "center"]) == "maximize",
                     "a circle picks the first placement even on a maximized window")
        suite.expect(draw(loop(radius: 120, squash: 0.25)) == 0, "a flat loop is not")
        suite.expect(draw(loop(radius: 80, turns: 0.7)) == 0, "two thirds of a circle is not")
        suite.expect(draw(loop(radius: 80), step: 0.5) == 0, "a circle drawn with pauses is not")
        suite.expect(draw((0...200).map { CGPoint(x: CGFloat($0) * 3, y: 0) }) == 0, "a straight line is not")
        suite.expect(draw((0...200).map { CGPoint(x: CGFloat($0) * 3, y: $0 % 10 < 5 ? 0 : 30) }) == 0,
                     "a zigzag is not")
        let square: [CGPoint] = (0..<40).map { CGPoint(x: 400 + CGFloat($0) * 5, y: 300) }
            + (0..<40).map { CGPoint(x: 600, y: 300 + CGFloat($0) * 5) }
            + (0..<40).map { CGPoint(x: 600 - CGFloat($0) * 5, y: 500) }
            + (0..<40).map { CGPoint(x: 400, y: 500 - CGFloat($0) * 5) }
            + (0..<10).map { CGPoint(x: 400 + CGFloat($0) * 5, y: 300) }
        suite.expect(draw(square) == 1, "a loop drawn as a rough square, closed, counts too")
        var partial = SnapWheelCircle()
        for (index, point) in loop(radius: 80, turns: 0.6).enumerated() { _ = partial.add(point, at: Double(index) * 0.01) }
        suite.expect(partial.isCircling, "halfway round is circling, so the preview waits")

        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.snapwheel-feel")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.snapwheel-feel")
        defer { defaults.removePersistentDomain(forName: "com.vorssaint.tests.snapwheel-feel") }
        suite.expect(SnapWheelFeel.current(in: defaults) == SnapWheelFeel(), "on and fairly twitchy by default")
        defaults.set(9.0, forKey: DefaultsKey.snapWheelRestDelay)
        suite.expect(SnapWheelFeel.current(in: defaults).restDelay == SnapWheelFeel.restDelayRange.upperBound,
                     "a stored delay is kept in range")
    }

    private static func trigger(_ suite: TestSuite) {
        // Device bits: left control 0x1, right control 0x2000; generic control 0x40000.
        let leftControl = SnapWheelTriggerKeys(eventFlags: 0x0004_0001)
        let rightControl = SnapWheelTriggerKeys(eventFlags: 0x0004_2000)
        suite.expect(leftControl == .leftControl, "left control is read from its device bit")
        suite.expect(rightControl == .rightControl, "right control is read from its device bit")
        suite.expect(SnapWheelTriggerKeys(eventFlags: CGEventFlags.maskControl.rawValue) == .leftControl,
                     "a generic control flag without a side counts as the left key")
        suite.expect(SnapWheelTriggerKeys(eventFlags: 0x0008_0020 | 0x0004_0001) == [.leftOption, .leftControl],
                     "two modifiers are both read")
        suite.expect(SnapWheelTriggerKeys(eventFlags: CGEventFlags.maskSecondaryFn.rawValue) == .function, "fn is read")
        suite.expect(SnapWheelTriggerKeys(eventFlags: 0x100) == [], "the always-set non-coalesced bit is ignored")

        let sided = SnapWheelTrigger(keys: .leftControl, eitherSide: false)
        suite.expect(sided.matches(.leftControl) && !sided.matches(.rightControl),
                     "a sided trigger only answers its own side")
        let either = SnapWheelTrigger(keys: .leftControl, eitherSide: true)
        suite.expect(either.matches(.rightControl) && either.matches(.leftControl), "either side answers both")
        suite.expect(!either.matches(SnapWheelTriggerKeys([.leftControl, .leftShift])), "an extra modifier is not the trigger")

        suite.expect(SnapWheelTriggerKeys(storageValue: "leftControl+rightOption") == [.leftControl, .rightOption],
                     "storage round-trips")
        suite.expect(SnapWheelTriggerKeys(storageValue: ([.leftCommand, .function] as SnapWheelTriggerKeys).storageValue)
                        == [.leftCommand, .function], "storage value parses back")
        suite.expect(SnapWheelTriggerKeys(storageValue: "control") == nil, "unknown tokens are refused")
        suite.expect(!SnapWheelTriggerKeys.leftShift.isUsableTrigger, "shift alone cannot be the trigger")
        suite.expect(SnapWheelTriggerKeys([.leftShift, .leftControl]).isUsableTrigger, "shift with company can")
        suite.expect(SnapWheelTriggerKeys.rightControl.displayName(eitherSide: false) == "Right Control",
                     "a sided key names its side")
        suite.expect(SnapWheelTriggerKeys.rightControl.displayName(eitherSide: true) == "Control",
                     "either side drops it")

        let defaults = UserDefaults(suiteName: "com.vorssaint.tests.snapwheel")!
        defaults.removePersistentDomain(forName: "com.vorssaint.tests.snapwheel")
        defer { defaults.removePersistentDomain(forName: "com.vorssaint.tests.snapwheel") }
        suite.expect(SnapWheelTrigger.current(in: defaults) == SnapWheelTrigger.default, "Left Control by default, as Loop has it")
        defaults.set("leftShift", forKey: DefaultsKey.snapWheelTrigger)
        suite.expect(SnapWheelTrigger.current(in: defaults) == SnapWheelTrigger.default, "a stored shift-only trigger falls back")
    }

    private static func hold(_ suite: TestSuite) {
        typealias Keys = SnapWheelTriggerKeys
        var hold = SnapWheelHold(trigger: .default)
        suite.expect(hold.update(.leftControl) == .arm, "holding the trigger arms")
        suite.expect(hold.update(.leftControl) == .nothing, "a repeat changes nothing")
        suite.expect(hold.update([]) == .release, "letting go releases")
        suite.expect(hold.update(.leftControl) == .arm, "and it arms again")
        suite.expect(hold.update(Keys([.leftControl, .leftShift])) == .cancel, "another modifier joining cancels")
        suite.expect(hold.update(.leftControl) == .nothing, "dropping it again does not re-arm")
        suite.expect(hold.update([]) == .nothing && hold.update(.leftControl) == .arm,
                     "only a fresh press arms after a cancel")

        var shiftFirst = SnapWheelHold(trigger: .default)
        suite.expect(shiftFirst.update(.leftShift) == .nothing, "an unrelated key alone does nothing")
        suite.expect(shiftFirst.update(Keys([.leftShift, .leftControl])) == .nothing, "the trigger with it does not arm")
        suite.expect(shiftFirst.update(.leftControl) == .nothing, "nor once the other key is up")
        suite.expect(shiftFirst.update([]) == .nothing && shiftFirst.update(.leftControl) == .arm,
                     "after everything is up it arms")

        var input = SnapWheelHold(trigger: .default)
        _ = input.update(.leftControl)
        suite.expect(input.cancel(), "a click while armed reports the cancel")
        suite.expect(input.update([]) == .nothing, "and the release then places nothing")

        var held = SnapWheelHold(trigger: .default, initiallyHeld: .leftControl)
        suite.expect(held.update(.leftControl) == .nothing, "a key already down at start does not arm")

        var chord = SnapWheelHold(trigger: SnapWheelTrigger(keys: [.leftControl, .leftOption], eitherSide: false))
        suite.expect(chord.update(.leftControl) == .nothing, "half a chord waits")
        suite.expect(chord.update(Keys([.leftControl, .leftOption])) == .arm, "the whole chord arms")
        suite.expect(chord.update(.leftOption) == .release, "letting go of one key releases")

        var right = SnapWheelHold(trigger: .default)
        suite.expect(right.update(.rightControl) == .nothing, "the other side stays free")
    }

    private static func geometry(_ suite: TestSuite) {
        let o = CGPoint.zero
        let reach = SnapWheelGeometry.directionalDistance(size: 100, thickness: 22)
        suite.expect(reach == 28, "the hole of the ring is the center")
        suite.expect(SnapWheelGeometry.slot(from: o, to: CGPoint(x: 4, y: 3), directionalDistance: reach) == nil,
                     "a few points is no choice")
        suite.expect(SnapWheelGeometry.slot(from: o, to: CGPoint(x: 15, y: 0), directionalDistance: reach) == .center,
                     "inside the hole is the center")
        let cases: [(CGPoint, SnapWheelSlot)] = [
            (CGPoint(x: 60, y: 0), .right), (CGPoint(x: 0, y: 60), .top), (CGPoint(x: -60, y: 0), .left),
            (CGPoint(x: 0, y: -60), .bottom), (CGPoint(x: 40, y: 40), .topRight), (CGPoint(x: -40, y: 40), .topLeft),
            (CGPoint(x: -40, y: -40), .bottomLeft), (CGPoint(x: 40, y: -40), .bottomRight),
            (CGPoint(x: 60, y: 20), .right), (CGPoint(x: 60, y: -20), .right),
        ]
        for (point, slot) in cases {
            suite.expect(SnapWheelGeometry.slot(from: o, to: point, directionalDistance: reach) == slot,
                         "\(point) points \(slot.rawValue)")
        }
        suite.expect(SnapWheelGeometry.continuousAngle(from: 0, to: -315) == 45, "turns the short way round")
        suite.expect(SnapWheelGeometry.continuousAngle(from: 350, to: 10) == 370, "keeps going past a full turn")
        suite.expect(SnapWheelGeometry.continuousAngle(from: -90, to: -180) == -180, "a quarter turn stays one")

        let pinned = SnapWheelGeometry.trackedPointer(previous: CGPoint(x: 0, y: 500), location: CGPoint(x: 0, y: 500),
                                                      delta: CGVector(dx: -30, dy: 0), pinnedX: true, pinnedY: false,
                                                      reach: 50)
        suite.expect(pinned == CGPoint(x: -30, y: 500), "movement past a screen edge still counts")
        let capped = SnapWheelGeometry.trackedPointer(previous: CGPoint(x: -45, y: 500), location: CGPoint(x: 0, y: 500),
                                                      delta: CGVector(dx: -30, dy: 0), pinnedX: true, pinnedY: false,
                                                      reach: 50)
        suite.expect(capped.x == -50, "up to a limit")
        let free = SnapWheelGeometry.trackedPointer(previous: CGPoint(x: -45, y: 500), location: CGPoint(x: 300, y: 400),
                                                    delta: CGVector(dx: 5, dy: 0), pinnedX: false, pinnedY: false,
                                                    reach: 50)
        suite.expect(free == CGPoint(x: 300, y: 400), "away from the edge the pointer is the pointer")
        suite.expect(SnapWheelGeometry.inset(CGRect(x: 0, y: 0, width: 100, height: 60), by: 10)
                        == CGRect(x: 10, y: 10, width: 80, height: 40), "padding pulls the preview in")
        suite.expect(SnapWheelGeometry.inset(CGRect(x: 0, y: 0, width: 50, height: 50), by: 40).width == 40,
                     "but never inside out")
    }

    private static func cycle(_ suite: TestSuite) {
        let left = ["leftHalf", "leftThird", "leftTwoThirds"]
        var cycle = SnapWheelCycle()
        suite.expect(cycle.enter(.left, actions: left, windowPlacement: nil) == "leftHalf", "first in starts the list")
        suite.expect(cycle.advance(.left, actions: left) == "leftThird", "a click steps on")
        suite.expect(cycle.enter(.right, actions: ["rightHalf"], windowPlacement: nil) == "rightHalf", "elsewhere")
        suite.expect(cycle.enter(.left, actions: left, windowPlacement: nil) == "leftThird",
                     "coming back keeps the step")
        suite.expect(cycle.advance(.left, actions: left) == "leftTwoThirds"
                        && cycle.advance(.left, actions: left) == "leftHalf", "and wraps around")

        var next = SnapWheelCycle()
        suite.expect(next.enter(.left, actions: left, windowPlacement: "leftHalf") == "leftThird",
                     "a window already on the half goes on to the third")
        var other = SnapWheelCycle()
        suite.expect(other.enter(.left, actions: left, windowPlacement: "rightHalf") == "leftHalf",
                     "a placement from another list starts over")
        suite.expect(other.enter(.top, actions: [], windowPlacement: nil) == nil, "an empty direction does nothing")
        suite.expect(other.advance(.top, actions: []) == nil, "and cannot step")
    }

    private static func slots(_ suite: TestSuite) {
        let defaults = SnapWheelSlots.decode(nil)
        suite.expect(defaults[.left] == ["leftHalf", "leftThird", "leftTwoThirds"], "Left cycles a half and thirds")
        suite.expect(defaults[.center] == ["maximize", "center"], "the center maximizes, then centers")
        var custom = defaults
        custom[.top] = []
        custom[.topLeft] = ["topLeftSixth", "minimize"]
        suite.expect(SnapWheelSlots.decode(SnapWheelSlots.encode(custom)) == custom, "slots round-trip")
        suite.expect(SnapWheelSlots.decode("not json") == defaults, "damaged storage falls back")
        for action in SnapWheelSlot.allCases.flatMap({ defaults[$0] ?? [] }) {
            suite.expect(SnapWheelLoopImport.directions.values.contains(action), "\(action) is a known action")
        }
    }

    private static func loopImport(_ suite: TestSuite) {
        // As Loop 1.4 stores them (from a real install).
        let loop: [String: Any] = [
            "trigger": [NSNumber(value: 59)],
            "sideDependentTriggerKey": NSNumber(value: true),
            "radialMenuTop": #"{"cycle":[{"direction":"TopHalf","id":"A","keybind":[]},{"direction":"TopThird","id":"B","keybind":[]},{"direction":"TopTwoThirds","id":"C","keybind":[]}],"direction":"Cycle","id":"D","keybind":[]}"#,
            "radialMenuTopLeft": #"{"direction":"TopLeftQuarter","id":"E","keybind":[]}"#,
            "radialMenuCenter": #"{"cycle":[{"direction":"Maximize","id":"F","keybind":[]},{"direction":"MacOSCenter","id":"G","keybind":[]}],"direction":"Cycle","id":"H","keybind":[]}"#,
            "lockRadialMenuToCenter": NSNumber(value: false),
            "radialMenuCornerRadius": NSNumber(value: 30),
            "radialMenuThickness": NSNumber(value: 10),
            "accentColorMode": NSNumber(value: 2),
            "useGradient": NSNumber(value: true),
            "customAccentColor": ["kCGColorSpaceExtendedSRGB", ["0.4311406016349792", "0.4311406016349792", "0.4311406016349792", 1]],
            "gradientColor": ["kCGColorSpaceExtendedSRGB", ["0.1959218680858612", "0.1959218680858612", "0.1959218680858612", 1]],
            "previewVisibility": NSNumber(value: true),
            "previewPadding": NSNumber(value: 0),
            "previewCornerRadius": "19.81048583984375",
            "previewBorderThickness": "1.8228759765625",
            "previewBackgroundEnableBlur": NSNumber(value: true),
            "previewBackgroundAccentOpacity": NSNumber(value: 0),
            "previewStartingPosition": "screenCenter",
            "hapticFeedback": NSNumber(value: true),
            "resizeWindowUnderCursor": NSNumber(value: false),
            "useScreenWithCursor": NSNumber(value: true),
            "enablePadding": NSNumber(value: true),
            "padding": #"{"bottom":0,"configureScreenPadding":true,"externalBar":0,"left":0,"right":0,"top":0,"window":10}"#,
        ]
        let result = SnapWheelLoopImport.preferences(from: loop)
        suite.expect(result[DefaultsKey.snapWheelTrigger] as? String == "leftControl", "key 59 is Left Control")
        suite.expect(result[DefaultsKey.snapWheelTriggerEitherSide] as? Bool == false, "side-dependent stays sided")
        let slots = SnapWheelSlots.decode(result[DefaultsKey.snapWheelSlots] as? String)
        suite.expect(slots[.top] == ["topHalf", "topThird", "topTwoThirds"], "a cycle comes over in order")
        suite.expect(slots[.topLeft] == ["topLeft"], "a single action comes over")
        suite.expect(slots[.center] == ["maximize", "center"], "macOS center is center")
        suite.expect(slots[.left] == SnapWheelSlots.defaults[.left], "a slot Loop doesn't set keeps its default")
        suite.expect(result[DefaultsKey.snapWheelPlacement] as? String == "pointer", "the ring follows the pointer")
        suite.expect(result[DefaultsKey.snapWheelCornerRadius] as? Double == 30, "the ring's corners come over")
        suite.expect(result[DefaultsKey.snapWheelThickness] as? Double == 10, "and its thickness")
        suite.expect(result[DefaultsKey.snapWheelColorMode] as? String == "gradient", "the gradient comes over")
        suite.expect(result[DefaultsKey.snapWheelColor] as? String == "#6E6E6E", "with its first color")
        suite.expect(result[DefaultsKey.snapWheelGradientColor] as? String == "#323232", "and its second")
        suite.expect(abs((result[DefaultsKey.snapWheelPreviewCornerRadius] as? Double ?? 0) - 19.81) < 0.01,
                     "text numbers are read")
        suite.expect(result[DefaultsKey.snapWheelPreviewMaterial] as? String == "frosted", "blur is frosted")
        suite.expect(result[DefaultsKey.snapWheelPreviewTint] as? Double == 0, "no tint stays none")
        suite.expect(result[DefaultsKey.snapWheelTarget] as? String == "focused", "the focused window")
        suite.expect(result[DefaultsKey.windowLayoutWindowGap] as? Int == 8, "a 10 pt gap lands on 8")
        suite.expect(result[DefaultsKey.windowLayoutScreenGap] as? Int == 0, "no edge padding stays none")
        suite.expect(SnapWheelLoopImport.preferences(from: [:]).isEmpty, "an empty Loop changes nothing")
        suite.expect(SnapWheelLoopImport.actions(fromSlotJSON: #"{"direction":"MoveToSpace3"}"#) == [],
                     "an action without a counterpart is left out")
    }
}
