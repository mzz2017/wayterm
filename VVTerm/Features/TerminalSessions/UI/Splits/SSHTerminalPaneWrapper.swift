//
//  SSHTerminalPaneWrapper.swift
//  VVTerm
//
//  Hosts a Ghostty terminal surface for a macOS split pane.
//

#if os(macOS)
import SwiftUI
import AppKit
import Foundation

/// Wraps SSH connection and Ghostty terminal for a pane.
struct SSHTerminalPaneWrapper: NSViewRepresentable {
    let paneId: UUID
    let server: Server
    let credentials: ServerCredentials
    let richPasteUIModel: TerminalRichPasteUIModel
    let tabManager: TerminalTabManager
    let isActive: Bool
    let autoReconnectEnabled: Bool
    let onProcessExit: () -> Void
    let onReady: () -> Void

    @EnvironmentObject var ghosttyApp: Ghostty.App

    private var surfaceAttachContext: TerminalSurfaceAttachContext {
        TerminalSurfaceAttachContext(
            isAppActive: true,
            isViewActive: isActive,
            autoReconnectEnabled: autoReconnectEnabled
        )
    }

    func makeNSView(context: Context) -> NSView {
        // Ensure Ghostty app is ready
        guard let app = ghosttyApp.app else {
            return NSView(frame: .zero)
        }

        let coordinator = context.coordinator
        tabManager.configureRuntime(
            forPane: paneId,
            server: server,
            credentials: credentials,
            onProcessExit: onProcessExit
        )

        // Check if terminal already exists for this pane (reuse to save memory)
        if let existingTerminal = tabManager.getTerminal(for: paneId) {
            coordinator.isReusingTerminal = true
            coordinator.terminal = existingTerminal

            existingTerminal.onResize = { [tabManager, paneId] cols, rows in
                tabManager.requestPaneResize(
                    TerminalResizeRequestSize(cols: cols, rows: rows),
                    forPane: paneId
                )
            }
            existingTerminal.onPwdChange = { [tabManager, paneId] rawDirectory in
                tabManager.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
            }
            existingTerminal.onTitleChange = { [tabManager, paneId] title in
                tabManager.updatePaneTitle(paneId, rawTitle: title)
            }
            existingTerminal.onZoomAction = { [tabManager, paneId] action in
                tabManager.handleTerminalZoom(action, for: paneId)
            }
            existingTerminal.applyPresentationOverrides(tabManager.presentationOverrides(for: paneId))
            existingTerminal.writeCallback = { [tabManager, paneId] data in
                tabManager.requestPaneInput(data, toPane: paneId)
            }
            coordinator.installRichPasteInterception(on: existingTerminal)

            // Re-wrap in scroll view
            let scrollView = TerminalScrollView(
                contentSize: NSSize(width: 800, height: 600),
                surfaceView: existingTerminal
            )

            DispatchQueue.main.async {
                onReady()
                coordinator.attachSurface(existingTerminal, context: surfaceAttachContext)
            }

            return scrollView
        }

        // Create Ghostty terminal with custom I/O for SSH
        let terminalView = GhosttyTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            worktreePath: NSHomeDirectory(),
            ghosttyApp: app,
            appWrapper: ghosttyApp,
            paneId: paneId.uuidString,
            useCustomIO: true
        )

        terminalView.onReady = { [weak coordinator, weak terminalView] in
            onReady()
            if let terminalView = terminalView {
                coordinator?.attachSurface(terminalView, context: surfaceAttachContext)
            }
        }
        terminalView.onProcessExit = onProcessExit
        terminalView.onPwdChange = { [tabManager, paneId] rawDirectory in
            tabManager.updatePaneWorkingDirectory(paneId, rawDirectory: rawDirectory)
        }
        terminalView.onTitleChange = { [tabManager, paneId] title in
            tabManager.updatePaneTitle(paneId, rawTitle: title)
        }
        terminalView.onZoomAction = { [tabManager, paneId] action in
            tabManager.handleTerminalZoom(action, for: paneId)
        }
        terminalView.applyPresentationOverrides(tabManager.presentationOverrides(for: paneId))

        // Store terminal reference
        coordinator.terminal = terminalView
        coordinator.installRichPasteInterception(on: terminalView)
        tabManager.registerTerminal(terminalView, for: paneId)

        // Setup write callback to send keyboard input to SSH
        terminalView.writeCallback = { [weak coordinator] data in
            coordinator?.sendToSSH(data)
        }

        // Setup resize callback to notify SSH of terminal size changes
        terminalView.onResize = { [tabManager, paneId] cols, rows in
            tabManager.requestPaneResize(
                TerminalResizeRequestSize(cols: cols, rows: rows),
                forPane: paneId
            )
        }

        // Wrap in scroll view
        let scrollView = TerminalScrollView(
            contentSize: NSSize(width: 800, height: 600),
            surfaceView: terminalView
        )

        return scrollView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let scrollView = nsView as? TerminalScrollView {
            scrollView.shouldOwnFirstResponder = isActive
            let terminalView = scrollView.surfaceView
            if terminalView.surfacePresentationOverrides != tabManager.presentationOverrides(for: paneId) {
                terminalView.applyPresentationOverrides(tabManager.presentationOverrides(for: paneId))
            }
        }
    }

    static func dismantleNSView(_: NSView, coordinator: Coordinator) {
        let resolution = coordinator.tabManager.handlePaneSurfaceViewDisappeared(coordinator.paneId)
        switch resolution {
        case .preservedForReuse:
            coordinator.isReusingTerminal = true
        case .closedAndCleanedUp:
            coordinator.terminal = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        return Coordinator(
            paneId: paneId,
            onProcessExit: onProcessExit,
            richPasteUIModel: richPasteUIModel,
            tabManager: tabManager
        )
    }

    @MainActor
    class Coordinator {
        let paneId: UUID
        let onProcessExit: () -> Void
        let tabManager: TerminalTabManager
        weak var terminal: GhosttyTerminalView?
        var isReusingTerminal = false
        private let richPasteRuntime: TerminalRichPasteRuntime

        @MainActor
        init(
            paneId: UUID,
            onProcessExit: @escaping () -> Void,
            richPasteUIModel: TerminalRichPasteUIModel,
            tabManager: TerminalTabManager
        ) {
            self.paneId = paneId
            self.onProcessExit = onProcessExit
            self.tabManager = tabManager
            self.richPasteRuntime = .terminalPane(
                paneId: paneId,
                uiModel: richPasteUIModel,
                tabManager: tabManager
            )
        }

        @MainActor
        func installRichPasteInterception(on terminal: GhosttyTerminalView) {
            richPasteRuntime.install(on: terminal)
        }

        func sendToSSH(_ data: Data) {
            tabManager.requestPaneInput(data, toPane: paneId)
        }

        @MainActor
        func attachSurface(_ terminal: GhosttyTerminalView, context: TerminalSurfaceAttachContext) {
            tabManager.requestSurfaceAttach(
                paneId: paneId,
                terminal: terminal,
                context: context
            )
        }

    }
}

#endif
