import Foundation

extension HIDRemoteMonitor {
    func connectSimulatedDevice(
        fingerprint: String,
        profileID: UUID?,
        isSeized: Bool = true
    ) {
        resetInputState()
        deviceFingerprint = fingerprint
        self.profileID = profileID
        activeDeviceIsSeized = isSeized
        onDeviceConnected?(profileID, fingerprint)
    }

    func handleSimulatedGoogleReport(
        reportID: UInt32,
        data: Data,
        descriptor: Data? = nil,
        source: String = "simulated",
        origin: HIDReportOrigin? = nil
    ) {
        let previous = currentReportIsGoogle
        let previousT1 = currentReportIsT1
        let previousDescriptor = currentReportDescriptor
        let previousOrigin = currentReportOrigin
        defer {
            currentReportIsGoogle = previous
            currentReportIsT1 = previousT1
            currentReportDescriptor = previousDescriptor
            currentReportOrigin = previousOrigin
        }
        currentReportIsGoogle = true
        currentReportIsT1 = false
        currentReportDescriptor = descriptor
        currentReportOrigin = origin ?? (source == "btle_log" ? .btleServerLog : .simulated)
        handleSimulatedReport(reportID: reportID, data: data, source: source)
    }

    func handleSimulatedT1Report(reportID: UInt32, data: Data) {
        let previousGoogle = currentReportIsGoogle
        let previousT1 = currentReportIsT1
        defer {
            currentReportIsGoogle = previousGoogle
            currentReportIsT1 = previousT1
        }
        currentReportIsGoogle = false
        currentReportIsT1 = true
        handleSimulatedReport(reportID: reportID, data: data)
    }

    func handleSimulatedReport(reportID: UInt32, data: Data, source: String = "simulated") {
        let previousOrigin = currentReportOrigin
        if source == "btle_log" {
            currentReportOrigin = .btleServerLog
        } else if source == "device" {
            currentReportOrigin = .iohid
        }
        defer { currentReportOrigin = previousOrigin }
        guard settings.customMappingEnabled || backOnlyMode else {
            diagnosticLogger("HID REPORT rejected reason=mapping_disabled source=\(source)")
            return
        }
        guard runtimePermissionsAreValid() else {
            diagnosticLogger("HID REPORT rejected reason=runtime_permission_revoked source=\(source)")
            releaseForRevokedPermissions()
            return
        }
        parseAndProcess(reportID: reportID, data: data, source: source)
    }

    func handleSimulatedBackOnlyReport(reportID: UInt32, data: Data) {
        let previousBackOnlyMode = backOnlyMode
        backOnlyMode = true
        defer { backOnlyMode = previousBackOnlyMode }
        handleSimulatedReport(reportID: reportID, data: data)
    }

    func disconnectSimulatedDevice() {
        deviceFingerprint = nil
        resetInputState()
        activeDeviceIsSeized = false
        nativeGoogleIOHIDObserved = false
        lastGoogleReportByOrigin.removeAll()
    }

    func shouldRejectBTLEServerLogGoogleReport(reportID: UInt32, data: Data) -> String? {
        guard currentReportIsGoogle, currentReportOrigin == .btleServerLog else { return nil }
        if nativeGoogleIOHIDObserved {
            return "native_iohid_verified"
        }
        if settings.isOnboardingComplete,
           let profileID,
           let profile = settings.remoteDeviceProfiles.first(where: { $0.id == profileID && $0.model.isChromecastRemote }),
           profile.effectiveG9N9NInputMode == .full {
            return "native_full_mode"
        }
        if let descriptor = currentReportDescriptor {
            if G9N9NProtocol.usesIndexedConsumerLayout(descriptor) {
                guard reportID == 1, (1...2).contains(data.count) else {
                    return "descriptor_report_mismatch"
                }
            } else {
                guard reportID == 2, data.count == 2 else {
                    return "descriptor_report_mismatch"
                }
            }
        }
        return nil
    }

    func recordNativeGoogleIOHIDIfNeeded(usages: Set<UInt16>, origin: HIDReportOrigin) {
        guard currentReportIsGoogle, origin == .iohid, usages.count == 1 else { return }
        if !nativeGoogleIOHIDObserved {
            nativeGoogleIOHIDObserved = true
            onNativeGoogleIOHIDVerified?(profileID)
        }
    }

