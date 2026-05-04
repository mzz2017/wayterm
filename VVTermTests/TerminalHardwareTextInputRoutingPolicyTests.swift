import Testing
@testable import VVTerm

struct TerminalHardwareTextInputRoutingPolicyTests {
    @Test
    func routesPrintablePinyinKeysToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func routesPrintableKanaKeysToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func routesPrintableHangulKeysToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func routesLatinPrintableKeysToSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            )
        )
    }

    @Test
    func keepsTerminalFallbackKeysOffSystemTextInputEvenInCJKLayouts() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: true
            ) == false
        )
    }

    @Test
    func routesCapsLockToggleToSystemTextInputEvenThoughItIsFallbackKey() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: true,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func alwaysRoutesActiveCompositionThroughSystemTextInput() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: true,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: true,
                keyProducesText: false
            )
        )
    }

    @Test
    func keepsModifiedPrintableKeysOnDirectGhosttyPath() {
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: true,
                hasAlternateModifier: false,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: true,
                hasCommandModifier: false,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
        #expect(
            TerminalHardwareTextInputRoutingPolicy.shouldRoutePressToSystemTextInput(
                hasControlModifier: false,
                hasAlternateModifier: false,
                hasCommandModifier: true,
                hasActiveIMEComposition: false,
                isSystemTextInputToggleKey: false,
                hasTerminalFallbackKey: false,
                keyProducesText: true
            ) == false
        )
    }
}

struct TerminalKeyboardFocusPolicyTests {
    @Test
    func startsAutomaticWithoutReconnectRestore() {
        let policy = TerminalKeyboardFocusPolicy()

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect == false)
    }

    @Test
    func userDismissalBlocksIncidentalFocusUntilExplicitRefocus() {
        var policy = TerminalKeyboardFocusPolicy()
        let initialActivationAllowed = policy.requestFocus(for: .initialActivation)

        #expect(initialActivationAllowed)
        policy.dismissForUser()

        #expect(policy.allowsAutomaticFocus == false)
        #expect(policy.shouldRestoreOnReconnect == false)
        let directTouchAllowed = policy.requestFocus(for: .directTouch)
        let selectionGestureAllowed = policy.requestFocus(for: .selectionGesture)
        #expect(directTouchAllowed == false)
        #expect(selectionGestureAllowed == false)

        let explicitUserRequestAllowed = policy.requestFocus(for: .explicitUserRequest)
        #expect(explicitUserRequestAllowed)

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect)
    }

    @Test
    func reconnectRestoreStaysBlockedAfterManualDismissal() {
        var policy = TerminalKeyboardFocusPolicy()
        let initialActivationAllowed = policy.requestFocus(for: .initialActivation)

        #expect(initialActivationAllowed)
        policy.dismissForUser()
        policy.markForReconnect()

        #expect(policy.allowsAutomaticFocus == false)
        #expect(policy.shouldRestoreOnReconnect == false)
        let reconnectRestoreAllowed = policy.requestFocus(for: .reconnectRestore)
        #expect(reconnectRestoreAllowed == false)
    }

    @Test
    func clearingReconnectIntentPreservesCurrentFocusMode() {
        var policy = TerminalKeyboardFocusPolicy()
        let initialActivationAllowed = policy.requestFocus(for: .initialActivation)

        #expect(initialActivationAllowed)
        policy.clearReconnect()

        #expect(policy.allowsAutomaticFocus)
        #expect(policy.shouldRestoreOnReconnect == false)

        policy.dismissForUser()
        policy.clearReconnect()

        #expect(policy.allowsAutomaticFocus == false)
        #expect(policy.shouldRestoreOnReconnect == false)
    }

    @Test
    func reconnectRestoreRequiresSavedRestoreIntent() {
        var policy = TerminalKeyboardFocusPolicy()
        let initialReconnectRestoreAllowed = policy.requestFocus(for: .reconnectRestore)
        let initialActivationAllowed = policy.requestFocus(for: .initialActivation)

        #expect(initialReconnectRestoreAllowed == false)
        #expect(initialActivationAllowed)
        policy.clearReconnect()

        let reconnectRestoreWithoutIntent = policy.requestFocus(for: .reconnectRestore)
        #expect(reconnectRestoreWithoutIntent == false)

        policy.markForReconnect()

        let reconnectRestoreWithIntent = policy.requestFocus(for: .reconnectRestore)
        #expect(reconnectRestoreWithIntent)
    }
}
