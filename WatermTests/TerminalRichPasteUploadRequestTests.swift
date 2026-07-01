import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect Terminal rich-paste image upload lifecycle ownership for
// root sessions and split panes. UI may capture clipboard images and display
// prompts/notices, but TerminalSessions application managers must own request
// tracking, SSH lease use, remote-path input, cancellation, and cleanup
// ordering. Fakes here use DEBUG upload, lease, and input seams; they perform
// no network I/O and intentionally block upload or owned-lease close to expose
// ordering bugs. Update these tests only if rich-paste upload ownership moves
// to another non-UI owner with equivalent lifecycle guarantees.
@Suite(.serialized)
@MainActor
struct TerminalRichPasteUploadRequestTests {
    @Test
    func sessionRichPasteRequestStaysPendingUntilUploadAndLeaseCloseFinish() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let uploadGate = RichPasteGate()
            let closeGate = RichPasteGate()
            let recorder = RichPasteRecorder()
            let client = BlockingRichPasteClient(closeGate: closeGate)

            manager.setRichPasteLeaseProviderForTesting { requestedSessionId in
                requestedSessionId == session.id
                    ? RemoteConnectionLease(client: client, ownership: .owned)
                    : nil
            }
            manager.setRichPasteUploadOperationForTesting { image, _, _, progress in
                await recorder.record("upload-start-\(image.sizeBytes)")
                await progress(String(localized: "Uploading image to remote host..."))
                await uploadGate.wait()
                await recorder.record("upload-finish")
                return RichPasteUploadResult(remotePath: "/tmp/Waterm Paste/image 1.png", seededRemoteClipboard: false)
            }
            manager.setInputOperationForTesting { data, entityId in
                await recorder.record("input-\(entityId)-\(String(decoding: data, as: UTF8.self))")
            }