    /// The same report may reach both IOHID and the log (with or without the leading
    /// report-ID byte on report 1); deduplicate by normalized decoded usages within 150 ms.
    func isDuplicateGoogleReport(
        reportID: UInt32,
        usages: Set<UInt16>,
        origin: HIDReportOrigin,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        guard currentReportIsGoogle, origin == .iohid || origin == .btleServerLog else {
            return false
        }
        defer { lastGoogleReportByOrigin[origin] = (reportID, usages, now) }
        return lastGoogleReportByOrigin.contains { otherOrigin, last in
            otherOrigin != origin &&
                last.reportID == reportID &&
                last.usages == usages &&
                now - last.time < 0.15
        }
    }

    func parseAndProcess(reportID: UInt32, data: Data, source: String) {
        if let rejectReason = shouldRejectBTLEServerLogGoogleReport(reportID: reportID, data: data) {
            diagnosticLogger("HID GOOGLE report dropped reason=\(rejectReason) source=\(source)")
            return
        }
        guard let parsed = parseReport(reportID: reportID, data: data, source: source) else {
            return
        }
        recordNativeGoogleIOHIDIfNeeded(usages: parsed.mappedUsages, origin: currentReportOrigin)
        if isDuplicateGoogleReport(reportID: reportID, usages: parsed.mappedUsages, origin: currentReportOrigin) {
            if currentReportOrigin == .iohid && !activeDeviceIsSeized {
                for button in RemoteButton.buttons(for: parsed.mappedUsages) {
                    eventSuppressor.arm(button: button, edge: .down)
                }
            }
            diagnosticLogger("HID GOOGLE report dropped reason=duplicate source=\(source)")
            return
        }
        processParsedReport(reportID: reportID, data: data, source: source, parsed: parsed)
    }

    func parseReport(reportID: UInt32, data: Data, source: String) -> ParsedHIDReport? {
        if currentReportIsT1 {
            let decoded = T1RemoteProtocol.decodeHIDReportForMonitor(reportID: reportID, data: data)
            switch decoded.result {
            case let .usages(usages, voiceHoldPressed):
                if reportID == T1RemoteProtocol.keyboardReportID,
                   t1VoiceHoldActive != voiceHoldPressed {
                    t1VoiceHoldActive = voiceHoldPressed
                    onT1VoiceHoldChanged?(profileID, voiceHoldPressed)
                }
                return ParsedHIDReport(
                    mappedUsages: t1ReportUsageState.update(reportID: reportID, usages: usages),
                    observedPassthroughUsages: t1PassthroughUsageState.update(
                        reportID: reportID,
                        usages: decoded.observedPassthroughUsages
                    )
                )
            case .ignore:
                logIgnoredT1Report(reportID: reportID, data: data, source: source)
                refreshActiveUsageExpiries()
                return nil
            case .invalid:
                diagnosticLogger(
                    "HID REPORT rejected reason=parse_failed source=\(source) " +
                        "id=\(reportID) bytes=\(data.count)"
                )
                return nil
            }
        }
        // On IOHID device callbacks ("device"), report-ID-prefixed descriptors always
        // carry the ID byte, so a shortened [1, 0] release is never payload-only Power.
        let payloadOnly = currentReportOrigin == .btleServerLog
        let indexedGoogleReport = currentReportIsGoogle && reportID == 1 &&
            G9N9NProtocol.usesIndexedConsumerLayout(currentReportDescriptor)
        let googleData = !payloadOnly && indexedGoogleReport &&
            (source == "device" || googleIndexedReportsIncludeID) && data == Data([1, 0])
            ? Data([1, 0, 0]) : data
        let decoded = currentReportIsGoogle
            ? G9N9NProtocol.usages(
                reportID: reportID,
                data: googleData,
                descriptor: currentReportDescriptor,
                payloadOnly: payloadOnly
            )
            : RemoteHIDReportParser.usages(reportID: reportID, data: data)
        guard let usages = decoded else {
            diagnosticLogger(
                "HID REPORT rejected reason=parse_failed source=\(source) " +
                    "id=\(reportID) bytes=\(data.count)"
            )
            return nil
        }
        return ParsedHIDReport(mappedUsages: usages, observedPassthroughUsages: [])
    }

