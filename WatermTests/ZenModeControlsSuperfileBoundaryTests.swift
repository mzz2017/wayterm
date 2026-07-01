import Foundation
import Testing

// Test Context:
// These source-boundary tests protect Zen mode control superfile ownership.
// ZenModeControls.swift should own reusable Zen overlay/control primitives,
// while platform-specific panel composition lives in sibling UI files. Update
// these tests only when Zen mode panel ownership intentionally changes.
@Suite(.serialized)
struct ZenModeControlsSuperfileBoundaryTests {
    @Test
    func zenModeControlsOwnsSharedChromeWithoutDefiningPlatformPanels() throws {
        let root = try sourceRoot()
        let sharedSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/ZenModeControls.swift")
        )
        let macOSPanelSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/MacOSZenModePanel.swift")
        )
        let iOSPanelSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/IOSZenModePanel.swift")
        )

        // Given ZenModeControls is the shared chrome file.
        for sharedType in [
            "ZenModeFloatingOverlay",
            "ZenModePanelCard",
            "ZenModeSection",
            "ZenModeChoiceChip",
            "ZenModeActionButton",
            "ZenModeStatusLine"
        ] {
            #expect(
                sharedSource.contains("struct \(sharedType)"),
                "ZenModeControls.swift should define shared Zen primitive \(sharedType)."
            )
        }

        // Then platform panel composition should live beside the shared chrome,
        // not inside the shared controls file.
        #expect(
            !sharedSource.contains("struct MacOSZenModePanel: View"),
            "ZenModeControls.swift should not define the macOS Zen panel."
        )
        #expect(
            !sharedSource.contains("struct IOSZenModePanel: View"),
            "ZenModeControls.swift should not define the iOS Zen panel."
        )
        #expect(
            macOSPanelSource.contains("struct MacOSZenModePanel: View"),
            "MacOSZenModePanel.swift should define the macOS Zen panel."
        )
        #expect(
            iOSPanelSource.contains("struct IOSZenModePanel: View"),
            "IOSZenModePanel.swift should define the iOS Zen panel."
        )
    }

    @Test
    func platformZenPanelsOwnPanelSpecificIntentClosures() throws {
        let root = try sourceRoot()
        let sharedSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/ZenModeControls.swift")
        )
        let macOSPanelSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/MacOSZenModePanel.swift")
        )
        let iOSPanelSource = try source(
            at: root.appendingPathComponent("Waterm/Features/TerminalSessions/UI/Terminal/IOSZenModePanel.swift")
        )

        // Given panel-specific commands are platform panel presentation details.
        for macOSIntent in [
            "let onSplitRight",
            "let onSplitDown",
            "let onClosePane",
            "let onToggleSidebar"
        ] {
            #expect(
                macOSPanelSource.contains(macOSIntent),
                "MacOSZenModePanel.swift should own macOS panel intent closure \(macOSIntent)."
            )
            #expect(
                !sharedSource.contains(macOSIntent),
                "ZenModeControls.swift should not own macOS panel intent closure \(macOSIntent)."
            )
        }

        for iOSIntent in [
            "let onCloseSession",
            "let onOpenSettings",
            "let onBack"
        ] {
            #expect(
                iOSPanelSource.contains(iOSIntent),
                "IOSZenModePanel.swift should own iOS panel intent closure \(iOSIntent)."
            )
            #expect(
                !sharedSource.contains(iOSIntent),
                "ZenModeControls.swift should not own iOS panel intent closure \(iOSIntent)."
            )
        }
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "WatermTests" {
            let next = url.deletingLastPathComponent()
            if next.path == url.path {
                throw SourceRootError.notFound
            }
            url = next
        }
        return url.deletingLastPathComponent()
    }

    private enum SourceRootError: Error {
        case notFound
    }
}
