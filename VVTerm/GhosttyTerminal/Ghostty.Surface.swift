import Foundation

nonisolated struct TerminalSurfaceTeardownQueue: Sendable {
    static let shared = TerminalSurfaceTeardownQueue(
        queue: DispatchQueue(label: "app.vivy.VVTerm.GhosttySurfaceTeardown", qos: .userInitiated)
    )

    private let enqueueOperation: @Sendable (@escaping @Sendable () -> Void) -> Void

    init(enqueue: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        self.enqueueOperation = enqueue
    }

    private init(queue: DispatchQueue) {
        self.enqueueOperation = { operation in
            queue.async(execute: operation)
        }
    }

    func async(_ operation: @escaping @Sendable () -> Void) {
        enqueueOperation(operation)
    }
}

extension Ghostty {
    /// Represents a single surface within Ghostty.
    ///
    /// Wraps a `ghostty_surface_t`
    nonisolated final class Surface: @unchecked Sendable {
        nonisolated final class NativeHandle: @unchecked Sendable {
            let rawValue: ghostty_surface_t?
            private let callbackContext: GhosttySurfaceCallbackContext?
            private let freeNativeSurface: () -> Void
            private let lock = NSLock()
            private var hasFreed = false

            init(
                rawValue: ghostty_surface_t?,
                callbackContext: GhosttySurfaceCallbackContext?,
                freeNativeSurface: (() -> Void)? = nil
            ) {
                self.rawValue = rawValue
                self.callbackContext = callbackContext
                self.freeNativeSurface = freeNativeSurface ?? {
                    if let rawValue {
                        ghostty_surface_free(rawValue)
                    }
                }
            }

            func scheduleFree(on queue: TerminalSurfaceTeardownQueue = .shared) {
                queue.async { [self] in
                    free()
                }
            }

            func free() {
                lock.lock()
                guard !hasFreed else {
                    lock.unlock()
                    return
                }
                hasFreed = true
                let callbackContext = callbackContext
                let freeNativeSurface = freeNativeSurface
                lock.unlock()

                callbackContext?.invalidate()
                freeNativeSurface()
            }
        }

        private var surface: ghostty_surface_t?
        private var callbackContext: GhosttySurfaceCallbackContext?
        private let lock = NSLock()

        /// Track if surface has been explicitly freed
        private var hasBeenFreed = false

        /// Read the underlying C value for this surface. This is unsafe because the value will be
        /// freed when the Surface class is deinitialized.
        var unsafeCValue: ghostty_surface_t? {
            lock.lock()
            defer { lock.unlock() }
            return surface
        }

        /// Initialize from the C structure.
        init(cSurface: ghostty_surface_t, callbackContext: GhosttySurfaceCallbackContext? = nil) {
            self.surface = cSurface
            self.callbackContext = callbackContext
        }

        @MainActor
        func invalidateCallbackContext() {
            lock.lock()
            let context = callbackContext
            lock.unlock()
            context?.invalidate()
        }

        nonisolated func detachForTeardown() -> NativeHandle? {
            lock.lock()
            guard !hasBeenFreed, let surf = surface else {
                lock.unlock()
                return nil
            }
            let context = callbackContext
            hasBeenFreed = true
            surface = nil
            callbackContext = nil
            lock.unlock()

            context?.invalidate()
            return NativeHandle(rawValue: surf, callbackContext: context)
        }

        /// Explicitly schedule surface teardown. Call this from cleanup() on main actor.
        /// Native teardown can block while joining Ghostty threads, so it runs off the UI thread.
        @MainActor
        func free() {
            detachForTeardown()?.scheduleFree()
        }

        deinit {
            detachForTeardown()?.scheduleFree()
        }

        /// Send text to the terminal as if it was typed. This doesn't send the key events so keyboard
        /// shortcuts and other encodings do not take effect.
        @MainActor
        func sendText(_ text: String) {
            guard let surface = unsafeCValue else { return }
            let len = text.utf8CString.count
            if (len == 0) { return }

            text.withCString { ptr in
                // len includes the null terminator so we do len - 1
                ghostty_surface_text(surface, ptr, UInt(len - 1))
            }
        }

        /// Send a key event to the terminal.
        ///
        /// This sends the full key event including modifiers, action type, and text to the terminal.
        /// Unlike `sendText`, this method processes keyboard shortcuts, key bindings, and terminal
        /// encoding based on the complete key event information.
        ///
        /// - Parameter event: The key event to send to the terminal
        @MainActor
        func sendKeyEvent(_ event: Input.KeyEvent) {
            guard let surface = unsafeCValue else { return }
            event.withCValue { cEvent in
                ghostty_surface_key(surface, cEvent)
            }
        }

        /// Whether the terminal has captured mouse input.
        ///
        /// When the mouse is captured, the terminal application is receiving mouse events
        /// directly rather than the host system handling them. This typically occurs when
        /// a terminal application enables mouse reporting mode.
        @MainActor
        var mouseCaptured: Bool {
            guard let surface = unsafeCValue else { return false }
            return ghostty_surface_mouse_captured(surface)
        }

        /// Whether the terminal is currently rendering the alternate screen.
        ///
        /// Full-screen terminal applications such as vim, less, htop, and many
        /// TUIs use the alternate screen even when they have not enabled mouse
        /// reporting. Host scrollback gestures should stay with the remote
        /// application in that state.
        @MainActor
        var inAlternateScreen: Bool {
            guard let surface = unsafeCValue else { return false }
            return ghostty_surface_in_alternate_screen(surface)
        }

        /// Whether closing this terminal requires user confirmation.
        ///
        /// Returns true if the terminal is busy (command running, cursor not at prompt).
        /// Uses Ghostty's internal prompt detection to avoid confirming idle shells.
        @MainActor
        var needsConfirmQuit: Bool {
            guard let surface = unsafeCValue else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }

        /// Send a mouse button event to the terminal.
        ///
        /// This sends a complete mouse button event including the button state (press/release),
        /// which button was pressed, and any modifier keys that were held during the event.
        /// The terminal processes this event according to its mouse handling configuration.
        ///
        /// - Parameter event: The mouse button event to send to the terminal
        @MainActor
        func sendMouseButton(_ event: Input.MouseButtonEvent) {
            guard let surface = unsafeCValue else { return }
            ghostty_surface_mouse_button(
                surface,
                event.action.cMouseState,
                event.button.cMouseButton,
                event.mods.cMods)
        }

        /// Send a mouse position event to the terminal.
        ///
        /// This reports the current mouse position to the terminal, which may be used
        /// for mouse tracking, hover effects, or other position-dependent features.
        /// The terminal will only receive these events if mouse reporting is enabled.
        ///
        /// - Parameter event: The mouse position event to send to the terminal
        @MainActor
        func sendMousePos(_ event: Input.MousePosEvent) {
            guard let surface = unsafeCValue else { return }
            ghostty_surface_mouse_pos(
                surface,
                event.x,
                event.y,
                event.mods.cMods)
        }

        /// Send a mouse scroll event to the terminal.
        ///
        /// This sends scroll wheel input to the terminal with delta values for both
        /// horizontal and vertical scrolling, along with precision and momentum information.
        /// The terminal processes this according to its scroll handling configuration.
        ///
        /// - Parameter event: The mouse scroll event to send to the terminal
        @MainActor
        func sendMouseScroll(_ event: Input.MouseScrollEvent) {
            guard let surface = unsafeCValue else { return }
            ghostty_surface_mouse_scroll(
                surface,
                event.x,
                event.y,
                event.mods.cScrollMods)
        }

        /// Perform a keybinding action.
        ///
        /// The action can be any valid keybind parameter. e.g. `keybind = goto_tab:4`
        /// you can perform `goto_tab:4` with this.
        ///
        /// Returns true if the action was performed. Invalid actions return false.
        @MainActor
        func perform(action: String) -> Bool {
            guard let surface = unsafeCValue else { return false }
            let len = action.utf8CString.count
            if (len == 0) { return false }
            return action.withCString { cString in
                ghostty_surface_binding_action(surface, cString, UInt(len - 1))
            }
        }

        /// Terminal grid size information
        struct TerminalSize {
            let columns: UInt16
            let rows: UInt16
            let widthPx: UInt32
            let heightPx: UInt32
            let cellWidthPx: UInt32
            let cellHeightPx: UInt32
        }

        /// Get current terminal size
        @MainActor
        func terminalSize() -> TerminalSize? {
            guard let surface = unsafeCValue else { return nil }
            let cSize = ghostty_surface_size(surface)
            return TerminalSize(
                columns: cSize.columns,
                rows: cSize.rows,
                widthPx: cSize.width_px,
                heightPx: cSize.height_px,
                cellWidthPx: cSize.cell_width_px,
                cellHeightPx: cSize.cell_height_px
            )
        }

        // MARK: - External backend I/O (for SSH clients)

        /// Feed remote bytes (e.g. SSH output) into the terminal for display.
        /// Used with the External termio backend. Caller serializes per surface.
        @MainActor
        func writeOutput(_ data: Data) {
            guard let surface = unsafeCValue else { return }
            guard !data.isEmpty else { return }
            data.withUnsafeBytes { buffer in
                if let ptr = buffer.baseAddress?.assumingMemoryBound(to: CChar.self) {
                    ghostty_surface_write_output(surface, ptr, UInt(buffer.count))
                }
            }
        }

        /// Convenience: feed a UTF-8 string into the terminal.
        @MainActor
        func writeOutputText(_ text: String) {
            guard let data = text.data(using: .utf8) else { return }
            writeOutput(data)
        }

        /// Notify the terminal that the external session ended (SSH disconnect).
        @MainActor
        func externalExited(_ exitCode: UInt32 = 0) {
            guard let surface = unsafeCValue else { return }
            ghostty_surface_external_exited(surface, exitCode)
        }
    }
}
