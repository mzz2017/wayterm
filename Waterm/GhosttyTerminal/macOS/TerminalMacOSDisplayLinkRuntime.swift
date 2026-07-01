//
//  TerminalMacOSDisplayLinkRuntime.swift
//  Waterm
//
//  Runtime owner for macOS Ghostty display-link rendering.
//

#if os(macOS)
import AppKit
import CoreVideo

final class TerminalMacOSDisplayLinkRuntime {
    typealias Tick = @MainActor () -> Void

    private var displayLink: CVDisplayLink?
    private var needsRender = false
    private var lastActivityTime: CFAbsoluteTime = 0
    private var idleCheckTimer: DispatchSourceTimer?
    private var displayLinkCallbackContext: Unmanaged<TerminalMacOSDisplayLinkCallbackContext>?

    private static let idleTimeout: CFTimeInterval = 0.1

    deinit {
        stopFromDeinit()
    }

    @MainActor
    func setup(tick: @escaping Tick) {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let displayLink = link else { return }

        let callbackContext = TerminalMacOSDisplayLinkCallbackContext(tick: tick)
        let retainedRef = Unmanaged.passRetained(callbackContext)
        displayLinkCallbackContext = retainedRef

        CVDisplayLinkSetOutputCallback(displayLink, { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let callbackContext = Unmanaged<TerminalMacOSDisplayLinkCallbackContext>
                .fromOpaque(userInfo)
                .takeUnretainedValue()

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    callbackContext.performTick()
                }
            }
            return kCVReturnSuccess
        }, retainedRef.toOpaque())

        self.displayLink = displayLink
        setupIdleCheckTimer()
    }

    @MainActor
    func tick(isShuttingDown: Bool, surface: ghostty_surface_t?, appTick: () -> Void) {
        guard !isShuttingDown else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastActivityTime > Self.idleTimeout && !needsRender {
            if let link = displayLink, CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStop(link)
            }
            return
        }

        if needsRender, let surface {
            needsRender = false
            ghostty_surface_refresh(surface)
            ghostty_surface_draw(surface)
        }

        appTick()
    }

    @MainActor
    func requestRender() {
        lastActivityTime = CFAbsoluteTimeGetCurrent()
        needsRender = true

        if let link = displayLink, !CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStart(link)
        }
    }

    @MainActor
    func stop() {
        idleCheckTimer?.cancel()
        idleCheckTimer = nil

        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil

        releaseCallbackContext(invalidate: true)
    }

    func stopFromDeinit() {
        idleCheckTimer?.cancel()
        idleCheckTimer = nil

        if let link = displayLink {
            CVDisplayLinkStop(link)
        }
        displayLink = nil

        releaseCallbackContext(invalidate: false)
    }

    @MainActor
    private func setupIdleCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.idleTimeout, repeating: Self.idleTimeout)
        timer.setEventHandler { [weak self] in
            self?.checkIdleState()
        }
        timer.resume()
        idleCheckTimer = timer
    }

    @MainActor
    private func checkIdleState() {
        guard let link = displayLink, CVDisplayLinkIsRunning(link) else { return }

        let now = CFAbsoluteTimeGetCurrent()
        if now - lastActivityTime > Self.idleTimeout && !needsRender {
            CVDisplayLinkStop(link)
        }
    }

    private func releaseCallbackContext(invalidate: Bool) {
        guard let retainedRef = displayLinkCallbackContext else { return }
        let callbackContext = retainedRef.takeRetainedValue()
        if invalidate {
            callbackContext.invalidate()
        }
        displayLinkCallbackContext = nil
    }
}

private final class TerminalMacOSDisplayLinkCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: TerminalMacOSDisplayLinkRuntime.Tick?

    init(tick: @escaping TerminalMacOSDisplayLinkRuntime.Tick) {
        self.tick = tick
    }

    @MainActor
    func performTick() {
        let tick: TerminalMacOSDisplayLinkRuntime.Tick?
        lock.lock()
        tick = self.tick
        lock.unlock()
        tick?()
    }

    func invalidate() {
        lock.lock()
        tick = nil
        lock.unlock()
    }
}

#endif