    func logIgnoredT1Report(reportID: UInt32, data: Data, source: String) {
        let payload = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        if reportID == T1RemoteProtocol.vendorReportID {
            diagnosticLogger(
                "HID T1 vendor_report source=\(source) id=\(reportID) bytes=\(data.count) payload=\(payload)"
            )
            return
        }
        if reportID == T1RemoteProtocol.mouseReportID {
            let header = data.prefix(2)
            let now = ProcessInfo.processInfo.systemUptime
            let hasMotionOrButtons = data.dropFirst().contains(where: { $0 != 0 })
            let shouldLog = header != lastT1MouseHeader ||
                (hasMotionOrButtons && now - lastT1MouseLogTime >= 0.5)
            guard shouldLog else { return }
            lastT1MouseHeader = header
            lastT1MouseLogTime = now
            diagnosticLogger(
                "HID T1 mouse_report source=\(source) id=\(reportID) bytes=\(data.count) payload=\(payload)"
            )
            return
        }
        diagnosticLogger(
            "HID T1 ignored_report source=\(source) id=\(reportID) bytes=\(data.count) payload=\(payload)"
        )
    }

    func processParsedReport(
        reportID: UInt32,
        data: Data,
        source: String,
        parsed: ParsedHIDReport
    ) {
        if currentReportIsGoogle, reportID == 1,
           G9N9NProtocol.usesIndexedConsumerLayout(currentReportDescriptor),
           data.count == 3, data.first == 1 {
            googleIndexedReportsIncludeID = true
        }
        let usages = parsed.mappedUsages
        suppressedUntilReleasedT1PassthroughUsages = suppressedUntilReleasedT1PassthroughUsages
            .intersection(parsed.observedPassthroughUsages)
        for usage in suppressedUntilReleasedT1PassthroughUsages {
            refreshSuppressedT1PassthroughExpiry(usage)
        }
        let observedPassthrough = parsed.observedPassthroughUsages
            .subtracting(suppressedUntilReleasedT1PassthroughUsages)
        let observedAll = usages.union(observedPassthrough)
        let releasedPassthrough = activeT1PassthroughUsages.subtracting(observedPassthrough)
        let pressedPassthrough = observedPassthrough.subtracting(activeT1PassthroughUsages)
        activeT1PassthroughUsages = observedPassthrough
        diagnosticLogger(
            "HID REPORT accepted source=\(source) id=\(reportID) bytes=\(data.count) " +
                "usage_count=\(observedAll.count) buttons=\(Self.buttonList(for: observedAll))"
        )
        processT1PassthroughReleases(for: releasedPassthrough)
        if !pressedPassthrough.isEmpty {
            processT1PassthroughPresses(for: pressedPassthrough)
        }
        for usage in pressedPassthrough {
            scheduleT1PassthroughHardCeiling(for: usage)
        }
        for usage in activeT1PassthroughUsages {
            refreshT1PassthroughExpiry(usage)
        }
        if backOnlyMode {
            processBackOnly(usages: usages.intersection([RemoteButton.back.hidUsage]))
        } else {
            process(usages: usages)
        }
    }

    static func handlesAppSwitcherControl(_ button: RemoteButton) -> Bool {
        switch button {
        case .ok, .back, .left, .right, .up, .down:
            return true
        default:
            return false
        }
    }

    func processT1PassthroughReleases(for released: Set<UInt16>) {
        for usage in released.sorted() {
            t1PassthroughExpiryTokens.removeValue(forKey: usage)
            t1PassthroughExpiryTimers.removeValue(forKey: usage)?.cancel()
            t1PassthroughHardCeilingTimers.removeValue(forKey: usage)?.cancel()
            suppressedT1PassthroughExpiryTimers.removeValue(forKey: usage)?.cancel()
            suppressedUntilReleasedT1PassthroughUsages.remove(usage)
            guard interceptedT1PassthroughUsages.remove(usage) != nil else { continue }
            guard let button = RemoteButton.usageMap[usage] else { continue }
            diagnosticLogger(
                "HID T1 modal_passthrough phase=release button=\(button.rawValue)"
            )
            if !activeDeviceIsSeized {
                armNativeSuppression(button: button, edge: .up)
            }
            _ = onRuntimeButton?(profileID, button, .release)
        }
    }

