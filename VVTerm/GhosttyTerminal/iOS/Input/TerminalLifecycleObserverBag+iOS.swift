//
//  TerminalLifecycleObserverBag+iOS.swift
//  VVTerm
//
//  Notification observer ownership for the iOS Ghostty terminal view
//

#if os(iOS)
import Foundation
import UIKit
import GameController

final class TerminalLifecycleObserverBag {
    private let notificationCenter: NotificationCenter
    nonisolated private let observerTokens: NotificationObserverTokens
    private var observesConfigReload = false
    private var observesInputModeChanges = false
    private var observesHardwareKeyboardChanges = false

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        self.observerTokens = NotificationObserverTokens(notificationCenter: notificationCenter)
    }

    deinit {
        observerTokens.invalidateAll()
    }

    func observeConfigReload(_ handler: @escaping @MainActor () -> Void) {
        guard !observesConfigReload else { return }
        observesConfigReload = true
        let token = notificationCenter.addObserver(
            forName: Ghostty.configDidReloadNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        observerTokens.append(token)
    }

    func observeInputModeChanges(_ handler: @escaping @MainActor () -> Void) {
        guard !observesInputModeChanges else { return }
        observesInputModeChanges = true
        let token = notificationCenter.addObserver(
            forName: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        observerTokens.append(token)
    }

    func observeHardwareKeyboardChanges(_ handler: @escaping @MainActor () -> Void) {
        guard !observesHardwareKeyboardChanges else { return }
        observesHardwareKeyboardChanges = true
        let connectToken = notificationCenter.addObserver(
            forName: NSNotification.Name.GCKeyboardDidConnect,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        observerTokens.append(connectToken)

        let disconnectToken = notificationCenter.addObserver(
            forName: NSNotification.Name.GCKeyboardDidDisconnect,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                handler()
            }
        }
        observerTokens.append(disconnectToken)
    }

    func invalidateAll() {
        observerTokens.invalidateAll()
        observesConfigReload = false
        observesInputModeChanges = false
        observesHardwareKeyboardChanges = false
    }
}

#endif