            // Given a session rich-paste request starts and the fake upload is blocked.
            let requestID = try! #require(
                manager.requestSessionRichPasteUpload(
                    image: imagePayload(),
                    settings: RichClipboardSettings(),
                    for: session.id,
                    onProgress: { @Sendable message in
                        Task { await recorder.record("progress-\(message ?? "nil")") }
                    },
                    onCompleted: { @Sendable result in
                        Task { await recorder.record("completed-\(result.testDescription)") }
                    }
                )
            )
            await recorder.waitForEvent("upload-start-7")

            // Then the manager keeps the request visible while upload work is running.
            #expect(manager.pendingSessionRichPasteUploadRequestIDs == [requestID])

            // When upload finishes but owned lease close is still blocked.
            await uploadGate.open()
            await recorder.waitForEvent("upload-finish")
            await client.waitUntilDisconnectStarted()

            // Then request cleanup still waits for lease.close().
            #expect(
                manager.pendingSessionRichPasteUploadRequestIDs == [requestID],
                "Rich-paste request bookkeeping must not clear until the SSH lease close path finishes."
            )

            await closeGate.open()
            await manager.waitForSessionRichPasteUploadRequest(requestID)

            // And success pastes the shell-escaped remote path through the manager input boundary.
            let events = await recorder.events()
            #expect(
                events.contains("input-session(\(session.id))-'/tmp/Waterm Paste/image 1.png'"),
                "Uploaded rich-paste paths must be pasted through requestSessionInput using POSIX shell escaping."
            )
            #expect(events.contains("completed-uploaded(/tmp/Waterm Paste/image 1.png,false)"))
            #expect(manager.pendingSessionRichPasteUploadRequestIDs.isEmpty)
        }
    }

    @Test
    func paneRichPasteRequestPastesUploadedPathThroughPaneInputBoundary() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )

            let recorder = RichPasteRecorder()
            let client = BlockingRichPasteClient(closeGate: RichPasteGate(open: true))

            manager.setRichPasteLeaseProviderForTesting { paneId in
                paneId == tab.rootPaneId
                    ? RemoteConnectionLease(client: client, ownership: .owned)
                    : nil
            }
            manager.setRichPasteUploadOperationForTesting { _, _, _, _ in
                RichPasteUploadResult(remotePath: "/tmp/pane paste.png", seededRemoteClipboard: true)
            }
            manager.setInputOperationForTesting { data, entityId in
                await recorder.record("input-\(entityId)-\(String(decoding: data, as: UTF8.self))")
            }

            // When a pane rich-paste upload completes.
            let requestID = try! #require(
                manager.requestPaneRichPasteUpload(
                    image: imagePayload(),
                    settings: RichClipboardSettings(),
                    forPane: tab.rootPaneId
                )
            )
            await manager.waitForPaneRichPasteUploadRequest(requestID)

            // Then pane input, not GhosttyTerminalView, receives the escaped path.
            let events = await recorder.events()
            #expect(
                events == ["input-pane(\(tab.rootPaneId))-'/tmp/pane paste.png'"],
                "Pane rich-paste success must route remote path paste through requestPaneInput."
            )
            #expect(manager.pendingPaneRichPasteUploadRequestIDs.isEmpty)
        }
    }

    @Test
    func closingSessionCancelsPendingRichPasteUploadWithoutUserFacingFailure() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let uploadGate = RichPasteGate()
            let recorder = RichPasteRecorder()
            let client = BlockingRichPasteClient(closeGate: RichPasteGate(open: true))

            manager.setRichPasteLeaseProviderForTesting { _ in
                RemoteConnectionLease(client: client, ownership: .owned)
            }
            manager.setRichPasteUploadOperationForTesting { _, _, _, _ in
                await recorder.record("upload-start")
                await uploadGate.wait()
                return RichPasteUploadResult(remotePath: "/tmp/should-not-paste.png", seededRemoteClipboard: false)
            }
            manager.setInputOperationForTesting { data, _ in
                await recorder.record("input-\(String(decoding: data, as: UTF8.self))")
            }
            manager.registerShellCancelHandler({ _ in
                await recorder.record("shell-teardown-start")
            }, for: session.id)

            // Given a rich-paste upload request is in flight.
            let requestID = try! #require(
                manager.requestSessionRichPasteUpload(
                    image: imagePayload(),
                    settings: RichClipboardSettings(),
                    for: session.id,
                    onCompleted: { @Sendable result in
                        Task { await recorder.record("completed-\(result.testDescription)") }
                    }
                )
            )
            await recorder.waitForEvent("upload-start")

            // When the owning session close path runs before upload completes.
            let closeTask = Task { @MainActor in
                await manager.closeSessionAndWait(session)
                await recorder.record("close-finished")
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then close has issued cancellation but still waits for the
            // lifecycle task to exit instead of dropping the request handle.
            #expect(
                !(await recorder.hasEvent("close-finished")),
                "closeSessionAndWait must wait for a cancelled rich-paste request to exit before SSH teardown can finish."
            )
            #expect(
                !(await recorder.hasEvent("shell-teardown-start")),
                "Shell/runtime teardown must not start before a cancelled rich-paste upload exits its lease path."
            )

            await uploadGate.open()
            await closeTask.value
            await manager.waitForSessionRichPasteUploadRequest(requestID)

            // Then close owns cancellation and no remote path is pasted.
            let events = await recorder.events()
            #expect(!events.contains { $0.hasPrefix("input-") })
            #expect(!events.contains { $0.hasPrefix("completed-failed") })
            #expect(manager.pendingSessionRichPasteUploadRequestIDs.isEmpty)
        }
    }

    @Test
    func closingPaneCancelsPendingRichPasteUploadBeforePaneTeardownFinishes() async {
        await withCleanTabManager { manager in
            let tab = TerminalTab(serverId: UUID(), title: "Tencent")
            manager.tabsByServer[tab.serverId] = [tab]
            manager.selectedTabByServer[tab.serverId] = tab.id
            manager.paneStates[tab.rootPaneId] = TerminalPaneState(
                paneId: tab.rootPaneId,
                tabId: tab.id,
                serverId: tab.serverId
            )

            let uploadGate = RichPasteGate()
            let recorder = RichPasteRecorder()
            let client = BlockingRichPasteClient(closeGate: RichPasteGate(open: true))

            manager.setRichPasteLeaseProviderForTesting { _ in
                RemoteConnectionLease(client: client, ownership: .owned)
            }
            manager.setRichPasteUploadOperationForTesting { _, _, _, _ in
                await recorder.record("pane-upload-start")
                await uploadGate.wait()
                return RichPasteUploadResult(remotePath: "/tmp/should-not-paste-pane.png", seededRemoteClipboard: false)
            }
            manager.setInputOperationForTesting { data, _ in
                await recorder.record("pane-input-\(String(decoding: data, as: UTF8.self))")
            }

            // Given a pane rich-paste upload request is in flight.
            let requestID = try! #require(
                manager.requestPaneRichPasteUpload(
                    image: imagePayload(),
                    settings: RichClipboardSettings(),
                    forPane: tab.rootPaneId,
                    onCompleted: { @Sendable result in
                        Task { await recorder.record("pane-completed-\(result.testDescription)") }
                    }
                )
            )
            await recorder.waitForEvent("pane-upload-start")

            // When pane close starts while upload work is still blocked.
            let closeTask = Task { @MainActor in
                await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)
                await recorder.record("pane-close-finished")
            }
            try? await Task.sleep(for: .milliseconds(20))

            // Then pane teardown remains awaitable until the cancelled upload exits.
            #expect(
                !(await recorder.hasEvent("pane-close-finished")),
                "closePaneAndWait must wait for a cancelled rich-paste request to exit before pane SSH teardown can finish."
            )

            await uploadGate.open()
            await closeTask.value
            await manager.waitForPaneRichPasteUploadRequest(requestID)

            let events = await recorder.events()
            #expect(!events.contains { $0.hasPrefix("pane-input-") })
            #expect(!events.contains { $0.hasPrefix("pane-completed-failed") })
            #expect(manager.pendingPaneRichPasteUploadRequestIDs.isEmpty)
        }
    }

    @Test
    func duplicateSessionRichPasteIntentSupersedesVisibleRequestButOlderRequestRemainsAwaitable() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let firstGate = RichPasteGate()
            let recorder = RichPasteRecorder()
            let client = BlockingRichPasteClient(closeGate: RichPasteGate(open: true))

            manager.setRichPasteLeaseProviderForTesting { _ in
                RemoteConnectionLease(client: client, ownership: .borrowed)
            }
            manager.setRichPasteUploadOperationForTesting { image, _, _, _ in
                if image.data == Data("first".utf8) {
                    await recorder.record("first-start")
                    await firstGate.wait()
                    return RichPasteUploadResult(remotePath: "/tmp/old.png", seededRemoteClipboard: false)
                }
                await recorder.record("second-start")
                return RichPasteUploadResult(remotePath: "/tmp/new.png", seededRemoteClipboard: false)
            }
            manager.setInputOperationForTesting { data, _ in
                await recorder.record("input-\(String(decoding: data, as: UTF8.self))")
            }

            // Given one upload is running for the session.
            let firstID = try! #require(
                manager.requestSessionRichPasteUpload(
                    image: imagePayload(data: Data("first".utf8)),
                    settings: RichClipboardSettings(),
                    for: session.id
                )
            )
            await recorder.waitForEvent("first-start")

            // When a newer upload intent arrives for the same session.
            let secondID = try! #require(
                manager.requestSessionRichPasteUpload(
                    image: imagePayload(data: Data("second".utf8)),
                    settings: RichClipboardSettings(),
                    for: session.id
                )
            )

            // Then visible request state belongs to the newest request while
            // the older request can still be awaited until its fake upload exits.
            #expect(manager.pendingSessionRichPasteUploadRequestIDs.contains(secondID))
            #expect(manager.pendingSessionRichPasteUploadRequestIDs.contains(firstID))

            await firstGate.open()
            await manager.waitForSessionRichPasteUploadRequest(firstID)
            await manager.waitForSessionRichPasteUploadRequest(secondID)

            let events = await recorder.events()
            #expect(events.contains("input-\(RemoteTerminalBootstrap.posixPastedPath("/tmp/new.png"))"))
            #expect(
                !events.contains("input-\(RemoteTerminalBootstrap.posixPastedPath("/tmp/old.png"))"),
                "A superseded rich-paste upload must not paste an older remote path after a newer intent wins."
            )
        }
    }

    @Test
    func supersededSessionRichPasteRequestCannotClearNewerVisibleProgress() async {
        await withCleanConnectionManager { manager in
            let session = ConnectionSession(
                serverId: UUID(),
                title: "Tencent",
                connectionState: .connected
            )
            manager.sessions = [session]

            let firstGate = RichPasteGate()
            let secondGate = RichPasteGate()
            let recorder = RichPasteRecorder()
            let client = BlockingRichPasteClient(closeGate: RichPasteGate(open: true))

            manager.setRichPasteLeaseProviderForTesting { _ in
                RemoteConnectionLease(client: client, ownership: .borrowed)
            }
            manager.setRichPasteUploadOperationForTesting { image, _, _, progress in
                if image.data == Data("first".utf8) {
                    await recorder.record("first-start")
                    await progress("first-progress")
                    await firstGate.wait()
                    return RichPasteUploadResult(remotePath: "/tmp/old.png", seededRemoteClipboard: false)
                }

                await recorder.record("second-start")
                await progress("second-progress")
                await secondGate.wait()
                return RichPasteUploadResult(remotePath: "/tmp/new.png", seededRemoteClipboard: false)
            }

            // Given one visible upload is running for the session.
            let firstID = try! #require(
                manager.requestSessionRichPasteUpload(
                    image: imagePayload(data: Data("first".utf8)),
                    settings: RichClipboardSettings(),
                    for: session.id,
                    onProgress: { @Sendable message in
                        Task { await recorder.record("first-progress-\(message ?? "nil")") }
                    }
                )
            )
            await recorder.waitForEvent("first-start")

            // When a newer upload intent supersedes the first request.
            let secondID = try! #require(
                manager.requestSessionRichPasteUpload(
                    image: imagePayload(data: Data("second".utf8)),
                    settings: RichClipboardSettings(),
                    for: session.id,
                    onProgress: { @Sendable message in
                        Task { await recorder.record("second-progress-\(message ?? "nil")") }
                    }
                )
            )

            #expect(manager.pendingSessionRichPasteUploadRequestIDs.contains(firstID))
            #expect(manager.pendingSessionRichPasteUploadRequestIDs.contains(secondID))

            // And the older cancelled task finally unwinds while the newer
            // request is still visible.
            await firstGate.open()
            await recorder.waitForEvent("second-start")

            // Then stale callbacks from the old request must not clear the UI
            // notice owned by the newer request.
            let events = await recorder.events()
            #expect(
                !events.contains("first-progress-nil"),
                "A superseded rich-paste request must not send progress cleanup after a newer request owns visible progress."
            )
            #expect(manager.pendingSessionRichPasteUploadRequestIDs.contains(secondID))
            #expect(manager.pendingSessionRichPasteUploadRequestIDs.contains(firstID))

            await secondGate.open()
            await manager.waitForSessionRichPasteUploadRequest(secondID)
            await manager.waitForSessionRichPasteUploadRequest(firstID)
            #expect(manager.pendingSessionRichPasteUploadRequestIDs.isEmpty)
        }
    }

    private func imagePayload(data: Data = Data([1, 2, 3, 4, 5, 6, 7])) -> ClipboardImagePayload {
        ClipboardImagePayload(
            data: data,
            mimeType: "image/png",
            utType: "public.png",
            suggestedExtension: "png"
        )
    }

    private func withCleanConnectionManager(
        _ body: @MainActor (ConnectionSessionManager) async throws -> Void
    ) async rethrows {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }

    private func withCleanTabManager(
        _ body: @MainActor (TerminalTabManager) async throws -> Void
    ) async rethrows {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()
        do {
            try await body(manager)
            await manager.resetForTesting()
        } catch {
            await manager.resetForTesting()
            throw error
        }
    }
}

