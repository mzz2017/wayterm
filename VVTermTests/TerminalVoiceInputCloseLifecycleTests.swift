import Foundation
import Testing
@testable import VVTerm

// Test Context:
// These tests protect VoiceInput cleanup when terminal lifetimes end. Terminal
// close owners may remove session/pane UI state, but active microphone and
// transcription lifecycle remains owned by TerminalVoiceInputStore. Close paths
// must send a scoped cancel intent through injected Application dependencies.
// Fakes only record cancel targets and do not use the real microphone, Speech,
// MLX, terminal surfaces, or network clients. Update these tests only if voice
// cleanup moves to an equivalent non-UI Application owner.
@Suite(.serialized)
@MainActor
struct TerminalVoiceInputCloseLifecycleTests {
    @Test
    func closingIOSSessionCancelsMatchingVoiceTarget() async {
        let manager = ConnectionSessionManager.shared
        await manager.resetForTesting()

        let recorder = VoiceCancelRecorder()
        manager.setVoiceInputCancellerForTesting { target in
            recorder.record(target)
        }
        let session = ConnectionSession(serverId: UUID(), title: "Voice Session")
        manager.sessions = [session]

        // When iOS session close removes the session lifetime.
        await manager.closeSessionAndWait(session)

        // Then it sends a scoped cancel intent to the Application voice owner.
        #expect(recorder.targets == [.session(session.id)])
        await manager.resetForTesting()
    }

    @Test
    func closingMacOSPaneCancelsMatchingVoiceTarget() async {
        let manager = TerminalTabManager.shared
        await manager.resetForTesting()

        let recorder = VoiceCancelRecorder()
        manager.setVoiceInputCancellerForTesting { target in
            recorder.record(target)
        }
        let tab = TerminalTab(serverId: UUID(), title: "Voice Pane")
        manager.tabsByServer[tab.serverId] = [tab]
        manager.paneStates[tab.rootPaneId] = TerminalPaneState(
            paneId: tab.rootPaneId,
            tabId: tab.id,
            serverId: tab.serverId
        )

        // When macOS pane close removes the pane lifetime.
        await manager.closePaneAndWait(tab: tab, paneId: tab.rootPaneId)

        // Then it sends a scoped cancel intent to the Application voice owner.
        #expect(recorder.targets == [.pane(tab.rootPaneId)])
        await manager.resetForTesting()
    }
}

@MainActor
private final class VoiceCancelRecorder {
    private(set) var targets: [TerminalVoiceInputTarget] = []

    func record(_ target: TerminalVoiceInputTarget) {
        targets.append(target)
    }
}
