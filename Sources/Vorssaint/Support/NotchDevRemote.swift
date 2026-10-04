// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

#if VORSSAINT_DEVELOPMENT
import Foundation

/// Developer builds only: drives the island from outside the app, so its
/// pages can be captured without a hand on the pointer. Post
/// `com.vorssaint.dev.notch` with an object of `open`, `home`, `collapse`,
/// `sections` or a section's raw value.
enum NotchDevRemote {
    static func install() {
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.vorssaint.dev.notch"), object: nil, queue: .main) { note in
            let service = NotchService.shared
            switch note.object as? String ?? "open" {
            case "open": service.open(pinned: true)
            case "home": service.open(pinned: true); service.showHome()
            case "collapse": service.collapse()
            case "sections": service.open(pinned: true); service.toggleSections()
            case let raw:
                if let module = NotchModule(rawValue: raw) { service.open(module, pinned: true) }
            }
        }
    }
}
#endif
