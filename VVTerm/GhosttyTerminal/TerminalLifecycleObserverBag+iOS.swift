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
    private var configReloadObserver: NSObjectProtocol?
    private var inputModeObserver: NSObjectProtocol?
    private var hardwareKeyboardObservers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    deinit {
        invalidateAll()
    }

    func observeConfigReload(_ handler: @escaping @MainActor () -> Void) {
        guard configReloadObserver == nil else { return }
        configReloadObserver = notificationCenter.addObserver(
            forName: Ghostty.configDidReloadNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
    }

    func observeInputModeChanges(_ handler: @escaping @MainActor () -> Void) {
        guard inputModeObserver == nil else { return }
        inputModeObserver = notificationCenter.addObserver(
            forName: UITextInputMode.currentInputModeDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                handler()
            }
        }
    }

    func observeHardwareKeyboardChanges(_ handler: @escaping @MainActor () -> Void) {
        guard hardwareKeyboardObservers.isEmpty else { return }
        hardwareKeyboardObservers.append(
            notificationCenter.addObserver(
                forName: NSNotification.Name.GCKeyboardDidConnect,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    handler()
                }
            }
        )
        hardwareKeyboardObservers.append(
            notificationCenter.addObserver(
                forName: NSNotification.Name.GCKeyboardDidDisconnect,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    handler()
                }
            }
        )
    }

    func invalidateAll() {
        if let observer = configReloadObserver {
            notificationCenter.removeObserver(observer)
            configReloadObserver = nil
        }
        if let observer = inputModeObserver {
            notificationCenter.removeObserver(observer)
            inputModeObserver = nil
        }
        for observer in hardwareKeyboardObservers {
            notificationCenter.removeObserver(observer)
        }
        hardwareKeyboardObservers.removeAll()
    }
}

#endif