    func processT1PassthroughPresses(for pressed: Set<UInt16>) {
        for usage in pressed.sorted() {
            guard let button = RemoteButton.usageMap[usage] else { continue }
            var resolvedProfileID = profileID
            if let deviceFingerprint,
               let routedProfileID = onPassthroughButtonObserved?(profileID, deviceFingerprint, button) {
                if profileID == nil {
                    profileID = routedProfileID
                }
                resolvedProfileID = routedProfileID
            }
            guard !backOnlyMode else { continue }
            let targetProfileID = resolvedProfileID ?? profileID
            let reportingModel = targetProfileID.flatMap { id in
                settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model
            } ?? .t1Remote
            let suppressConfiguredAction = OnboardingControlValidationPolicy.suppressConfiguredActions(
                at: settings.onboardingStep,
                source: settings.onboardingControlSource,
                reportingModel: reportingModel,
                onboardingWindowIsActive: onboardingWindowIsActive()
            )
            guard !suppressConfiguredAction else { continue }

            let claimedByRuntime = targetProfileID != nil && claimsRuntimeButton?(targetProfileID, button) == true
            let claimedByAppSwitcher = appSwitcherCoordinator.isActive && Self.handlesAppSwitcherControl(button)
            guard claimedByRuntime || claimedByAppSwitcher else { continue }

            guard mappingDeliveryIsSafe else {
                pauseForUnavailableNativeFilter()
                continue
            }
            if !activeDeviceIsSeized {
                armNativeSuppression(button: button, edge: .down)
            }
            interceptedT1PassthroughUsages.insert(usage)
            diagnosticLogger(
                "HID T1 modal_passthrough phase=press button=\(button.rawValue) " +
                    "runtime=\(claimedByRuntime) app_switcher=\(claimedByAppSwitcher)"
            )
            if claimedByRuntime,
               onRuntimeButton?(targetProfileID, button, .press) == true {
                continue
            }
            if appSwitcherCoordinator.isActive, handleAppSwitcherControlPress(button) {
                continue
            }
        }
    }

