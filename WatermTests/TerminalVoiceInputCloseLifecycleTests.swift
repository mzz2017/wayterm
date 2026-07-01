import Foundation
import Testing
@testable import Waterm

// Test Context:
// These tests protect VoiceInput cleanup when terminal lifetimes end. Terminal
// close owners may remove session/pane UI state, but active microphone and
// transcription lifecycle remains owned by TerminalVoiceInputStore. Close paths
// must send a scoped cancel intent through injected Application dependencies
// and wait for the voice owner cancellation task before close returns. Fakes
// only record cancel targets and do not use the real microphone, Speech, MLX,
// terminal surfaces, or network clients. Update these tests only if voice
// cleanup moves to an equivalent non-UI Application owner.
@Suite(.serialized)
@MainActor
struct TerminalVoiceInputCloseLifecycleTests {
    @Test
    func closingIOSSessionCancelsMatchingVoiceTarget() async {
        // Given an iOS session and a voice cancellation dependency that remains
        // pending until the test releases it.
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()

        let recorder = VoiceCancelRecorder()
        let releaseCancel = VoiceCancelGate()
        manager.setVoiceInputCancellerForTesting { target in
            Task { @MainActor in
                recorder.record(target)
                await releaseCancel.wait()
                recorder.recordCancelCompleted(target)
            }
        }
        let session = ConnectionSession(serverId: UUID(), title: "Voice Session")
        manager.sessions = [session]

        // When iOS session close removes the session lifetime.
        let closeTask = Task { @MainActor in
            await manager.closeSessionAndWait(session)
            recorder.record(.closeReturned(session.id))
        }
        await recorder.waitForCount(1)

        // Then it sends a scoped cancel intent to the Application voice owner
        // and keeps close pending until that cancellation completes.
        #expect(recorder.events == [.targetSession(session.id)])
        await releaseCancel.open()
        await closeTask.value
        #expect(
            recorder.events == [
                .targetSession(session.id),
                .cancelCompletedSession(session.id),
                .closeReturned(session.id)
            ],
            "Closing an iOS terminal session should wait for TerminalVoiceInputStore cancellation cleanup."
        )
        await manager.resetForTesting()
    }

    @Test
    func closingMacOSPaneCancelsMatchingVoiceTarget() async {
        // Given a macOS pane and a voice cancellation dependency that remains
        // pending until the test releases it.
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()

        let recorder = VoiceCancelRecorder()
        let releaseCancel = VoiceCancelGate()
        manager.setVoiceInputCancellerForTesting { target in
            Task { @MainActor in
                recorder.record(target)
                await releaseCancel.wait()
                recorder.recordCancelCompleted(target)
            }
        }
        let tab = TerminalTab(serverId: UUID(), title: "Voice Pane")
        manager.tabsByServer[tab.serverId] = [tab]
        manager.paneStates[tab.rootPaneId] = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )

        // When macOS pane close removes the pane lifetime.
        let closeTask = Task { @MainActor in
            await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)
            recorder.record(.closeReturned(tab.rootPaneId))
        }
        await recorder.waitForCount(1)

        // Then it sends a scoped cancel intent to the Application voice owner
        // and keeps close pending until that cancellation completes.
        #expect(recorder.events == [.targetPane(tab.rootPaneId)])
        await releaseCancel.open()
        await closeTask.value
        #expect(
            recorder.events == [
                .targetPane(tab.rootPaneId),
                .cancelCompletedPane(tab.rootPaneId),
                .closeReturned(tab.rootPaneId)
            ],
            "Closing a macOS terminal pane should wait for TerminalVoiceInputStore cancellation cleanup."
        )
        await manager.resetForTesting()
    }
}

@MainActor
private final class VoiceCancelRecorder {
    private(set) var events: [VoiceCancelEvent] = []

    func record(_ target: TerminalVoiceInputTarget) {
        switch target {
        case let .session(id):
            events.append(.targetSession(id))
        case let .pane(id):
            events.append(.targetPane(id))
        }
    }

    func recordCancelCompleted(_ target: TerminalVoiceInputTarget) {
        switch target {
        case let .session(id):
            events.append(.cancelCompletedSession(id))
        case let .pane(id):
            events.append(.cancelCompletedPane(id))
        }
    }

    func record(_ event: VoiceCancelEvent) {
        events.append(event)
    }

    func waitForCount(_ count: Int) async {
        while events.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum VoiceCancelEvent: Equatable {
    case targetSession(UUID)
    case targetPane(UUID)
    case cancelCompletedSession(UUID)
    case cancelCompletedPane(UUID)
    case closeReturned(UUID)
}

private actor VoiceCancelGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let ready = continuations
        continuations.removeAll()
        ready.forEach { $0.resume() }
    }
}
