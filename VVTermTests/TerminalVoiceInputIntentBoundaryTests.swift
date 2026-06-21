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
            source.contains("TerminalVoiceInputStore.shared"),
            "TerminalContainerView should observe the application-layer voice owner."
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
            source.contains("TerminalVoiceInputStore.shared"),
            "Split TerminalView should observe the application-layer voice owner."
        )

        // Then SwiftUI must not own AudioService or voice lifecycle tasks.
        #expect(!source.contains("@StateObject private var audioService = AudioService()"))
        #expect(!voiceSlice.containsRegex(#"audioService\.(startRecording|stopRecording|cancelRecording)\s*\("#))
        #expect(!voiceSlice.containsRegex(#"(?s)Task\s*\{[^}]*audioService\.(startRecording|stopRecording|cancelRecording)\s*\("#))
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