    func process(usages rawUsages: Set<UInt16>) {
        suppressedUntilReleasedUsages = suppressedUntilReleasedUsages.intersection(rawUsages)
        for usage in suppressedUntilReleasedUsages {
            refreshSuppressedUsageExpiry(usage)
        }
        let usages = rawUsages.subtracting(suppressedUntilReleasedUsages)
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        if !pressed.isEmpty || !released.isEmpty {
            diagnosticLogger(
                "HID EDGE pressed=\(Self.buttonList(for: pressed)) " +
                    "released=\(Self.buttonList(for: released))"
            )
        }
        activeUsages = usages
        let pressedButtons = RemoteButton.buttons(for: pressed)
        if currentReportOrigin == .btleServerLog {
            btleLogActiveUsages.formUnion(pressed)
            btleLogPendingGestureButtons.formUnion(pressedButtons)
        } else if currentReportOrigin == .iohid {
            btleLogActiveUsages.subtract(pressed)
            btleLogPendingGestureButtons.subtract(pressedButtons)
        }
        for usage in released {
            usageExpiryTokens.removeValue(forKey: usage)
            usageExpiryTimers.removeValue(forKey: usage)?.cancel()
            usageHardCeilingTimers.removeValue(forKey: usage)?.cancel()
            suppressedUsageExpiryTimers.removeValue(forKey: usage)?.cancel()
            suppressedUntilReleasedUsages.remove(usage)
        }
        for usage in pressed {
            scheduleHardCeiling(for: usage)
        }
        for usage in usages { refreshUsageExpiry(usage) }
        emitActiveButtons()
        let reportButtons = RemoteButton.buttons(for: usages)
        var emittedObservedReport = false

        for usage in pressed.sorted() {
            // A failed action may stop/reset the monitor. Do not dispatch further
            // presses from that stale snapshot, but still finish its release edges.
            guard activeUsages == usages else { break }
            guard let button = RemoteButton.usageMap[usage] else { continue }
            let preflightProfileID = profileID
            let preflightDirectPassthrough = isDirectPassthrough(button: button, profileID: preflightProfileID)
            let preflightRecognizesDoubleClick = !preflightDirectPassthrough && settings.configuredAction(
                for: button,
                trigger: .doubleClick,
                profileID: preflightProfileID
            ).action != .disabled
            let preflightRecognizesLongPress = !preflightDirectPassthrough && settings.configuredAction(
                for: button,
                trigger: .longPress,
                profileID: preflightProfileID
            ).action != .disabled && !settings.allowsHoldRepeat(for: button, profileID: preflightProfileID)
            let preflightAction = settings.action(for: button, profileID: preflightProfileID)
            let usesNativePassthrough = preflightProfileID != nil &&
                !preflightDirectPassthrough &&
                claimsRuntimeButton?(preflightProfileID, button) != true && shouldUseNativePassthrough(
                button: button,
                action: preflightAction,
                recognizesDoubleClick: preflightRecognizesDoubleClick,
                recognizesLongPress: preflightRecognizesLongPress
            )
            if !activeDeviceIsSeized, !usesNativePassthrough {
                armNativeSuppression(button: button, edge: .down)
            }
            var shouldPerformAction = true
            if let deviceFingerprint,
               let routing = onButtonPressed?(profileID, deviceFingerprint, button) {
                if profileID == nil {
                    profileID = routing.profileID
                }
                shouldPerformAction = routing.shouldPerformAction
            }
            if !emittedObservedReport, !reportButtons.isEmpty {
                emittedObservedReport = true
                onObservedButtonReport?(profileID, reportButtons)
            }
            guard let profileID, shouldPerformAction else {
                if !activeDeviceIsSeized, usesNativePassthrough {
                    armNativeSuppression(button: button, edge: .down)
                }
                continue
            }

            // Observing a report is safe without a filter; injecting an additional action
            // is not. Default native arrows retain their one-to-one passthrough path.
            guard mappingDeliveryIsSafe || usesNativePassthrough else {
                pauseForUnavailableNativeFilter()
                continue
            }

            if onRuntimeButton?(profileID, button, .press) == true {
                if !activeDeviceIsSeized, usesNativePassthrough { armNativeSuppression(button: button, edge: .down) }
                continue
            }
            let recognizesDoubleClick = settings.configuredAction(
                for: button,
                trigger: .doubleClick,
                profileID: profileID
            ).action != .disabled
            let recognizesLongPress = settings.configuredAction(
                for: button,
                trigger: .longPress,
                profileID: profileID
            ).action != .disabled && !settings.allowsHoldRepeat(for: button, profileID: profileID)
            let action = settings.action(for: button, profileID: profileID)
            if appSwitcherCoordinator.isActive,
               handleAppSwitcherControlPress(button) {
                continue
            }
            if appSwitcherCoordinator.isActive, button == .tv {
                diagnosticLogger(
                    "HID GESTURE button=tv trigger=singleClick path=app_switcher"
                )
                guard performAppSwitcherAction(for: button, trigger: .singleClick) else {
                    continue
                }
                continue
            }
            if appSwitcherCoordinator.isActive, action == .appSwitcher,
               !recognizesDoubleClick, !recognizesLongPress {
                diagnosticLogger(
                    "HID GESTURE button=\(button.rawValue) trigger=singleClick " +
                        "path=app_switcher"
                )
                guard performAppSwitcherAction(for: button, trigger: .singleClick) else {
                    continue
                }
                continue
            }
            if appSwitcherCoordinator.isActive, action != .appSwitcher {
                appSwitcherCoordinator.finishLifecycle(
                    reason: "unrelated_button_\(button.rawValue)",
                    confirmed: false
                )
            }
            if usesNativePassthrough {
                nativePassthroughUsages.insert(usage)
                diagnosticLogger(
                    "HID NATIVE PASSTHROUGH button=\(button.rawValue) action=\(action.rawValue)"
                )
                continue
            }
            if isDirectPassthrough(button: button, profileID: profileID) {
                guard mappingDeliveryIsSafe else {
                    pauseForUnavailableNativeFilter()
                    continue
                }
                guard let keyCode = button.directionKeyCode else { continue }
                guard runtimePermissionsAreValid() else {
                    releaseForRevokedPermissions()
                    continue
                }
                directPassthroughUsages.insert(usage)
                scheduleHardCeiling(for: usage)
                refreshUsageExpiry(usage)
                diagnosticLogger(
                    "HID DIRECT PASSTHROUGH press button=\(button.rawValue) keyCode=\(keyCode)"
                )
                AppLogger.shared.write(
                    "HID BUTTON button=\(button.rawValue) trigger=directPassthrough action=directPassthrough"
                )
                _ = nativeKeyStatePoster(keyCode, true, [])
                continue
            }
            if recognizesDoubleClick || recognizesLongPress || gestureRecognizer.isTracking(button) {
                let commands = gestureRecognizer.press(
                    button,
                    recognizesDoubleClick: recognizesDoubleClick,
                    recognizesLongPress: recognizesLongPress
                )
                guard processGestureCommands(commands) else { continue }
            } else {
                guard shouldAcceptRawPress(
                    button: button,
                    action: action,
                    frontmostBundleIdentifier: frontmostBundleIdentifier()
                ) else { continue }
                diagnosticLogger(
                    "HID GESTURE button=\(button.rawValue) trigger=singleClick path=raw " +
                        "long_press=\(settings.configuredAction(for: button, trigger: .longPress, profileID: profileID).action.rawValue) " +
                        "double_click=\(settings.configuredAction(for: button, trigger: .doubleClick, profileID: profileID).action.rawValue) " +
                        "hold_repeat=\(settings.allowsHoldRepeat(for: button, profileID: profileID)) " +
                        "preflight_bound=\(preflightProfileID != nil)"
                )
                guard performConfiguredAction(for: button, trigger: .singleClick) else { continue }
            }
            startRepeatIfNeeded(usage: usage, button: button, action: action)
        }

        processReleases(for: released)
    }

