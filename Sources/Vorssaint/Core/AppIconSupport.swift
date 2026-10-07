// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

// Fork: App Icons, in the spirit of Replacicon. Every app on the Mac in one
// grid; drop a picture on one to make it that app's icon, or give it a dark
// version of its own. The picture is kept here, so when an update replaces
// the app and its custom icon with it, the icon is put back. Records and the
// rules about which apps can change live here, where the tests compile them;
// the file work is in Services/AppIcons.

extension DefaultsKey {
    /// Watch customized apps and put their icon back after an update.
    static let appIconsEnabled = "appIconsEnabled"
    /// JSON list of `AppIconRecord`.
    static let appIconsRecords = "appIconsRecords"
}

struct AppIconRecord: Codable, Equatable, Identifiable {
    enum Style: String, Codable {
        /// A picture the person chose.
        case custom
        /// The app's own icon in the dark style.
        case dark
    }

    var bundleID: String
    /// Where the app was when its icon was set; an app that moved is found
    /// again by bundle identifier.
    var path: String
    var style: Style
    var appliedAt: Date
    /// How many times the icon was put back after an update.
    var restores: Int = 0

    var id: String { bundleID }

    /// The stored picture's file name.
    var iconFileName: String { AppIconSupport.fileName(for: bundleID) }
}

enum AppIconSupport {
    static let title = "App Icons"
    static let hubDescription = "Every app on your Mac in one place. Drop a picture on an app to change its icon, or make it dark. Custom icons come back after an app updates."

    static let registeredDefaults: [String: Any] = [
        DefaultsKey.appIconsEnabled: true,
    ]

    /// Folders scanned for apps, home first so a personal copy wins.
    static func searchFolders(home: String = NSHomeDirectory()) -> [String] {
        [home + "/Applications", "/Applications", "/Applications/Utilities", "/Applications/Setapp"]
    }

    /// Apple's own apps live on the sealed system volume: their icons cannot
    /// change at all.
    static func isProtected(path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        return standardized.hasPrefix("/System/") || standardized.hasPrefix("/Library/Apple/")
    }

    /// A file name safe for any bundle identifier.
    static func fileName(for bundleID: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let cleaned = String(bundleID.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
        return (cleaned.isEmpty ? "app" : cleaned) + ".png"
    }

    static func decode(_ raw: String?) -> [AppIconRecord] {
        guard let raw, let data = raw.data(using: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? decoder.decode([AppIconRecord].self, from: data)) ?? []
    }

    static func encode(_ records: [AppIconRecord]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(records.sorted { $0.bundleID < $1.bundleID }) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    static func records(in defaults: UserDefaults = .standard) -> [AppIconRecord] {
        decode(defaults.string(forKey: DefaultsKey.appIconsRecords))
    }

    /// Adds or replaces the record for its app.
    static func upserting(_ record: AppIconRecord, into records: [AppIconRecord]) -> [AppIconRecord] {
        records.filter { $0.bundleID != record.bundleID } + [record]
    }

    /// What has to happen to one customized app, given what is on disk.
    enum Reconciliation: Equatable {
        /// Its custom icon is still there.
        case intact
        /// Updated or reinstalled: the icon has to go back on.
        case reapply(path: String)
        /// The app is gone; the record waits in case it comes back.
        case missing
    }

    static func reconcile(_ record: AppIconRecord,
                          exists: (String) -> Bool,
                          hasCustomIcon: (String) -> Bool,
                          locate: (String) -> String?) -> Reconciliation {
        let path = exists(record.path) ? record.path : locate(record.bundleID)
        guard let path else { return .missing }
        return hasCustomIcon(path) && path == record.path ? .intact : .reapply(path: path)
    }

    /// The shell command that puts a custom icon file (made by
    /// `NSWorkspace.setIcon` on a scratch folder) onto an app that needs an
    /// administrator to change, and marks the app as having one.
    static func adminInstallCommand(iconFile: String, appPath: String) -> String {
        let target = appPath + "/Icon\r"
        return "/bin/cp \(quoted(iconFile)) \(quoted(target))"
            + " && /usr/bin/xattr -wx com.apple.FinderInfo \(finderInfoCustomIcon) \(quoted(appPath))"
            + " && /usr/bin/touch \(quoted(appPath))"
    }

    static func adminRemoveCommand(appPath: String) -> String {
        "/bin/rm -f \(quoted(appPath + "/Icon\r"))"
            + " ; /usr/bin/xattr -d com.apple.FinderInfo \(quoted(appPath)) 2>/dev/null"
            + " ; /usr/bin/touch \(quoted(appPath))"
    }

    /// Finder info with only the "has custom icon" flag set (0x0400 at byte 8).
    static let finderInfoCustomIcon = "00000000000000000400000000000000" + "00000000000000000000000000000000"

    /// Single-quoted for /bin/sh, safe for any path.
    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
