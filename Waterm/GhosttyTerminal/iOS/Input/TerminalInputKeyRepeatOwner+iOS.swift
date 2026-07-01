//
//  TerminalInputKeyRepeatOwner+iOS.swift
//  Waterm
//
//  Owns keyboard accessory repeat timers outside UIInputView actor state.
//

#if os(iOS)
import Foundation

nonisolated final class TerminalInputKeyRepeatOwner: @unchecked Sendable {
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    deinit {
        stop()
    }

    func start(
        key: TerminalKey,
        initialDelay: DispatchTimeInterval = .milliseconds(350),
        repeating interval: DispatchTimeInterval = .milliseconds(50),
        handler: @escaping @MainActor (TerminalKey) -> Void
    ) {
        stop()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + initialDelay, repeating: interval)
        timer.setEventHandler {
            MainActor.assumeIsolated {
                handler(key)
            }
        }

        lock.lock()
        self.timer = timer
        lock.unlock()

        timer.resume()
    }

    func stop() {
        lock.lock()
        let timerToCancel = timer
        timer = nil
        lock.unlock()

        timerToCancel?.cancel()
    }
}

#endif