    func processReleases(for released: Set<UInt16>) {
        for usage in released {
            let usedNativePassthrough = nativePassthroughUsages.remove(usage) != nil
            let usedDirectPassthrough = directPassthroughUsages.remove(usage) != nil
            let wasFromBTLEServerLog = btleLogActiveUsages.remove(usage) != nil || currentReportOrigin == .btleServerLog
            if !activeDeviceIsSeized, !usedNativePassthrough,
               let button = RemoteButton.usageMap[usage] {
                armNativeSuppression(button: button, edge: .up, fromBTLEServerLog: wasFromBTLEServerLog)
            }
            cancelRepeat(for: usage)
            if let button = RemoteButton.usageMap[usage] {
                if onRuntimeButton?(profileID, button, .release) == true {
                    if usedDirectPassthrough, let keyCode = button.directionKeyCode {
                        _ = nativeKeyStatePoster(keyCode, false, [])
                    }
                    continue
                }
                if usedDirectPassthrough {
                    usageHardCeilingTimers.removeValue(forKey: usage)?.cancel()
                    usageExpiryTokens.removeValue(forKey: usage)
                    usageExpiryTimers.removeValue(forKey: usage)?.cancel()
                    if let keyCode = button.directionKeyCode {
                        _ = nativeKeyStatePoster(keyCode, false, [])
                    }
                    diagnosticLogger(
                        "HID DIRECT PASSTHROUGH release button=\(button.rawValue)"
                    )
                    continue
                }
                scheduleNonRepeatableRelease(for: button)
                guard processGestureCommands(gestureRecognizer.release(button)) else { continue }
            }
        }
    }

    func scheduleHardCeiling(for usage: UInt16, afterMilliseconds: UInt64 = HIDRemoteTiming.maximumContinuousHoldMilliseconds) {
        usageHardCeilingTimers.removeValue(forKey: usage)?.cancel()
        guard RemoteButton.usageMap[usage] != nil else { return }
        usageHardCeilingTimers[usage] = scheduler.schedule(
            afterMilliseconds: afterMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            self?.recoverHardCeilingHold(for: usage)
        }
    }

    func refreshActiveUsageExpiries() {
        for usage in activeUsages {
            refreshUsageExpiry(usage)
        }
        for usage in suppressedUntilReleasedUsages {
            refreshSuppressedUsageExpiry(usage)
        }
        for usage in activeT1PassthroughUsages {
            refreshT1PassthroughExpiry(usage)
        }
        for usage in suppressedUntilReleasedT1PassthroughUsages {
            refreshSuppressedT1PassthroughExpiry(usage)
        }
    }

