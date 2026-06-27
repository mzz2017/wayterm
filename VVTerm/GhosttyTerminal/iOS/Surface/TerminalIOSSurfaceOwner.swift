//
//  TerminalIOSSurfaceOwner.swift
//  VVTerm
//
//  Stable owner for iOS Ghostty app and surface references.
//

#if os(iOS)
import Foundation

@MainActor
final class TerminalIOSSurfaceOwner {
    let ghosttyApp: ghostty_app_t
    weak var appWrapper: Ghostty.App?
    var surface: Ghostty.Surface?

    init(ghosttyApp: ghostty_app_t, appWrapper: Ghostty.App?) {
        self.ghosttyApp = ghosttyApp
        self.appWrapper = appWrapper
    }
}
#endif