private extension TerminalRichPasteUploadRequestResult {
    var testDescription: String {
        switch self {
        case .uploaded(let remotePath, let seededRemoteClipboard):
            return "uploaded(\(remotePath),\(seededRemoteClipboard))"
        case .skippedNoConnection:
            return "skippedNoConnection"
        case .cancelled:
            return "cancelled"
        case .failed(let message):
            return "failed(\(message))"
        }
    }
}

private actor RichPasteGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) {
        self.isOpen = open
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor RichPasteRecorder {
    private var recordedEvents: [String] = []
    private var waiters: [
        (predicate: (String) -> Bool, continuation: CheckedContinuation<Void, Never>)
    ] = []

    func record(_ event: String) {
        recordedEvents.append(event)
        resumeMatchingWaiters()
    }

    func events() -> [String] {
        recordedEvents
    }

    func hasEvent(_ event: String) -> Bool {
        recordedEvents.contains(event)
    }

    func waitForEvent(_ event: String) async {
        if recordedEvents.contains(event) { return }
        await withCheckedContinuation { continuation in
            waiters.append(({ $0 == event }, continuation))
        }
    }

    private func resumeMatchingWaiters() {
        var remaining: [
            (predicate: (String) -> Bool, continuation: CheckedContinuation<Void, Never>)
        ] = []
        for waiter in waiters {
            if recordedEvents.contains(where: waiter.predicate) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }
}

private actor BlockingRichPasteClient: RemoteConnectionLeaseClient {
    private let closeGate: RichPasteGate
    private var didStartDisconnect = false
    private var disconnectWaiters: [CheckedContinuation<Void, Never>] = []

    init(closeGate: RichPasteGate) {
        self.closeGate = closeGate
    }

    func waitUntilDisconnectStarted() async {
        guard !didStartDisconnect else { return }
        await withCheckedContinuation { continuation in
            disconnectWaiters.append(continuation)
        }
    }

    func disconnect() async {
        didStartDisconnect = true
        let waiters = disconnectWaiters
        disconnectWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await closeGate.wait()
    }

    func execute(_ command: String, timeout: Duration?) async throws -> String {
        ""
    }

    func upload(
        _ data: Data,
        to path: String,
        permissions: Int32,
        strategy: SSHUploadStrategy
    ) async throws {}

    func remoteEnvironment(forceRefresh: Bool) async -> RemoteEnvironment {
        .fallbackPOSIX
    }

    func remoteTerminalType(forceRefresh: Bool) async -> RemoteTerminalType {
        .xterm256Color
    }
}