    func refreshUsageExpiry(_ usage: UInt16) {
        usageExpiryTokens.removeValue(forKey: usage)
        usageExpiryTimers.removeValue(forKey: usage)?.cancel()
        guard RemoteButton.usageMap[usage] != nil else { return }
        let token = UUID()
        usageExpiryTokens[usage] = token
        usageExpiryTimers[usage] = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.missingReleaseTimeoutMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self, self.usageExpiryTokens[usage] == token else { return }
            self.recoverMissingRelease(for: usage)
        }
    }

    func refreshSuppressedUsageExpiry(_ usage: UInt16) {
        suppressedUsageExpiryTimers.removeValue(forKey: usage)?.cancel()
        suppressedUsageExpiryTimers[usage] = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.missingReleaseTimeoutMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self else { return }
            self.suppressedUntilReleasedUsages.remove(usage)
            self.suppressedUsageExpiryTimers.removeValue(forKey: usage)
        }
    }

    func synthesizeReleaseState(for usage: UInt16, reason: String) {
        usageExpiryTokens.removeValue(forKey: usage)
        usageExpiryTimers.removeValue(forKey: usage)?.cancel()
        usageHardCeilingTimers.removeValue(forKey: usage)?.cancel()
        let wasFromBTLEServerLog = btleLogActiveUsages.remove(usage) != nil
        guard let button = RemoteButton.usageMap[usage] else { return }
        guard activeUsages.contains(usage) || nonRepeatablePressedButtons.contains(button) else { return }
        diagnosticLogger("HID BUTTON recovered reason=\(reason) button=\(button.rawValue)")
        cancelRepeat(for: usage)
        cancelDoubleClickTimeout(for: button)
        cancelLongPressTimeout(for: button)
        gestureRecognizer.cancel(button)
        finishNonRepeatablePress(button)
        if nativePassthroughUsages.remove(usage) != nil {
            for event in button.nativeEvents {
                if case .keyboard(let code) = event {
                    _ = nativeKeyStatePoster(code, false, [])
                }
            }
        } else if directPassthroughUsages.remove(usage) != nil {
            if let keyCode = button.directionKeyCode {
                _ = nativeKeyStatePoster(keyCode, false, [])
            }
            if !activeDeviceIsSeized {
                armNativeSuppression(button: button, edge: .up, fromBTLEServerLog: wasFromBTLEServerLog)
            }
        } else if !activeDeviceIsSeized {
            armNativeSuppression(button: button, edge: .up, fromBTLEServerLog: wasFromBTLEServerLog)
        }
        activeUsages.remove(usage)
        t1ReportUsageState.remove(usage)
        _ = onRuntimeButton?(profileID, button, .release)
        emitActiveButtons()
    }

    func recoverMissingRelease(for usage: UInt16) {
        // Some remotes send no reports during a repeat or native passthrough hold.
        // Check again in case repeat stops before the independent hard ceiling.
        if repeatTimers[usage] != nil || nativePassthroughUsages.contains(usage) || directPassthroughUsages.contains(usage) {
            refreshUsageExpiry(usage)
            return
        }
        suppressedUsageExpiryTimers.removeValue(forKey: usage)?.cancel()
        suppressedUntilReleasedUsages.remove(usage)
        synthesizeReleaseState(for: usage, reason: "missing_release")
    }

    func recoverHardCeilingHold(for usage: UInt16) {
        suppressedUntilReleasedUsages.insert(usage)
        refreshSuppressedUsageExpiry(usage)
        synthesizeReleaseState(for: usage, reason: "hard_ceiling")
    }

    func scheduleT1PassthroughHardCeiling(
        for usage: UInt16,
        afterMilliseconds: UInt64 = HIDRemoteTiming.maximumContinuousHoldMilliseconds
    ) {
        t1PassthroughHardCeilingTimers.removeValue(forKey: usage)?.cancel()
        guard RemoteButton.usageMap[usage] != nil else { return }
        t1PassthroughHardCeilingTimers[usage] = scheduler.schedule(
            afterMilliseconds: afterMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            self?.recoverT1PassthroughHardCeilingHold(for: usage)
        }
    }

    func refreshT1PassthroughExpiry(_ usage: UInt16) {
        t1PassthroughExpiryTokens.removeValue(forKey: usage)
        t1PassthroughExpiryTimers.removeValue(forKey: usage)?.cancel()
        guard RemoteButton.usageMap[usage] != nil else { return }
        let token = UUID()
        t1PassthroughExpiryTokens[usage] = token
        t1PassthroughExpiryTimers[usage] = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.missingReleaseTimeoutMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self, self.t1PassthroughExpiryTokens[usage] == token else { return }
            self.recoverMissingT1PassthroughRelease(for: usage)
        }
    }

    func refreshSuppressedT1PassthroughExpiry(_ usage: UInt16) {
        suppressedT1PassthroughExpiryTimers.removeValue(forKey: usage)?.cancel()
        suppressedT1PassthroughExpiryTimers[usage] = scheduler.schedule(
            afterMilliseconds: HIDRemoteTiming.missingReleaseTimeoutMilliseconds,
            repeatingEveryMilliseconds: nil
        ) { [weak self] in
            guard let self else { return }
            self.suppressedUntilReleasedT1PassthroughUsages.remove(usage)
            self.suppressedT1PassthroughExpiryTimers.removeValue(forKey: usage)
        }
    }

    func synthesizeT1PassthroughReleaseState(for usage: UInt16, reason: String) {
        t1PassthroughExpiryTokens.removeValue(forKey: usage)
        t1PassthroughExpiryTimers.removeValue(forKey: usage)?.cancel()
        t1PassthroughHardCeilingTimers.removeValue(forKey: usage)?.cancel()
        let wasActive = activeT1PassthroughUsages.remove(usage) != nil
        let wasIntercepted = interceptedT1PassthroughUsages.remove(usage) != nil
        t1PassthroughUsageState.remove(usage)
        guard wasActive || wasIntercepted else { return }
        guard let button = RemoteButton.usageMap[usage] else { return }
        if wasIntercepted {
            diagnosticLogger("HID T1 modal_passthrough recovered reason=\(reason) button=\(button.rawValue)")
            if !activeDeviceIsSeized {
                armNativeSuppression(button: button, edge: .up)
            }
            _ = onRuntimeButton?(profileID, button, .release)
        }
        emitActiveButtons()
    }

    func recoverMissingT1PassthroughRelease(for usage: UInt16) {
        suppressedT1PassthroughExpiryTimers.removeValue(forKey: usage)?.cancel()
        suppressedUntilReleasedT1PassthroughUsages.remove(usage)
        synthesizeT1PassthroughReleaseState(for: usage, reason: "missing_release")
    }

    func recoverT1PassthroughHardCeilingHold(for usage: UInt16) {
        suppressedUntilReleasedT1PassthroughUsages.insert(usage)
        refreshSuppressedT1PassthroughExpiry(usage)
        synthesizeT1PassthroughReleaseState(for: usage, reason: "hard_ceiling")
    }

    func clearT1PassthroughTracking() {
        t1PassthroughUsageState.reset()
        activeT1PassthroughUsages.removeAll()
        interceptedT1PassthroughUsages.removeAll()
        t1PassthroughExpiryTokens.removeAll()
        t1PassthroughExpiryTimers.values.forEach { $0.cancel() }
        t1PassthroughExpiryTimers.removeAll()
        t1PassthroughHardCeilingTimers.values.forEach { $0.cancel() }
        t1PassthroughHardCeilingTimers.removeAll()
        suppressedUntilReleasedT1PassthroughUsages.removeAll()
        suppressedT1PassthroughExpiryTimers.values.forEach { $0.cancel() }
        suppressedT1PassthroughExpiryTimers.removeAll()
    }

    func processBackOnly(usages rawUsages: Set<UInt16>) {
        suppressedUntilReleasedUsages = suppressedUntilReleasedUsages.intersection(rawUsages)
        for usage in suppressedUntilReleasedUsages {
            refreshSuppressedUsageExpiry(usage)
        }
        let usages = rawUsages.subtracting(suppressedUntilReleasedUsages)
        let pressed = usages.subtracting(activeUsages)
        let released = activeUsages.subtracting(usages)
        for usage in released {
            usageExpiryTokens.removeValue(forKey: usage)
            usageExpiryTimers.removeValue(forKey: usage)?.cancel()
            usageHardCeilingTimers.removeValue(forKey: usage)?.cancel()
            suppressedUsageExpiryTimers.removeValue(forKey: usage)?.cancel()
            suppressedUntilReleasedUsages.remove(usage)
            if let button = RemoteButton.usageMap[usage] {
                _ = onRuntimeButton?(profileID, button, .release)
            }
        }
        for usage in pressed {
            scheduleHardCeiling(for: usage)
            if let button = RemoteButton.usageMap[usage] {
                _ = onRuntimeButton?(profileID, button, .press)
            }
        }
        activeUsages = usages
        for usage in usages { refreshUsageExpiry(usage) }
        emitActiveButtons()
        guard pressed.contains(RemoteButton.back.hidUsage) else { return }
        let configured = ConfiguredButtonAction(action: .deleteBackward, shortcut: nil)
        guard actionPerformer(.back, .singleClick, configured) else {
            if !runtimePermissionsAreValid() { releaseForRevokedPermissions() }
            return
        }
        AppLogger.shared.write(
            "HID BUTTON button=back trigger=singleClick action=deleteBackward path=back_only"
        )
    }
}
