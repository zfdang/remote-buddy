import AppKit
import Foundation

extension HIDRemoteMonitor {
    func currentApplicationScope() -> CapturedApplicationScope {
        CapturedApplicationScope(bundleIdentifier: settings.frontmostApplicationBundleIdentifier())
    }

    func capturedOrCurrentApplicationScope(for button: RemoteButton) -> CapturedApplicationScope {
        capturedApplicationScopes[button] ?? currentApplicationScope()
    }

    func clearCapturedApplicationScopeIfIdle(for button: RemoteButton) {
        guard !activeUsages.contains(button.hidUsage),
              !gestureRecognizer.isTracking(button),
              repeatTimers[button.hidUsage] == nil
        else { return }
        capturedApplicationScopes.removeValue(forKey: button)
    }

    func shouldAcceptRawPress(
        button: RemoteButton,
        action: ButtonAction,
        frontmostBundleIdentifier: String? = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
        applicationScope: ApplicationOverrideScope = .live
    ) -> Bool {
        guard !Self.shouldRepeat(
            action: action,
            frontmostBundleIdentifier: frontmostBundleIdentifier,
            enabled: settings.allowsHoldRepeat(
                for: button,
                profileID: profileID,
                applicationScope: applicationScope
            )
        ) else { return true }
        if nonRepeatableReleaseTimers[button] != nil {
            finishNonRepeatablePress(button)
        }
        guard nonRepeatablePressedButtons.insert(button).inserted else { return false }
        refreshUsageExpiry(button.hidUsage)
        return true
    }

    nonisolated static func shouldRepeat(
        action: ButtonAction,
        frontmostBundleIdentifier: String?,
        enabled: Bool
    ) -> Bool {
        guard enabled, action != .disabled else { return false }
        guard frontmostBundleIdentifier == PresetApplication.remoteMic.bundleIdentifier else {
            return true
        }
        return ![.arrowUp, .arrowDown, .arrowLeft, .arrowRight, .deleteBackward].contains(action)
    }

    func isDirectPassthrough(
        button: RemoteButton,
        profileID: UUID?,
        applicationScope: ApplicationOverrideScope = .live
    ) -> Bool {
        guard button.isDirectional else { return false }
        return settings.configuredAction(
            for: button,
            trigger: .singleClick,
            profileID: profileID,
            applicationScope: applicationScope
        ).action == .directPassthrough
    }

    /// Expects and swallows the native key event macOS generates for a remote press.
    /// Reports recovered from the BTLEServer log have no native event, so arming would
    /// only risk swallowing a real keyboard press of the same key.
    func armNativeSuppression(button: RemoteButton, edge: RemoteEventEdge, fromBTLEServerLog: Bool = false) {
        guard !fromBTLEServerLog, currentReportOrigin != .btleServerLog else { return }
        eventSuppressor.arm(button: button, edge: edge)
    }

    func shouldUseNativePassthrough(
        button: RemoteButton,
        action: ButtonAction,
        recognizesDoubleClick: Bool,
        recognizesLongPress: Bool,
        applicationScope: ApplicationOverrideScope = .live
    ) -> Bool {
        guard !activeDeviceIsSeized,
              currentReportOrigin != .btleServerLog,
              !appSwitcherCoordinator.isActive,
              !recognizesDoubleClick,
              !recognizesLongPress,
              settings.allowsHoldRepeat(
                  for: button,
                  profileID: profileID,
                  applicationScope: applicationScope
              ),
              frontmostBundleIdentifier() != PresetApplication.remoteMic.bundleIdentifier
        else { return false }
        return (button == .left && action == .arrowLeft) ||
            (button == .right && action == .arrowRight)
    }

