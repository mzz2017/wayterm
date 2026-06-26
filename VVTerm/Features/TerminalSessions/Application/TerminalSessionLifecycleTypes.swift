//
//  TerminalSessionLifecycleTypes.swift
//  VVTerm
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
