//
//  SSHTerminalWrapper.swift
//  VVTerm
//
//  SwiftUI wrapper for Ghostty terminal with SSH connections
//

import SwiftUI
import Foundation
import os.log

// MARK: - SSH Terminal Coordinator Protocol

/// Protocol for shared SSH terminal coordinator functionality across platforms
@MainActor
protocol SSHTerminalCoordinator: AnyObject {
    var server: Server { get }
    var credentials: ServerCredentials { get }
    var sessionId: UUID { get }
    var onProcessExit: () -> Void { get }
    var terminalView: GhosttyTerminalView? { get set }
    var logger: Logger { get }
}

extension SSHTerminalCoordinator {
    func sendToSSH(_ data: Data) {
        Task(priority: .userInitiated) { [sessionId] in
            await ConnectionSessionManager.shared.sendInput(data, to: sessionId)
        }
    }

    func attachSurface(_ terminal: GhosttyTerminalView) {
        Task { [sessionId] in
            await ConnectionSessionManager.shared.attachSurface(terminal, to: sessionId)
        }
    }
}

#if os(macOS)
import AppKit

// MARK: - SSH Terminal Wrapper

struct SSHTerminalWrapper: NSViewRepresentable {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    var isActive: Bool = true
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    @EnvironmentObject var ghosttyApp: Ghostty.App

    func makeCoordinator() -> Coordinator {
        return Coordinator(
            server: server,
            credentials: credentials,
            sessionId: session.id,
            onProcessExit: onProcessExit,
            richPasteUIModel: richPasteUIModel
        )
    }

    func makeNSView(context: Context) -> NSView {
        // Ensure Ghostty app is ready
        guard let app = ghosttyApp.app else {
            return NSView(frame: .zero)
        }

        let coordinator = context.coordinator
        ConnectionSessionManager.shared.configureRuntime(
            for: session.id,
            server: server,
            credentials: credentials,
            onProcessExit: onProcessExit
        )

        // Check if terminal already exists for this session (reuse to save memory)
        // Each Ghostty surface uses ~50-100MB (font atlas, Metal textures, scrollback)
        if let existingTerminal = ConnectionSessionManager.shared.getTerminal(for: session.id) {
            // Mark coordinator as reusing existing terminal - don't cleanup on deinit
            coordinator.isReusingTerminal = true
            coordinator.terminalView = existingTerminal

            // Update callbacks because the SwiftUI coordinator can be recreated
            // while the application-owned runtime stays alive.
            existingTerminal.onResize = { [session] cols, rows in
                guard cols > 0 && rows > 0 else { return }
                Task {
                    await ConnectionSessionManager.shared.resizeSession(session.id, cols: cols, rows: rows)
                }
            }
            existingTerminal.onPwdChange = { [sessionId = session.id] rawDirectory in
                ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
            }
            existingTerminal.onTitleChange = { [sessionId = session.id] title in
                ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
            }
            existingTerminal.onZoomAction = { [sessionId = session.id] action in
                ConnectionSessionManager.shared.handleTerminalZoom(action, for: sessionId)
            }
            existingTerminal.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))
            existingTerminal.writeCallback = { [weak coordinator] data in
                coordinator?.sendToSSH(data)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)

            // Re-wrap in scroll view
            let scrollView = TerminalScrollView(
                contentSize: NSSize(width: 800, height: 600),
                surfaceView: existingTerminal
            )

            // Terminal is already ready - call onReady immediately
            // Use async to avoid calling during view construction
            DispatchQueue.main.async {
                onReady()
                let shellMissing = ConnectionSessionManager.shared.shellId(for: session) == nil
                let shellStartInFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
                if shellMissing && !shellStartInFlight {
                    if ConnectionSessionManager.shared.consumeTerminalReconnectReset(for: session.id) {
                        existingTerminal.resetTerminalForReconnect()
                    }
                    coordinator.attachSurface(existingTerminal)
                }
            }

