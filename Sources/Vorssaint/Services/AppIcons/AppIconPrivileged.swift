// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation
import Security

/// Fork: runs App Icons' administrator commands as a child of Vorssaint.
///
/// Writing inside an app owned by the system needs root, and App Management
/// only lets it through when the write is credited to an app the person
/// allowed. `do shell script … with administrator privileges` from an
/// osascript process is refused even with Vorssaint allowed, and the
/// in-process AppleScript route holds the main thread while macOS asks its
/// questions. Authorization Services' execute call starts the command as
/// Vorssaint's own child, from any thread, with the system's password
/// dialog. It is deprecated but still the documented way to do exactly
/// this without installing a helper, so it is looked up at run time.
enum AppIconPrivileged {
    private typealias Execute = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private static let execute: Execute? = {
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW),
              let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(symbol, to: Execute.self)
    }()

    static var isAvailable: Bool { execute != nil }

    enum Outcome: Equatable {
        case finished
        case cancelled
        case failed(OSStatus)
    }

    /// Asks for an administrator (showing `prompt`), runs `command` with
    /// /bin/sh as root and waits for it to finish. Call off the main thread.
    static func run(_ command: String, prompt: String) -> Outcome {
        guard let execute else { return .failed(errAuthorizationInternal) }
        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization else { return .failed(errAuthorizationInternal) }
        defer { AuthorizationFree(authorization, [.destroyRights]) }

        let status: OSStatus = kAuthorizationRightExecute.withCString { rightName in
            prompt.withCString { promptText in
                var right = AuthorizationItem(name: rightName, valueLength: 0, value: nil, flags: 0)
                var promptItem = AuthorizationItem(name: kAuthorizationEnvironmentPrompt,
                                                   valueLength: strlen(promptText),
                                                   value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                return withUnsafeMutablePointer(to: &right) { rightPointer in
                    withUnsafeMutablePointer(to: &promptItem) { promptPointer in
                        var rights = AuthorizationRights(count: 1, items: rightPointer)
                        var environment = AuthorizationEnvironment(count: 1, items: promptPointer)
                        return AuthorizationCopyRights(authorization, &rights, &environment,
                                                       [.interactionAllowed, .extendRights, .preAuthorize], nil)
                    }
                }
            }
        }
        if status == errAuthorizationCanceled { return .cancelled }
        guard status == errAuthorizationSuccess else { return .failed(status) }

        var pipe: UnsafeMutablePointer<FILE>?
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("-c"), strdup(command), nil]
        defer { arguments.forEach { free($0) } }
        let started = arguments.withUnsafeBufferPointer { buffer in
            execute(authorization, "/bin/sh", [], buffer.baseAddress!, &pipe)
        }
        guard started == errAuthorizationSuccess else { return .failed(started) }
        // The command's output closes when it exits: reading to the end is
        // waiting for it.
        if let pipe {
            var buffer = [CChar](repeating: 0, count: 256)
            while fgets(&buffer, Int32(buffer.count), pipe) != nil {}
            fclose(pipe)
        }
        return .finished
    }
}
