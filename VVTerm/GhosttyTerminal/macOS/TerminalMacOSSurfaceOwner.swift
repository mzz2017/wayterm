//
//  TerminalMacOSSurfaceOwner.swift
//  VVTerm
//
//  Stable owner for macOS Ghostty app and surface references.
//

#if os(macOS)
import Foundation

@MainActor
final class TerminalMacOSSurfaceOwner {
    let ghosttyApp: ghostty_app_t
    weak var appWrapper: Ghostty.App?
    var surface: Ghostty.Surface?

    init(ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App?) {
        self.ghosttyApp = ghosttyApp
        self.appWrapper = appWrapper
    }
}
#endif
