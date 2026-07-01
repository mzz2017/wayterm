//
//  TerminalSessionLifecycleTypes.swift
//  Waterm
//
//  Shared lifecycle value types for terminal session orchestration.
//

import Foundation

enum ShellTeardownMode: Equatable, Sendable {
    case closeShellOnly
    case fullDisconnect
}

enum TerminalSurfaceDetachReason: Equatable, Sendable {
    case viewDisappeared
    case sessionClosed
}

enum TerminalSurfaceViewDisappearanceResolution: Equatable, Sendable {
    case preservedForReuse
    case closedAndCleanedUp
    case staleSurfaceIgnored
}

enum TerminalSurfaceUpdateDisposition: Equatable, Sendable {
    case continueUpdating
    case closedAndCleanedUp
}

struct TerminalSurfaceAttachContext: Equatable, Sendable {
    var isAppActive: Bool
    var isViewActive: Bool
    var autoReconnectEnabled: Bool

    static let active = TerminalSurfaceAttachContext(
        isAppActive: true,
        isViewActive: true,
        autoReconnectEnabled: true
    )
}

struct TerminalResizeRequestSize: Equatable, Sendable {
    let cols: Int
    let rows: Int

    var isValid: Bool {
        cols > 0 && rows > 0
    }
}
