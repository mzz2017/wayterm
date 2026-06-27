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
        let proUpgradePresentationUI = try source(
            at: root.appendingPathComponent("VVTerm/Features/Store/UI/ProUpgradePresentation.swift")
        )

        // Then those long-lived owners must not be declared in UI source files.
        #expect(
            !aboutUI.contains("final class AboutWindowController"),
            "The About singleton NSWindow owner must live outside Settings/UI."
        )
        #expect(
            !proUpgradeUI.contains("final class ProUpgradeWindowPresenter"),
            "The Pro upgrade singleton NSWindow owner must live outside Store/UI."
        )
        #expect(
            !proUpgradeUI.contains("ProUpgradePresentationModifier"),
            "ProUpgradeSheet.swift should not own Pro upgrade presentation routing."
        )
        #expect(
            !proUpgradeUI.contains("struct ProUpgradeWindowConfigurator"),
            "ProUpgradeSheet.swift should not own AppKit window configuration bridge code."
        )
        #expect(
            !proUpgradePresentationUI.contains("StoreManager.shared"),
            "Pro upgrade presentation UI should receive StoreManager from the environment instead of resolving the singleton."
        )
        #expect(
            !proUpgradePresentationUI.contains("ProUpgradeWindowPresenter.shared"),
            "Pro upgrade presentation UI should use an injected window presentation service instead of resolving the singleton presenter."
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
        #expect(
            FileManager.default.fileExists(
                atPath: root
                    .appendingPathComponent("VVTerm/Features/Store/Application/ProUpgradeWindowPresentationService.swift")
                    .path
            ),
            "Store/Application should provide the live Pro upgrade window presentation service."
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
