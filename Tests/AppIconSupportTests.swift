// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

/// Fork: App Icons. Records round-trip, an update is noticed and an app
/// that moved is found again, the administrator commands quote any path,
/// and the dark style finds a background, keeps a glyph readable, leaves a
/// dark icon alone and dims a busy one.
enum AppIconSupportTests {
    static func run(_ suite: TestSuite) {
        records(suite)
        reconcile(suite)
        commands(suite)
        styler(suite)
        backup(suite)
    }

    /// Every fork setting travels in a settings backup, App Icons with its
    /// pictures, and an older backup leaves the fork settings alone.
    private static func backup(_ suite: TestSuite) {
        let exported = SettingsBackupSupport.exportKeys()
        suite.expect(exported.isSuperset(of: SettingsBackupSupport.forkPreferenceKeys),
                     "workspaces, wheel slots, island tabs, mouse shortcuts and icons are exported")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let payload = SettingsBackupSupport.payload(
            appVersion: "test", appIconImages: ["md.obsidian": png, "bad": Data([1, 2])]) { key in
            key == DefaultsKey.workspacesDefinitions ? "[]" : nil
        }
        let restored = SettingsBackupSupport.sanitizedSettings(from: payload) ?? [:]
        suite.expect(restored[DefaultsKey.workspacesDefinitions] as? String == "[]", "workspaces round-trip")
        suite.expect(restored[SettingsBackupSupport.appIconImagesKey] as? [String: Data] == ["md.obsidian": png],
                     "icon pictures round-trip and anything not a PNG is dropped")
        suite.expect(SettingsBackupSupport.keysToClear(whenImporting: restored)
                        .contains(DefaultsKey.snapWheelSlots),
                     "a current backup replaces the wheel slots")
        var older = payload
        older.removeValue(forKey: SettingsBackupSupport.forkVersionKey)
        let olderSettings = SettingsBackupSupport.sanitizedSettings(from: older) ?? [:]
        suite.expect(SettingsBackupSupport.keysToClear(whenImporting: olderSettings)
                        .isDisjoint(with: SettingsBackupSupport.forkPreferenceKeys),
                     "an older backup keeps this Mac's fork settings")
    }