            return scrollView
        }

        // Create Ghostty terminal with custom I/O for SSH
        // Using useCustomIO: true means the terminal won't spawn a subprocess
        // Instead, it will use callbacks for I/O (for SSH via libssh2)
        let terminalView = GhosttyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: session.id.uuidString,
            useCustomIO: true  // Use callback backend for SSH
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            onReady()
            // Start SSH connection after terminal is ready
            if let terminalView = terminalView {
                coordinator?.attachSurface(terminalView)
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onPwdChange = { [sessionId = session.id] rawDirectory in
            ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
        }
        terminalView.onTitleChange = { [sessionId = session.id] title in
            ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
        }
        terminalView.onZoomAction = { [sessionId = session.id] action in
            ConnectionSessionManager.shared.handleTerminalZoom(action, for: sessionId)
        }
        terminalView.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))

        // Store terminal reference in coordinator and register with session manager
        coordinator.terminalView = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        ConnectionSessionManager.shared.registerTerminal(terminalView, for: session.id)

        // Setup write callback to send keyboard input to SSH
        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }

        // Setup resize callback to notify SSH of terminal size changes
        terminalView.onResize = { [sessionId = session.id] cols, rows in
            guard cols > 0 && rows > 0 else { return }
            Task {
                await ConnectionSessionManager.shared.resizeSession(sessionId, cols: cols, rows: rows)
            }
        }

        // Wrap in scroll view
        let scrollView = TerminalScrollView(
            contentSize: NSSize(width: 800, height: 600),
            surfaceView: terminalView
        )

        return scrollView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Check if session still exists - if not, cleanup and return
        let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == session.id }
        if !sessionExists {
            ConnectionSessionManager.shared.trackShellTeardownForClosedSession(
                sessionId: session.id,
                serverId: session.serverId,
                reason: "mac update missing session"
            ) {
                await ConnectionSessionManager.shared.detachSurface(from: session.id, reason: .sessionClosed)
            }
            return
        }

        if let scrollView = nsView as? TerminalScrollView {
            scrollView.shouldOwnFirstResponder = isActive
            let terminalView = scrollView.surfaceView
            if terminalView.surfacePresentationOverrides != ConnectionSessionManager.shared.presentationOverrides(for: session.id) {
                terminalView.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: SSHTerminalCoordinator {
        let server: Server
        let credentials: ServerCredentials
        let sessionId: UUID
        let onProcessExit: () -> Void
        weak var terminalView: GhosttyTerminalView?

        private let richPasteRuntime: TerminalRichPasteRuntime
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHTerminal")

        /// If true, this coordinator is reusing an existing terminal and should NOT cleanup on deinit
        var isReusingTerminal = false

        init(
            server: Server,
            credentials: ServerCredentials,
            sessionId: UUID,
            onProcessExit: @escaping () -> Void,
            richPasteUIModel: TerminalRichPasteUIModel
        ) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
            self.richPasteRuntime = .connectionSession(
                sessionId: sessionId,
                uiModel: richPasteUIModel
            )
        }

        @MainActor
        func installRichPasteInterception(on terminal: GhosttyTerminalView) {
            richPasteRuntime.install(on: terminal)
        }

        deinit {
            // Don't cleanup if we're just reusing an existing terminal (e.g., switching to split view)
            // isReusingTerminal is set when we find an existing terminal in makeNSView
            guard !isReusingTerminal else { return }

            // Check if terminal view is still alive (session manager holds strong reference)
            // If it is, the terminal is being reused by another view (e.g., split view)
            guard terminalView == nil else { return }

            let sessionId = self.sessionId
            let serverId = self.server.id
            Task { @MainActor in
                ConnectionSessionManager.shared.trackShellTeardownForClosedSession(
                    sessionId: sessionId,
                    serverId: serverId,
                    reason: "mac coordinator deinit"
                ) {
                    await ConnectionSessionManager.shared.detachSurface(from: sessionId, reason: .sessionClosed)
                }
            }
        }
    }
}

#else
// MARK: - iOS SSH Terminal Wrapper

import UIKit
import SwiftUI

/// SwiftUI wrapper that uses GeometryReader to get proper size (matches official Ghostty pattern)
struct SSHTerminalWrapper: View {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    var isActive: Bool = true
    var shouldPreserveKeyboardDuringReconnect: Bool = false
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            SSHTerminalRepresentable(
                session: session,
                server: server,
                credentials: credentials,
                richPasteUIModel: richPasteUIModel,
                size: geo.size,
                isActive: isActive,
                shouldPreserveKeyboardDuringReconnect: shouldPreserveKeyboardDuringReconnect,
                onProcessExit: onProcessExit,
                onReady: onReady,
                onVoiceTrigger: onVoiceTrigger
            )
        }
    }
}

