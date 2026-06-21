import Foundation
import Testing

// Test Context:
// These tests protect macOS singleton window ownership boundaries for feature
// presentation. SwiftUI files may configure their attached host window, but
// long-lived singleton NSWindow presenters must live in Application-owned files
// so view recreation does not become the owner of critical window lifetime.
// The tests inspect source placement only; they do not instantiate AppKit
// windows, render SwiftUI, or exercise purchase/about behavior. Update this
// context only when the feature-first ownership rule intentionally changes.
@Suite
struct AppKitWindowOwnershipBoundaryTests {
    @Test
    func singletonWindowPresentersLiveInApplicationLayer() throws {
        // Given AppKit singleton presenters retain NSWindow instances across
        // SwiftUI view lifetimes.
        let root = try sourceRoot()
        let aboutUI = try source(at: root.appendingPathComponent("VVTerm/Features/Settings/UI/AboutView.swift"))
        let proUpgradeUI = try source(at: root.appendingPathComponent("VVTerm/Features/Store/UI/ProUpgradeSheet.swift"))

        // Then those long-lived owners must not be declared in UI source files.
        #expect(
            !aboutUI.contains("final class AboutWindowController"),
            "The About singleton NSWindow owner must live outside Settings/UI."
        )
        #expect(
            !proUpgradeUI.contains("final class ProUpgradeWindowPresenter"),
            "The Pro upgrade singleton NSWindow owner must live outside Store/UI."
        )

        // And the feature Application layer must contain the replacement owners.
        #expect(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent("VVTerm/Features/Settings/Application/AboutWindowPresenter.swift")
                    .path
            ),
            "Settings/Application should own the About window presenter."
        )
        #expect(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent("VVTerm/Features/Store/Application/ProUpgradeWindowPresenter.swift")
                    .path
            ),
            "Store/Application should own the Pro upgrade window presenter."
        )
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    private func sourceRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.lastPathComponent != "VVTermTests" {
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
