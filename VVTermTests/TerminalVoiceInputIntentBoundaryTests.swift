import Foundation
import Testing

// Test Context:
// These source-boundary tests protect terminal voice input ownership. SwiftUI
// terminal views may render recording controls and send synchronous voice
// intent, but TerminalSessions Application must own AudioService and async
// start/stop/cancel request lifecycles. Update these tests only when terminal
// voice lifecycle ownership intentionally moves to another non-UI application
// owner; do not update them for visual-only voice overlay changes.

@Suite(.serialized)
struct TerminalVoiceInputIntentBoundaryTests {
    @Test
    func terminalContainerDelegatesVoiceLifecycleToApplicationStore() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/TerminalContainerView.swift")
        )
        let voiceSlice = try slice(
            startingAt: "// MARK: - Voice Input",
            endingBefore: "private func handleVoiceTranscription",
            in: source
        )

        // Given the single-session terminal voice UI source.
        #expect(
            source.contains("@EnvironmentObject private var voiceInput: TerminalVoiceInputStore"),
            "TerminalContainerView should observe the injected application-layer voice owner."
        )
        #expect(
            !source.contains("TerminalVoiceInputStore.shared"),
            "TerminalContainerView should not resolve the voice owner from a global singleton."
        )

        // Then SwiftUI must not own AudioService or voice lifecycle tasks.
        #expect(!source.contains("@StateObject private var audioService = AudioService()"))
        #expect(!voiceSlice.containsRegex(#"audioService\.(startRecording|stopRecording|cancelRecording)\s*\("#))
        #expect(!voiceSlice.containsRegex(#"(?s)Task\s*\{[^}]*audioService\.(startRecording|stopRecording|cancelRecording)\s*\("#))
    }

    @Test
    func splitTerminalDelegatesVoiceLifecycleToApplicationStore() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let voiceSlice = try slice(
            startingAt: "// MARK: - Voice Input",
            endingBefore: "private func sendTranscriptionToTerminal",
            in: source
        )

        // Given the split terminal voice UI source.
        #expect(
            source.contains("@EnvironmentObject private var voiceInput: TerminalVoiceInputStore"),
            "Split TerminalView should observe the injected application-layer voice owner."
        )
        #expect(
            !source.contains("TerminalVoiceInputStore.shared"),
            "Split TerminalView should not resolve the voice owner from a global singleton."
        )

        // Then SwiftUI must not own AudioService or voice lifecycle tasks.
        #expect(!source.contains("@StateObject private var audioService = AudioService()"))
        #expect(!voiceSlice.containsRegex(#"audioService\.(startRecording|stopRecording|cancelRecording)\s*\("#))
        #expect(!voiceSlice.containsRegex(#"(?s)Task\s*\{[^}]*audioService\.(startRecording|stopRecording|cancelRecording)\s*\("#))
    }

    @Test
    func splitTerminalDelegatesVoiceTextSendToTabManager() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Splits/TerminalView.swift")
        )
        let textSendSlice = try slice(
            startingAt: "private var voiceOverlay",
            endingBefore: "#endif",
            in: source
        )

        // Given split-pane voice transcription completes inside SwiftUI.
        #expect(
            textSendSlice.contains("case .pane(let paneId)"),
            "Split voice transcription should preserve the voice request target pane."
        )
        #expect(
            textSendSlice.contains("let target = voiceTarget"),
            "Split voice completion should capture the request target before handing work to the voice store."
        )
        #expect(
            textSendSlice.contains("target: target"),
            "The recording overlay should receive the same captured target used by its completion closure."
        )
        #expect(
            textSendSlice.contains("for: target"),
            "Stop-and-send should use the same captured target as its completion closure."
        )

        // When transcription text is ready, the UI must send text intent to the
        // application manager instead of retaining or writing a terminal surface.
        #expect(
            textSendSlice.contains("tabManager.sendText(trimmed, toPane: paneId)"),
            "Split voice text insertion should be owned by TerminalTabManager."
        )
        #expect(
            !textSendSlice.contains("TerminalTabManager.shared.sendText"),
            "Split TerminalView should use its injected tab manager instead of reaching for the singleton."
        )

        // Then SwiftUI must not unwrap or write GhosttyTerminalView directly.
        #expect(!textSendSlice.contains("guard let terminal = focusedTerminal"))
        #expect(!textSendSlice.contains("terminal.sendText(trimmed)"))
        #expect(!textSendSlice.contains("DispatchQueue.main.async"))
    }

    @Test
    func voiceOverlayDelegatesSendAndCancelToApplicationStore() throws {
        let root = try sourceRoot()
        let source = try source(
            at: root.appendingPathComponent("VVTerm/Features/TerminalSessions/UI/Terminal/VoiceRecordingView.swift")
        )

        // Given the reusable terminal voice overlay.
        #expect(
            source.contains("TerminalVoiceInputStore"),
            "VoiceRecordingView should render store state instead of observing AudioService directly."
        )

        // Then overlay buttons must not start their own transcription task or
        // call AudioService directly.
        #expect(!source.contains("@ObservedObject var audioService: AudioService"))
        #expect(!source.containsRegex(#"audioService\.(startRecording|stopRecording|cancelRecording)\s*\("#))
        #expect(!source.containsRegex(#"(?s)Task\s*\{[^}]*audioService\.(startRecording|stopRecording|cancelRecording)\s*\("#))
    }

    private func slice(startingAt marker: String, endingBefore endMarker: String, in source: String) throws -> String {
        guard let start = source.range(of: marker),
              let end = source.range(of: endMarker, range: start.lowerBound..<source.endIndex)
        else {
            throw SourceSliceError.notFound
        }
        return String(source[start.lowerBound..<end.lowerBound])
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("VVTerm.xcodeproj").path) {
                return url
            }
            url.deleteLastPathComponent()
        }
        throw SourceRootError.notFound
    }

    private enum SourceRootError: Error {
        case notFound
    }

    private enum SourceSliceError: Error {
        case notFound
    }
}

private extension String {
    func containsRegex(_ pattern: String) -> Bool {
        range(of: pattern, options: .regularExpression) != nil
    }
}