    func scheduleNonRepeatableRelease(for button: RemoteButton) {
        guard nonRepeatablePressedButtons.contains(button) else { return }
        nonRepeatableReleaseTimers.removeValue(forKey: button)?.cancel()
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.stableReleaseMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            self?.finishNonRepeatablePress(button)
        }
        nonRepeatableReleaseTimers[button] = timer
    }

    func finishNonRepeatablePress(_ button: RemoteButton) {
        nonRepeatableReleaseTimers.removeValue(forKey: button)?.cancel()
        nonRepeatablePressedButtons.remove(button)
    }

    func cancelRepeat(for usage: UInt16) {
        repeatTokens.removeValue(forKey: usage)
        repeatTimers.removeValue(forKey: usage)?.cancel()
        if let button = RemoteButton.usageMap[usage] {
            clearCapturedApplicationScopeIfIdle(for: button)
        }
    }

    func startRepeatIfNeeded(
        usage: UInt16,
        button: RemoteButton,
        action: ButtonAction,
        applicationScope: ApplicationOverrideScope = .live
    ) {
        let interval = HIDRemoteTiming.repeatIntervalMilliseconds(for: action)
        guard
            action != .disabled,
            Self.shouldRepeat(
                action: action,
                frontmostBundleIdentifier: frontmostBundleIdentifier(),
                enabled: settings.allowsHoldRepeat(
                    for: button,
                    profileID: profileID,
                    applicationScope: applicationScope
                )
            )
        else { return }

        cancelRepeat(for: usage)
        if action == .deleteBackward {
            scheduleHardCeiling(for: usage, afterMilliseconds: HIDRemoteTiming.maximumDeleteHoldMilliseconds)
        }
        let token = UUID()
        repeatTokens[usage] = token
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.repeatStartMilliseconds,
            repeatingEveryMilliseconds: interval
        ) { [weak self] in
            guard let self, self.repeatTokens[usage] == token else { return }
            guard self.activeUsages.contains(usage) else {
                self.cancelRepeat(for: usage)
                return
            }
            let configured = self.settings.configuredAction(
                for: button,
                trigger: .singleClick,
                profileID: self.profileID,
                applicationScope: applicationScope
            )
            if !Self.shouldRepeat(
                    action: configured.action,
                    frontmostBundleIdentifier: self.frontmostBundleIdentifier(),
                    enabled: self.settings.allowsHoldRepeat(
                        for: button,
                        profileID: self.profileID,
                        applicationScope: applicationScope
                    )
                ) {
                self.cancelRepeat(for: usage)
                return
            }
            guard self.runtimePermissionsAreValid() else {
                self.releaseForRevokedPermissions()
                return
            }
            guard self.mappingDeliveryIsSafe else {
                self.cancelRepeat(for: usage)
                self.pauseForUnavailableNativeFilter()
                return
            }
            // A hold has won over the deferred click; release must not emit another click.
            self.gestureRecognizer.cancel(button)
            self.cancelDoubleClickTimeout(for: button)
            self.cancelLongPressTimeout(for: button)
            if !self.performConfiguredAction(
                for: button,
                trigger: .singleClick,
                applicationScope: applicationScope
            ) {
                self.cancelRepeat(for: usage)
            }
        }
        repeatTimers[usage] = timer
    }

    func processGestureCommands(
        _ commands: [RemoteButtonGestureRecognizer.Command]
    ) -> Bool {
        for command in commands {
            switch command {
            case let .scheduleDoubleClickTimeout(button):
                scheduleDoubleClickTimeout(for: button)
            case let .cancelDoubleClickTimeout(button):
                cancelDoubleClickTimeout(for: button)
            case let .scheduleLongPressTimeout(button):
                scheduleLongPressTimeout(for: button)
            case let .cancelLongPressTimeout(button):
                cancelLongPressTimeout(for: button)
            case let .trigger(button, trigger):
                diagnosticLogger(
                    "HID GESTURE button=\(button.rawValue) trigger=\(trigger.rawValue) path=recognizer"
                )
                let captured = capturedOrCurrentApplicationScope(for: button)
                guard performConfiguredAction(
                    for: button,
                    trigger: trigger,
                    applicationScope: .fixed(captured.bundleIdentifier)
                ) else { return false }
            }
        }
        return true
    }

    func cancelDoubleClickTimeout(for button: RemoteButton) {
        doubleClickTimerTokens.removeValue(forKey: button)
        doubleClickTimers.removeValue(forKey: button)?.cancel()
    }

    func cancelLongPressTimeout(for button: RemoteButton) {
        longPressTimerTokens.removeValue(forKey: button)
        longPressTimers.removeValue(forKey: button)?.cancel()
    }

    func clearBTLELogPendingGestureIfFinished(for button: RemoteButton) {
        guard !btleLogActiveUsages.contains(button.hidUsage),
              !activeUsages.contains(button.hidUsage),
              !gestureRecognizer.isTracking(button)
        else { return }
        btleLogPendingGestureButtons.remove(button)
    }

    func scheduleDoubleClickTimeout(for button: RemoteButton) {
        cancelDoubleClickTimeout(for: button)
        let token = UUID()
        doubleClickTimerTokens[button] = token
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.doubleClickMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self, self.doubleClickTimerTokens[button] == token else { return }
            self.doubleClickTimerTokens.removeValue(forKey: button)
            self.doubleClickTimers.removeValue(forKey: button)
            _ = self.processGestureCommands(self.gestureRecognizer.doubleClickTimedOut(button))
            self.clearBTLELogPendingGestureIfFinished(for: button)
            self.clearCapturedApplicationScopeIfIdle(for: button)
        }
        doubleClickTimers[button] = timer
    }

    func scheduleLongPressTimeout(for button: RemoteButton) {
        cancelLongPressTimeout(for: button)
        let token = UUID()
        longPressTimerTokens[button] = token
        let timer = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.longPressMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self, self.longPressTimerTokens[button] == token else { return }
            self.longPressTimerTokens.removeValue(forKey: button)
            self.longPressTimers.removeValue(forKey: button)
            _ = self.processGestureCommands(self.gestureRecognizer.longPressTimedOut(button))
            self.clearBTLELogPendingGestureIfFinished(for: button)
            self.clearCapturedApplicationScopeIfIdle(for: button)
        }
        longPressTimers[button] = timer
    }

    func performConfiguredAction(
        for button: RemoteButton,
        trigger: ButtonTrigger,
        applicationScope: ApplicationOverrideScope? = nil
    ) -> Bool {
        guard runtimePermissionsAreValid() else {
            releaseForRevokedPermissions()
            return false
        }
        guard mappingDeliveryIsSafe else {
            pauseForUnavailableNativeFilter()
            return false
        }
        let resolvedScope = applicationScope ?? .fixed(capturedOrCurrentApplicationScope(for: button).bundleIdentifier)
        let configured = settings.configuredAction(
            for: button,
            trigger: trigger,
            profileID: profileID,
            applicationScope: resolvedScope
        )
        if appSwitcherCoordinator.isActive, button == .tv {
            return performAppSwitcherAction(for: button, trigger: trigger)
        }
        if configured.action == .appSwitcher {
            return performAppSwitcherAction(for: button, trigger: trigger)
        }
        if appSwitcherCoordinator.isActive {
            appSwitcherCoordinator.finishLifecycle(
                reason: "unrelated_action_\(configured.action.rawValue)",
                confirmed: false
            )
        }
        if configured.action.isAppInternal {
            onInternalAction?(profileID, configured.action)
            AppLogger.shared.write(
                "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=\(configured.action.rawValue)"
            )
            return true
        }
        guard actionPerformer(button, trigger, configured) else {
            diagnosticLogger(
                "HID ACTION failed button=\(button.rawValue) trigger=\(trigger.rawValue) " +
                    "action=\(configured.action.rawValue)"
            )
            // A library rejection is not evidence of revoked Accessibility permission.
            // Preserve the held edge so duplicate reports cannot restart the action.
            if !runtimePermissionsAreValid() {
                releaseForRevokedPermissions()
            }
            return false
        }
        AppLogger.shared.write(
            "HID BUTTON button=\(button.rawValue) trigger=\(trigger.rawValue) action=\(configured.action.rawValue)"
        )
        return true
    }

    func performAppSwitcherAction(
        for button: RemoteButton,
        trigger: ButtonTrigger
    ) -> Bool {
        let submitted = appSwitcherCoordinator.trigger(
            for: button,
            trigger: trigger,
            owner: switcherOwnerToken
        )
        if appSwitcherCoordinator.isOwned(by: switcherOwnerToken) {
            if submitted {
                btleLogOwnsAppSwitcher = (currentReportOrigin == .btleServerLog)
            }
        } else {
            btleLogOwnsAppSwitcher = false
        }
        return submitted
    }

    func handleAppSwitcherControlPress(_ button: RemoteButton) -> Bool {
        let handled = appSwitcherCoordinator.handleControlPress(button, owner: switcherOwnerToken)
        if handled {
            if appSwitcherCoordinator.isOwned(by: switcherOwnerToken) {
                btleLogOwnsAppSwitcher = (currentReportOrigin == .btleServerLog)
            } else {
                btleLogOwnsAppSwitcher = false
            }
        }
        return handled
    }

    func resetGestureRecognition() {
        doubleClickTimerTokens.removeAll()
        doubleClickTimers.values.forEach { $0.cancel() }
        doubleClickTimers.removeAll()
        longPressTimerTokens.removeAll()
        longPressTimers.values.forEach { $0.cancel() }
        longPressTimers.removeAll()
        btleLogPendingGestureButtons.removeAll()
        btleLogOwnsAppSwitcher = false
        capturedApplicationScopes.removeAll()
        gestureRecognizer.reset()
    }

    func cancelMappingInteractions() { resetInputState() }

    func cancelBTLEServerLogInteractions() {
        lastGoogleReportByOrigin.removeValue(forKey: .btleServerLog)
        let ownsActiveBTLESwitcher = btleLogOwnsAppSwitcher &&
            appSwitcherCoordinator.isOwned(by: switcherOwnerToken)
        guard !btleLogActiveUsages.isEmpty || !btleLogPendingGestureButtons.isEmpty || ownsActiveBTLESwitcher else {
            return
        }
        let affectedUsages = btleLogActiveUsages
        let affectedButtons = btleLogPendingGestureButtons.union(RemoteButton.buttons(for: affectedUsages))
        btleLogActiveUsages.removeAll()
        btleLogPendingGestureButtons.removeAll()
        for usage in affectedUsages {
            activeUsages.remove(usage)
            cancelRepeat(for: usage)
            usageExpiryTokens.removeValue(forKey: usage)
            usageExpiryTimers.removeValue(forKey: usage)?.cancel()
            usageHardCeilingTimers.removeValue(forKey: usage)?.cancel()
            suppressedUntilReleasedUsages.remove(usage)
            suppressedUsageExpiryTimers.removeValue(forKey: usage)?.cancel()
            nativePassthroughUsages.remove(usage)
            if directPassthroughUsages.remove(usage) != nil,
               let button = RemoteButton.usageMap[usage],
               let keyCode = button.directionKeyCode {
                _ = nativeKeyStatePoster(keyCode, false, [])
            }
        }
        for button in affectedButtons {
            gestureRecognizer.cancel(button)
            cancelDoubleClickTimeout(for: button)
            cancelLongPressTimeout(for: button)
            finishNonRepeatablePress(button)
            capturedApplicationScopes.removeValue(forKey: button)
        }
        if ownsActiveBTLESwitcher {
            appSwitcherCoordinator.finishIfActive(
                forOwner: switcherOwnerToken,
                reason: "btle_log_stopped",
                confirmed: false
            )
        }
        btleLogOwnsAppSwitcher = false
        emitActiveButtons()
    }

    func cancelPendingButtonActions() {
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        repeatTokens.removeAll()
        for usage in directPassthroughUsages {
            guard let button = RemoteButton.usageMap[usage], let keyCode = button.directionKeyCode else { continue }
            _ = nativeKeyStatePoster(keyCode, false, [])
        }
        directPassthroughUsages.removeAll()
        usageExpiryTokens.removeAll()
        usageExpiryTimers.values.forEach { $0.cancel() }
        usageExpiryTimers.removeAll()
        usageHardCeilingTimers.values.forEach { $0.cancel() }
        usageHardCeilingTimers.removeAll()
        suppressedUntilReleasedUsages.removeAll()
        suppressedUsageExpiryTimers.values.forEach { $0.cancel() }
        suppressedUsageExpiryTimers.removeAll()
        nonRepeatableReleaseTimers.values.forEach { $0.cancel() }
        nonRepeatableReleaseTimers.removeAll()
        nonRepeatablePressedButtons.removeAll()
        let wasT1VoiceHeld = t1VoiceHoldActive
        t1VoiceHoldActive = false
        if wasT1VoiceHeld {
            onT1VoiceHoldChanged?(profileID, false)
        }
        lastT1MouseHeader = nil
        lastT1MouseLogTime = 0
        resetGestureRecognition()
        activeUsages.removeAll()
        btleLogActiveUsages.removeAll()
        emitActiveButtons()
        appSwitcherCoordinator.finishIfActive(reason: "common_phrases_opened", confirmed: false)
    }

    func resetInputState() {
        clearTransientInputState(emitEmptyActiveButtons: true)
    }

    func clearTransientInputState(emitEmptyActiveButtons: Bool) {
        googleIndexedReportsIncludeID = false
        onInputReset?(profileID)
        appSwitcherCoordinator.cancelForInputReset(owner: switcherOwnerToken)
        if !activeDeviceIsSeized {
            for usage in activeUsages.subtracting(nativePassthroughUsages) {
                if let button = RemoteButton.usageMap[usage] {
                    armNativeSuppression(
                        button: button,
                        edge: .up,
                        fromBTLEServerLog: btleLogActiveUsages.contains(usage)
                    )
                }
            }
            for usage in interceptedT1PassthroughUsages {
                if let button = RemoteButton.usageMap[usage] {
                    armNativeSuppression(button: button, edge: .up)
                }
            }
        }
        btleLogActiveUsages.removeAll()
        repeatTimers.values.forEach { $0.cancel() }
        repeatTimers.removeAll()
        repeatTokens.removeAll()
        // No physical key-up is guaranteed after a disconnect or mapping reset.
        for usage in nativePassthroughUsages {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            for event in button.nativeEvents {
                if case .keyboard(let code) = event {
                    _ = nativeKeyStatePoster(code, false, [])
                }
            }
        }
        nativePassthroughUsages.removeAll()
        for usage in directPassthroughUsages {
            guard let button = RemoteButton.usageMap[usage], let keyCode = button.directionKeyCode else { continue }
            _ = nativeKeyStatePoster(keyCode, false, [])
        }
        directPassthroughUsages.removeAll()
        usageExpiryTokens.removeAll()
        usageExpiryTimers.values.forEach { $0.cancel() }
        usageExpiryTimers.removeAll()
        usageHardCeilingTimers.values.forEach { $0.cancel() }
        usageHardCeilingTimers.removeAll()
        suppressedUntilReleasedUsages.removeAll()
        suppressedUsageExpiryTimers.values.forEach { $0.cancel() }
        suppressedUsageExpiryTimers.removeAll()
        nonRepeatableReleaseTimers.values.forEach { $0.cancel() }
        nonRepeatableReleaseTimers.removeAll()
        nonRepeatablePressedButtons.removeAll()
        let wasT1VoiceHeld = t1VoiceHoldActive
        t1VoiceHoldActive = false
        if wasT1VoiceHeld {
            onT1VoiceHoldChanged?(profileID, false)
        }
        t1ReportUsageState.reset()
        clearT1PassthroughTracking()
        lastT1MouseHeader = nil
        lastT1MouseLogTime = 0
        resetGestureRecognition()
        activeUsages.removeAll()
        if emitEmptyActiveButtons {
            emitActiveButtons()
        }
    }

    func emitActiveButtons() {
        onActiveButtons?(profileID, RemoteButton.buttons(for: activeUsages.union(activeT1PassthroughUsages)))
    }

    var mappingDeliveryIsSafe: Bool {
        activeDeviceIsSeized || nativeSuppressionAvailable()
    }

    func pauseForUnavailableNativeFilter() {
        appSwitcherCoordinator.finishIfActive(reason: "native_filter_unavailable", confirmed: false)
        let message = LocalizedMessage("button_mapping.error.filter_unavailable")
        if status != message { updateStatus(message) }
    }

    func runtimePermissionsAreValid() -> Bool {
        runtimePermissions()
    }
}