/// The actual UIViewRepresentable that receives size from GeometryReader
private struct SSHTerminalRepresentable: UIViewRepresentable {
    let session: ConnectionSession
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let size: CGSize
    var isActive: Bool = true
    var shouldPreserveKeyboardDuringReconnect: Bool = false
    let onProcessExit: () -> Void
    let onReady: () -> Void
    var onVoiceTrigger: (() -> Void)? = nil

    @EnvironmentObject var ghosttyApp: Ghostty.App
    @Environment(\.scenePhase) private var scenePhase

    func makeCoordinator() -> Coordinator {
        return Coordinator(
            server: server,
            credentials: credentials,
            sessionId: session.id,
            onProcessExit: onProcessExit,
            richPasteUIModel: richPasteUIModel
        )
    }

    func makeUIView(context: Context) -> UIView {
        guard let app = ghosttyApp.app else {
            return UIView(frame: .zero)
        }

        let coordinator = context.coordinator
        ConnectionSessionManager.shared.configureRuntime(
            for: session.id,
            server: server,
            credentials: credentials,
            onProcessExit: onProcessExit
        )

        // Check if terminal already exists for this session (reuse to save memory)
        if let existingTerminal = ConnectionSessionManager.shared.peekTerminal(for: session.id) {
            ConnectionSessionManager.shared.markTerminalUsed(for: session.id)
            coordinator.terminalView = existingTerminal
            coordinator.isTerminalReady = true
            coordinator.preserveSession = true
            existingTerminal.onVoiceButtonTapped = onVoiceTrigger
            existingTerminal.onProcessExit = onProcessExit
            existingTerminal.onPwdChange = { [sessionId = session.id] rawDirectory in
                DispatchQueue.main.async {
                    ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
                }
            }
            existingTerminal.onTitleChange = { [sessionId = session.id] title in
                ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
            }
            existingTerminal.onZoomAction = { [sessionId = session.id] action in
                ConnectionSessionManager.shared.handleTerminalZoom(action, for: sessionId)
            }
            existingTerminal.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))

            // Route UI input intent through the application-owned runtime.
            existingTerminal.writeCallback = { [weak coordinator] data in
                coordinator?.sendToSSH(data)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)
            existingTerminal.onResize = { [session] cols, rows in
                guard cols > 0 && rows > 0 else { return }
                Task {
                    await ConnectionSessionManager.shared.resizeSession(session.id, cols: cols, rows: rows)
                }
            }

            if size.width > 0 && size.height > 0 {
                coordinator.lastReportedSize = size
                existingTerminal.frame = CGRect(origin: .zero, size: size)
                existingTerminal.sizeDidChange(size)
            }