    private static func records(_ suite: TestSuite) {
        let first = AppIconRecord(bundleID: "com.tinyspeck.slackmacgap", path: "/Applications/Slack.app",
                                  style: .dark, appliedAt: Date(timeIntervalSince1970: 1_000))
        let second = AppIconRecord(bundleID: "md.obsidian", path: "/Applications/Obsidian.app",
                                   style: .custom, appliedAt: Date(timeIntervalSince1970: 2_000), restores: 3)
        let encoded = AppIconSupport.encode([second, first])
        suite.expect(AppIconSupport.decode(encoded) == [first, second], "records round-trip, sorted")
        suite.expect(AppIconSupport.decode("garbage").isEmpty, "damaged storage reads as none")
        var replaced = first
        replaced.style = .custom
        suite.expect(AppIconSupport.upserting(replaced, into: [first, second]) == [second, replaced],
                     "setting an icon again replaces the app's record")
        suite.expect(AppIconSupport.fileName(for: "com.example.App") == "com.example.App.png", "a plain id is its name")
        suite.expect(AppIconSupport.fileName(for: "a/b c") == "a_b_c.png", "unsafe characters are replaced")
        suite.expect(AppIconSupport.isProtected(path: "/System/Applications/Mail.app"), "Apple's apps are sealed")
        suite.expect(AppIconSupport.isProtected(
            path: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"), "Safari too")
        suite.expect(!AppIconSupport.isProtected(path: "/Applications/Slack.app"), "other apps can change")
        suite.expect(AppIconSupport.searchFolders(home: "/Users/me").first == "/Users/me/Applications",
                     "the personal folder comes first")
    }

    private static func reconcile(_ suite: TestSuite) {
        let record = AppIconRecord(bundleID: "com.example", path: "/Applications/Example.app", style: .custom,
                                   appliedAt: Date())
        func outcome(exists: Set<String>, custom: Set<String>, located: String?) -> AppIconSupport.Reconciliation {
            AppIconSupport.reconcile(record, exists: { exists.contains($0) }, hasCustomIcon: { custom.contains($0) },
                                     locate: { _ in located })
        }
        suite.expect(outcome(exists: [record.path], custom: [record.path], located: nil) == .intact,
                     "an icon still in place needs nothing")
        suite.expect(outcome(exists: [record.path], custom: [], located: nil) == .reapply(path: record.path),
                     "an update that took the icon puts it back")
        suite.expect(outcome(exists: ["/Applications/Utilities/Example.app"], custom: ["/Applications/Utilities/Example.app"],
                             located: "/Applications/Utilities/Example.app")
                        == .reapply(path: "/Applications/Utilities/Example.app"),
                     "an app that moved is followed, and its record with it")
        suite.expect(outcome(exists: [], custom: [], located: nil) == .missing, "a removed app is left waiting")
    }

    private static func commands(_ suite: TestSuite) {
        suite.expect(AppIconSupport.quoted("/Applications/Bob's App.app") == "'/Applications/Bob'\\''s App.app'",
                     "a quote in a path is escaped")
        let install = AppIconSupport.adminInstallCommand(iconFile: "/tmp/x/Icon\r", appPath: "/Applications/A B.app")
        suite.expect(install.contains("'/Applications/A B.app/Icon\r'"), "the icon file lands inside the app")
        suite.expect(install.contains("com.apple.FinderInfo " + AppIconSupport.finderInfoCustomIcon),
                     "the app is flagged as having a custom icon")
        suite.expect(AppIconSupport.finderInfoCustomIcon.count == 64, "Finder info is 32 bytes")
        suite.expect(AppIconSupport.adminRemoveCommand(appPath: "/Applications/A.app").hasPrefix("/bin/rm -f '/Applications/A.app/Icon\r'"),
                     "restoring removes the icon file")
    }

    // MARK: - The dark style

    /// A size × size tile: rounded square of `background`, a centered square
    /// of `glyph` covering the middle third.
    private static func tile(size: Int = 120, background: (Int, Int, Int), glyph: (Int, Int, Int),
                             gradient: Int = 0) -> AppIconBitmap {
        var bitmap = AppIconBitmap(width: size, height: size)
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        for y in 0..<size {
            for x in 0..<size {
                let i = (y * size + x) * 4
                guard AppIconStyler.isInsideRoundedRect(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5), rect: rect,
                                                        radius: CGFloat(size) * 0.22) else { continue }
                let inGlyph = (size / 3..<size * 2 / 3).contains(x) && (size / 3..<size * 2 / 3).contains(y)
                let shade = gradient * y / size
                let color = inGlyph ? glyph : (background.0 + shade, background.1 + shade, background.2 + shade)
                bitmap.pixels[i] = UInt8(min(255, color.0))
                bitmap.pixels[i + 1] = UInt8(min(255, color.1))
                bitmap.pixels[i + 2] = UInt8(min(255, color.2))
                bitmap.pixels[i + 3] = 255
            }
        }
        return bitmap
    }

    private static func value(_ p: (r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Int { Int(max(p.r, p.g, p.b)) }

    private static func styler(_ suite: TestSuite) {
        // White tile, black glyph: the background goes dark, the glyph light.
        var light = tile(background: (250, 250, 250), glyph: (10, 10, 10))
        suite.expect(AppIconStyler.darkenTile(&light) == .background, "a calm background is found")
        suite.expect(value(light.pixel(20, 60)) < 80, "the light background turns dark")
        suite.expect(value(light.pixel(60, 60)) > 200, "the black glyph turns light so it still reads")
        suite.expect(light.pixel(0, 0).a == 0, "transparent corners stay transparent")

        // Colored glyph on white: the color is kept.
        var colored = tile(background: (245, 245, 245), glyph: (230, 40, 40))
        AppIconStyler.darkenTile(&colored)
        let red = colored.pixel(60, 60)
        suite.expect(red.r > 200 && red.g < 80, "a colored glyph keeps its color")

        // A gentle gradient is still one background.
        var gradient = tile(background: (120, 140, 220), glyph: (255, 255, 255), gradient: 40)
        suite.expect(AppIconStyler.darkenTile(&gradient) == .background, "a gradient is crossed")
        suite.expect(value(gradient.pixel(20, 100)) < 90 && value(gradient.pixel(60, 60)) > 240,
                     "the gradient goes dark under a white glyph that stays white")

        // Already dark: left as it is.
        let dark = tile(background: (20, 20, 24), glyph: (240, 120, 60))
        var kept = dark
        suite.expect(AppIconStyler.darkenTile(&kept) == .kept && kept == dark, "a dark icon is left alone")

        // A busy picture with no calm edge is dimmed whole.
        var noise = tile(background: (0, 0, 0), glyph: (0, 0, 0))
        var seed: UInt64 = 42
        for i in stride(from: 0, to: noise.pixels.count, by: 4) where noise.pixels[i + 3] > 0 {
            for c in 0..<3 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                noise.pixels[i + c] = UInt8(truncatingIfNeeded: seed >> 56) | 0x40
            }
        }
        let before = noise.pixel(30, 30)
        suite.expect(AppIconStyler.darkenTile(&noise) == .dimmed, "a busy picture is dimmed")
        suite.expect(value(noise.pixel(30, 30)) < value(before), "and comes out darker")

        // Tiles and shapes.
        let full = tile(background: (200, 200, 200), glyph: (0, 0, 0))
        let bounds = AppIconStyler.opaqueBounds(of: full)
        suite.expect(bounds == CGRect(x: 0, y: 0, width: 120, height: 120), "the bounds are the opaque area")
        suite.expect(bounds.map { AppIconStyler.kind(of: full, bounds: $0) } == .tile, "a filled rounded square is a tile")
        var dot = AppIconBitmap(width: 120, height: 120)
        for y in 0..<120 {
            for x in 0..<120 where hypot(Double(x) - 60, Double(y) - 60) < 50 {
                dot.pixels[(y * 120 + x) * 4 + 3] = 255
            }
        }
        suite.expect(AppIconStyler.opaqueBounds(of: dot).map { AppIconStyler.kind(of: dot, bounds: $0) } == .shape,
                     "a circle is a shape, given a tile of its own")
        let base = AppIconStyler.darkBase(for: (0.2, 0.4, 0.9), at: 0)
        suite.expect(max(base.r, base.g, base.b) < 0.3 && base.b > base.r, "the dark tile keeps a hint of the hue")
        let neutral = AppIconStyler.darkBase(for: (0.95, 0.95, 0.95), at: 1)
        suite.expect(abs(neutral.r - neutral.b) < 0.001, "a white background gives a neutral graphite")
    }
}