            DispatchQueue.main.async {
                onReady()
                let shellMissing = ConnectionSessionManager.shared.shellId(for: session) == nil
                let shellStartInFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
                if shellMissing,
                   !shellStartInFlight,
                   UIApplication.shared.applicationState == .active,
                   !ConnectionSessionManager.shared.isSuspendingForBackground {
                    if ConnectionSessionManager.shared.consumeTerminalReconnectReset(for: session.id) {
                        existingTerminal.resetTerminalForReconnect()
                    }
                    coordinator.attachSurface(existingTerminal)
                }
            }
            return terminalHostView(for: existingTerminal)
        }

        let initialSize = (size.width > 0 && size.height > 0) ? size : CGSize(width: 800, height: 600)
        let terminalView = GhosttyTerminalView(
            frame: CGRect(origin: .zero, size: initialSize),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: session.id.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            coordinator?.isTerminalReady = true
            DispatchQueue.main.async {
                onReady()
                if let terminalView = terminalView,
                   UIApplication.shared.applicationState == .active,
                   !ConnectionSessionManager.shared.isSuspendingForBackground {
                    coordinator?.attachSurface(terminalView)
                }
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onVoiceButtonTapped = onVoiceTrigger
        terminalView.onPwdChange = { [sessionId = session.id] rawDirectory in
            DispatchQueue.main.async {
                ConnectionSessionManager.shared.updateSessionWorkingDirectory(sessionId, rawDirectory: rawDirectory)
            }
        }
        terminalView.onTitleChange = { [sessionId = session.id] title in
            ConnectionSessionManager.shared.updateSessionTitle(sessionId, rawTitle: title)
        }
        terminalView.onZoomAction = { [sessionId = session.id] action in
            ConnectionSessionManager.shared.handleTerminalZoom(action, for: sessionId)
        }
        terminalView.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))

        coordinator.terminalView = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        ConnectionSessionManager.shared.registerTerminal(terminalView, for: session.id)

        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }
        terminalView.onResize = { [session] cols, rows in
            guard cols > 0 && rows > 0 else { return }
            Task {
                await ConnectionSessionManager.shared.resizeSession(session.id, cols: cols, rows: rows)
            }
        }

        coordinator.lastReportedSize = initialSize
        if size.width > 0 && size.height > 0 {
            terminalView.sizeDidChange(size)
        }
        if !isActive {
            terminalView.pauseRendering()
        }

        return terminalHostView(for: terminalView)
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let nativeScrollContainer = uiView as? TerminalNativeScrollContainerView
        guard let terminalView = Self.terminalView(from: uiView) else {
            return
        }

        // Check if session still exists - if not, cleanup and return
        let sessionExists = ConnectionSessionManager.shared.sessions.contains { $0.id == session.id }
        if !sessionExists {
            // Session was closed externally, cleanup terminal
            ConnectionSessionManager.shared.trackShellTeardownForClosedSession(
                sessionId: session.id,
                serverId: session.serverId,
                reason: "ios update missing session"
            ) {
                await ConnectionSessionManager.shared.detachSurface(from: session.id, reason: .sessionClosed)
            }
            terminalView.writeCallback = nil
            terminalView.onReady = nil
            terminalView.onProcessExit = nil
            return
        }

        let wasActive = context.coordinator.wasActive
        let shouldRenderTerminal = isActive && scenePhase == .active

        terminalView.onVoiceButtonTapped = onVoiceTrigger
        if terminalView.surfacePresentationOverrides != ConnectionSessionManager.shared.presentationOverrides(for: session.id) {
            terminalView.applyPresentationOverrides(ConnectionSessionManager.shared.presentationOverrides(for: session.id))
        }
        if size.width > 0, size.height > 0, size != context.coordinator.lastReportedSize {
            context.coordinator.lastReportedSize = size
            terminalView.sizeDidChange(size)
            nativeScrollContainer?.setNeedsLayout()
            nativeScrollContainer?.refreshNativeScrollState()
        }

        if context.coordinator.isTerminalReady {
            if shouldRenderTerminal && !wasActive {
                terminalView.resumeRendering()
                terminalView.forceRefresh()
            } else if !shouldRenderTerminal && wasActive {
                terminalView.pauseRendering()
            }
        }
        context.coordinator.wasActive = shouldRenderTerminal

        let autoReconnectEnabled = (UserDefaults.standard.object(forKey: "sshAutoReconnect") as? Bool) ?? true
        let shellMissing = ConnectionSessionManager.shared.shellId(for: session) == nil
        let shellStartInFlight = ConnectionSessionManager.shared.isShellStartInFlight(for: session.id)
        let shouldRestoreKeyboardFocus =
            shouldPreserveKeyboardDuringReconnect
            && session.connectionState.isConnecting
            && terminalView.shouldRestoreKeyboardFocusOnReconnect
        let shouldKeepExistingKeyboardFocus = terminalView.isFirstResponder && shouldRestoreKeyboardFocus
        terminalView.acceptsTerminalInput = session.connectionState.isConnected
        let shouldStartSSHConnection: Bool = {
            switch session.connectionState {
            case .connecting, .reconnecting, .connected:
                return true
            case .disconnected:
                return isActive && autoReconnectEnabled
            case .failed, .idle:
                return false
            }
        }()
        if context.coordinator.isTerminalReady
            && shellMissing
            && !shellStartInFlight
            && shouldStartSSHConnection
            && scenePhase == .active
            && !ConnectionSessionManager.shared.isSuspendingForBackground {
            let coordinator = context.coordinator
            DispatchQueue.main.async { [weak terminalView] in
                guard let terminalView else { return }
                guard ConnectionSessionManager.shared.sessions.contains(where: { $0.id == session.id }) else { return }
                guard ConnectionSessionManager.shared.shellId(for: session) == nil else { return }
                guard !ConnectionSessionManager.shared.isShellStartInFlight(for: session.id) else { return }
                if ConnectionSessionManager.shared.consumeTerminalReconnectReset(for: session.id) {
                    terminalView.resetTerminalForReconnect()
                }
                coordinator.attachSurface(terminalView)
            }
        }

        // Keep the terminal from reclaiming focus while an overlay (for example
        // the disconnected card) should be interactive above it.
        if shouldRenderTerminal && context.coordinator.isTerminalReady {
            let focusReason: TerminalKeyboardFocusReason?
            if shouldRestoreKeyboardFocus {
                focusReason = .reconnectRestore
            } else if session.connectionState.isConnected && terminalView.allowsAutomaticKeyboardFocus {
                focusReason = .initialActivation
            } else {
                focusReason = nil
            }

            if let focusReason, terminalView.window != nil && !terminalView.isFirstResponder {
                terminalView.requestKeyboardFocus(for: focusReason)
            }
        } else if scenePhase == .active
            && terminalView.isFirstResponder
            && !shouldKeepExistingKeyboardFocus {
            _ = terminalView.resignFirstResponder()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        guard let terminalView = terminalView(from: uiView) else { return }

        // Check if session still exists - if it does, user just navigated away
        // Keep terminal alive for when they come back
        let sessionStillExists = ConnectionSessionManager.shared.sessions.contains { $0.id == coordinator.sessionId }

        if sessionStillExists {
            // Session still active - user just navigated away
            // Pause rendering but keep everything alive
            terminalView.pauseRendering()
            _ = terminalView.resignFirstResponder()

            // Mark coordinator to not cleanup in deinit
            // IMPORTANT: Do NOT set terminalView = nil here!
            // The SSH output loop checks terminalView != nil to continue running.
            // Setting it to nil would break the loop and close the connection.
            coordinator.preserveSession = true
            Task {
                await ConnectionSessionManager.shared.detachSurface(from: coordinator.sessionId, reason: .viewDisappeared)
            }
            return
        }

        // Session was closed - full cleanup
        coordinator.terminalView = nil
        ConnectionSessionManager.shared.trackShellTeardownForClosedSession(
            sessionId: coordinator.sessionId,
            serverId: coordinator.server.id,
            reason: "ios dismantle closed session"
        ) {
            await ConnectionSessionManager.shared.detachSurface(from: coordinator.sessionId, reason: .sessionClosed)
        }
    }

    private func terminalHostView(for terminalView: GhosttyTerminalView) -> UIView {
        guard TerminalNativeScrollContainerView.isEnabled else {
            TerminalNativeScrollContainerView.detachExistingContainer(containing: terminalView)
            terminalView.setNativeHostScrollContainerEnabled(false)
            return terminalView
        }
        return TerminalNativeScrollContainerView(terminalView: terminalView)
    }

    private static func terminalView(from uiView: UIView) -> GhosttyTerminalView? {
        if let terminalView = uiView as? GhosttyTerminalView {
            return terminalView
        }
        if let container = uiView as? TerminalNativeScrollContainerView {
            return container.terminalView
        }
        return nil
    }

    // MARK: - Coordinator

    class Coordinator: SSHTerminalCoordinator {
        let server: Server
        let credentials: ServerCredentials
        let sessionId: UUID
        let onProcessExit: () -> Void
        weak var terminalView: GhosttyTerminalView?

        private let richPasteRuntime: TerminalRichPasteRuntime
        let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "VVTerm", category: "SSHTerminal")

        /// Tracks whether the terminal surface has been created and is ready for interaction
        var isTerminalReady = false

        /// If true, session is still active and we shouldn't cleanup on deinit (user just navigated away)
        var preserveSession = false
        var wasActive = false
        var lastReportedSize: CGSize = .zero

        init(
            server: Server,
            credentials: ServerCredentials,
            sessionId: UUID,
            onProcessExit: @escaping () -> Void,
            richPasteUIModel: TerminalRichPasteUIModel
        ) {
            self.server = server
            self.credentials = credentials
            self.sessionId = sessionId
            self.onProcessExit = onProcessExit
            self.richPasteRuntime = .connectionSession(
                sessionId: sessionId,
                uiModel: richPasteUIModel
            )
        }

        @MainActor
        func installRichPasteInterception(on terminal: GhosttyTerminalView) {
            richPasteRuntime.install(on: terminal)
        }

        deinit {
            // Don't cleanup if session is still active (user just navigated away)
            guard !preserveSession else { return }
            let sessionId = self.sessionId
            let serverId = self.server.id
            Task { @MainActor in
                ConnectionSessionManager.shared.trackShellTeardownForClosedSession(
                    sessionId: sessionId,
                    serverId: serverId,
                    reason: "ios coordinator deinit"
                ) {
                    await ConnectionSessionManager.shared.detachSurface(from: sessionId, reason: .sessionClosed)
                }
            }
        }
    }
}
#endif
