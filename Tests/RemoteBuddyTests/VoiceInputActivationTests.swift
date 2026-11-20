import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Ordered voice input activation")
@MainActor
struct VoiceInputActivationTests {
    private func makeModel(voiceTool: OnboardingVoiceTool = .doubao) throws -> (model: BridgeAppModel, defaults: UserDefaults, suite: String) {
        let suite = "voice-activation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let settings = AppSettings(defaults: defaults)
        settings.setOnboardingVoiceTool(voiceTool)
        settings.voiceKeyMode = .function
        return (BridgeAppModel(settings: settings, initialAudioDevices: []), defaults, suite)
    }

    private func beginInlineSession(_ monitor: PreferredInputSourceMonitor) -> Bool {
        var result = false
        monitor.beginVoiceSession { result = $0 }
        return result
    }

    private func useReadyDestination(_ model: BridgeAppModel) {
        model.voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(snapshot: {
            VoiceInputDestinationSnapshot(bundleIdentifier: "test.editor", role: "AXTextArea", subrole: "",
                enabled: true, editable: true, protectedContent: false, semanticText: "input")
        })
    }

    @Test func tapPreparationWaitsForAutomaticInputSourceAndCancelsLateActivation() throws {
        let tool = OnboardingVoiceTool.doubao
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        useReadyDestination(model)
        model.settings.setOnboardingVoiceTool(tool)
        let target = try #require(tool.automaticVoiceSessionInputSourceID)
        var source = "ABC"
        var activate: ((Bool) -> Void)?
        var continuing: (() -> Bool)?
        var results: [VoiceInputDestinationWaitResult] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { tool }, prepareInputSource: { _ in source = target; return .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            // Passive path: the wait closure captures `activate`; the caller drives done().
            // Source starts as "ABC" so the first wait simulates the IME not switching yet.
            waitForInputSourceActivation: { _, _, active, done in continuing = active; activate = done },
            installMonitor: { _ in nil }, logger: { _ in })
        let clock = ControlledTestScheduler()
        let wait = model.prepareIntegratedVoiceInputDestination(completion: { results.append($0) },
            schedule: clock.voiceSchedule)
        guard case let .waiting(operation) = wait else { Issue.record("Expected source activation wait"); return }
        #expect(results.isEmpty)
        operation.cancel()
        #expect(continuing?() == false)
        activate?(true)
        #expect(results.isEmpty)
        // source was never switched by prepareInputSource (passive skips it) or by the IME.
        #expect(source == "ABC")
        // Second attempt: simulate IME switching the source before activate fires.
        let nextWait = model.prepareIntegratedVoiceInputDestination(completion: { results.append($0) }, schedule: clock.voiceSchedule)
        source = target
        withExtendedLifetime(nextWait) { activate?(true) }
        #expect(results == [.ready])
        model.preferredInputSourceMonitor.markVoiceTriggerSubmitted()
        model.preferredInputSourceMonitor.endVoiceSession()
        #expect(source == target)
    }

    @Test func productionTapSessionMarksSuccessfulTriggerAndRetainsInputSource() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try #require(OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        var source = "ABC"
        var edges: [Bool] = []
        useReadyDestination(model)
        model.settings.voiceKeyMode = .rightOption
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao }, prepareInputSource: { _ in source = target; return .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            // Simulate the IME switching the source itself during the passive wait.
            waitForInputSourceActivation: { requested, _, _, done in source = requested; done(true) },
            installMonitor: { _ in nil }, logger: { _ in })
        model.voiceTapTrigger = VoiceTapTrigger(selectedMode: { .rightOption }, setKey: { _, down in
            #expect(source == target)
            edges.append(down)
            return true
        })
        let clock = ControlledTestScheduler()
        model.voiceFnTapSession = model.makeVoiceFnTapSession(schedule: clock.voiceSchedule)
        model.voiceFnTapSession.setEnabled(true)
        #expect(model.voiceFnTapSession.startVoice())
        clock.runAll()
        #expect(edges == [true, false])
        model.voiceFnTapSession.setEnabled(false)
        #expect(source == target)
    }

    @Test func firstFnWaitsForActivationAndLeavesSourceSelectedAfterStop() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try #require(OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        var source = "previous"
        var events: [String] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao }, prepareInputSource: { _ in events.append("select"); return .selected },
            currentInputSourceID: { source },
            restoreInputSource: { source = $0; events.append("restore"); return .selected },
            waitForInputSourceActivation: { requested, current, continuing, done in
                // Passive path: IME switches source itself during the wait window.
                #expect(current() == "previous")
                source = requested
                events.append("activated")
                done(continuing())
            }, installMonitor: { _ in nil }, logger: { _ in })
        for _ in 0..<2 {
            let started = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
                keySetter: { mode, down in
                    #expect(mode == .function)
                    #expect(source == target)
                    events.append(down ? "fn_down" : "fn_up")
                    return true
                })
            #expect(started)
            let stopped = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
                keySetter: { _, _ in events.append("fn_up"); return true })
            #expect(stopped)
            #expect(source == target)
            #expect(!model.voiceKeyLatch.isHeld)
            #expect(!model.preferredInputSourceMonitor.functionKeyIsPressedForDiagnostics)
        }
        // "select" (prepareInputSource) is not called on the passive path; the IME
        // switches the source itself, which is captured as "activated" in the wait callback.
        #expect(events == ["activated", "fn_down", "fn_up", "fn_down", "fn_up"])
    }

    @Test func cancelledActivationCannotSendFnDownOrBlockTheNextSession() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = "previous"
        var cancel = true
        var posted: [Bool] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao }, prepareInputSource: { _ in .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { target, _, continuing, done in
                source = target
                if cancel {
                    let stopped = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
                        keySetter: { _, down in posted.append(down); return true })
                    #expect(stopped)

                }
                done(continuing())
            }, installMonitor: { _ in nil }, logger: { _ in })
        let cancelled = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in posted.append(down); return true })
        #expect(!cancelled)
        #expect(posted.isEmpty)
        #expect(model.pendingVoiceKeyMode == nil)
        #expect(!model.voiceKeyLatch.isHeld)
        #expect(source == "previous")
        cancel = false
        let restarted = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in posted.append(down); return true })
        #expect(restarted)
        #expect(posted == [true])
        let cleaned = model.releaseVoiceKeyIfNeeded(releaseKey: { _ in posted.append(false); return true })
        #expect(cleaned)
        #expect(posted == [true, false])
        #expect(source == OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
    }

    @Test func activationTimeoutRollsBackBeforePostingAnyKey() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = "previous"
        var posts = 0
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao }, prepareInputSource: { _ in .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { _, _, _, done in done(false) }, installMonitor: { _ in nil }, logger: { _ in })
        let started = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in posts += 1; return true })
        #expect(!started)
        #expect(posts == 0)
        #expect(!model.voiceKeyLatch.isHeld)
        #expect(model.pendingVoiceKeyMode == nil)
        #expect(!model.voiceSession.commandAudio.isWaiting)
    }

    @Test func failedFnUpAndConfirmedCleanupBothRetainSourceForComposition() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = "previous"
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao }, prepareInputSource: { tool in source = tool.automaticVoiceSessionInputSourceID!; return .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { requested, _, continuing, done in source = requested; done(continuing()) },
            installMonitor: { _ in nil }, logger: { _ in })
        let started = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in true })
        #expect(started)
        let stopped = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in false })
        #expect(!stopped)
        #expect(model.voiceKeyLatch.isHeld)
        #expect(source == OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        let cleaned = model.releaseVoiceKeyIfNeeded(releaseKey: { _ in true })
        #expect(cleaned)
        #expect(source == OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
    }

    @Test func alreadySelectedSourceAndUserChangesArePreserved() throws {
        let target = try #require(OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        var source = target
        var restored: [String] = []
        let monitor = PreferredInputSourceMonitor(voiceTool: { .doubao },
            prepareInputSource: { _ in source = target; return .selected }, currentInputSourceID: { source },
            restoreInputSource: { restored.append($0); source = $0; return .selected },
            waitForInputSourceActivation: { _, _, continuing, done in done(continuing()) }, installMonitor: { _ in nil }, logger: { _ in })
        #expect(beginInlineSession(monitor))
        monitor.endVoiceSession()
        #expect(restored.isEmpty)
        source = "previous"
        #expect(beginInlineSession(monitor))
        source = "user_selected"
        monitor.endVoiceSession()
        #expect(restored.isEmpty)
        #expect(source == "user_selected")
    }

    @Test func ordinaryKeyboardFnLeavesItsInputSourceSelected() throws {
        var source = "previous"
        let target = try #require(OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        let monitor = PreferredInputSourceMonitor(voiceTool: { .doubao },
            prepareInputSource: { _ in source = target; return .selected }, currentInputSourceID: { source },
            restoreInputSource: { source = $0; return .selected }, installMonitor: { _ in nil }, logger: { _ in })
        monitor.handleFunctionKeyPressed(true)
        #expect(source == target)
        #expect(monitor.functionKeyIsPressedForDiagnostics)
        monitor.handleFunctionKeyPressed(false)
        #expect(source == target)
    }

    @Test func delayedResultRemainsAttachedAfterKeyUpAndMonitorStop() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = try #require(OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        var source = "previous"
        var restores = 0
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in source = target; return .selected },
            currentInputSourceID: { source },
            restoreInputSource: { source = $0; restores += 1; return .selected },
            waitForInputSourceActivation: { requested, _, continuing, done in source = requested; done(continuing()) },
            installMonitor: { _ in nil }, logger: { _ in })
        #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in true }))
        #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, _ in true }))
        model.preferredInputSourceMonitor.stop()
        // A recognition result can arrive after both recording and monitoring
        // have ended. Its input method must still be the selected text client.
        #expect(source == target)
        #expect(restores == 0)
        #expect(!model.voiceKeyLatch.isHeld)
    }

    @Test func monitorStopDuringSubmittedVoiceRetainsSourceAndUserSelection() throws {
        let target = try #require(OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        for userChanged in [false, true] {
            var source = "previous"
            var restores = 0
            let monitor = PreferredInputSourceMonitor(voiceTool: { .doubao },
                prepareInputSource: { _ in source = target; return .selected },
                currentInputSourceID: { source },
                restoreInputSource: { source = $0; restores += 1; return .selected },
                waitForInputSourceActivation: { requested, _, continuing, done in source = requested; done(continuing()) },
                installMonitor: { _ in nil }, logger: { _ in })
            #expect(beginInlineSession(monitor))
            monitor.markVoiceTriggerSubmitted()
            if userChanged { source = "user_selected" }
            monitor.stop()
            monitor.endVoiceSession()
            #expect(source == (userChanged ? "user_selected" : target))
            #expect(restores == 0)
        }
    }

    @Test func unsubmittedSessionRollsBackAndDoesNotAffectLaterSuccessfulSession() throws {
        let target = try #require(OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        var source = "previous"
        var restored: [String] = []
        let monitor = PreferredInputSourceMonitor(voiceTool: { .doubao },
            prepareInputSource: { _ in source = target; return .selected },
            currentInputSourceID: { source },
            restoreInputSource: { restored.append($0); source = $0; return .selected },
            waitForInputSourceActivation: { requested, _, continuing, done in source = requested; done(continuing()) },
            installMonitor: { _ in nil }, logger: { _ in })
        #expect(beginInlineSession(monitor))
        monitor.endVoiceSession()
        #expect(source == "previous")
        #expect(restored == ["previous"])
        #expect(beginInlineSession(monitor))
        monitor.markVoiceTriggerSubmitted()
        monitor.endVoiceSession()
        #expect(source == target)
        #expect(restored == ["previous"])
    }

    @Test func standaloneToolsNeverSelectWaitForOrRestoreAnInputSource() {
        // Tools without automaticVoiceSessionInputSourceID bypass all input-source machinery.
        for tool in [OnboardingVoiceTool.voiceBuddy, .chatterfly, .typeless, .bageshuo, .other] {
            #expect(tool.automaticVoiceSessionInputSourceID == nil)
            #expect(!tool.passiveVoiceSessionActivation)
            var sourceOperations = 0
            let monitor = PreferredInputSourceMonitor(voiceTool: { tool },
                prepareInputSource: { _ in sourceOperations += 1; return .failed },
                currentInputSourceID: { sourceOperations += 1; return "previous" },
                restoreInputSource: { _ in sourceOperations += 1; return .failed },
                waitForInputSourceActivation: { _, _, _, done in sourceOperations += 1; done(false) },
                installMonitor: { _ in nil }, logger: { _ in })
            #expect(beginInlineSession(monitor))
            monitor.markVoiceTriggerSubmitted()
            monitor.endVoiceSession()
            monitor.handleFunctionKeyPressed(true)
            monitor.handleFunctionKeyPressed(false)
            monitor.stop()
            #expect(sourceOperations == 0)
        }
    }

    @Test func passiveToolsHaveExpectedInputSourceProperties() {
        // WeChat IME and Doubao IME both expose a "全局唤起" global-activation option.
        for tool in [OnboardingVoiceTool.weixin, .doubao] {
            #expect(tool.automaticVoiceSessionInputSourceID != nil)
            #expect(tool.passiveVoiceSessionActivation)
        }
        #expect(OnboardingVoiceTool.weixin.preferredInputSourceID == "com.tencent.inputmethod.wetype.pinyin")
        #expect(OnboardingVoiceTool.weixin.requiresInputSourceSelection)
    }

    /// IME switches the input source itself via global activation — no TISSelectInputSource needed.
    @Test func passiveToolSucceedsWhenIMESwitchesSourceWithoutFallback() throws {
        for tool in [OnboardingVoiceTool.weixin, .doubao] {
            let target = try #require(tool.automaticVoiceSessionInputSourceID)
            var source = "previous"
            var prepareCount = 0
            var restored: [String] = []
            let monitor = PreferredInputSourceMonitor(voiceTool: { tool },
                prepareInputSource: { _ in prepareCount += 1; source = target; return .selected },
                currentInputSourceID: { source },
                restoreInputSource: { restored.append($0); source = $0; return .selected },
                waitForInputSourceActivation: { _, _, continuing, done in
                    // Simulate the IME switching the source itself before the timeout.
                    source = target; done(continuing())
                },
                installMonitor: { _ in nil }, logger: { _ in })
            #expect(beginInlineSession(monitor))
            // prepareInputSource must NOT have been called (IME handled the switch).
            #expect(prepareCount == 0)
            monitor.markVoiceTriggerSubmitted()
            monitor.endVoiceSession()
            monitor.stop()
            #expect(source == target)
            #expect(restored.isEmpty)
        }
    }

    /// IME did not switch on its own (global activation off) — fallback TISSelectInputSource is called.
    @Test func passiveToolFallsBackToExplicitSwitchWhenIMEDoesNotSwitch() throws {
        for tool in [OnboardingVoiceTool.weixin, .doubao] {
            let target = try #require(tool.automaticVoiceSessionInputSourceID)
            var source = "previous"
            var prepareCount = 0
            var restored: [String] = []
            var waitCount = 0
            let monitor = PreferredInputSourceMonitor(voiceTool: { tool },
                prepareInputSource: { _ in prepareCount += 1; source = target; return .selected },
                currentInputSourceID: { source },
                restoreInputSource: { restored.append($0); source = $0; return .selected },
                waitForInputSourceActivation: { _, current, continuing, done in
                    waitCount += 1
                    // First wait: IME did not switch (timeout). Second wait: source already set by fallback.
                    done(current() == target && continuing())
                },
                installMonitor: { _ in nil }, logger: { _ in })
            #expect(beginInlineSession(monitor))
            // prepareInputSource must have been called exactly once as the fallback.
            #expect(prepareCount == 1)
            #expect(waitCount == 2)
            monitor.markVoiceTriggerSubmitted()
            monitor.endVoiceSession()
            monitor.stop()
            #expect(source == target)
            #expect(restored.isEmpty)
        }
    }

    @Test func automaticInputSourceMethodRetainsSelectionAfterSuccessfulTrigger() throws {
        let tool = OnboardingVoiceTool.doubao
        let target = try #require(tool.automaticVoiceSessionInputSourceID)
        var source = "previous"
        var restored: [String] = []
        let monitor = PreferredInputSourceMonitor(voiceTool: { tool },
            prepareInputSource: { _ in source = target; return .selected },
            currentInputSourceID: { source },
            restoreInputSource: { restored.append($0); source = $0; return .selected },
            waitForInputSourceActivation: { _, current, continuing, done in
                // Simulate IME switching source passively before timeout.
                source = target; done(current() == target && continuing())
            },
            installMonitor: { _ in nil }, logger: { _ in })
        #expect(beginInlineSession(monitor))
        monitor.markVoiceTriggerSubmitted()
        monitor.endVoiceSession()
        monitor.stop()
        #expect(source == target)
        #expect(restored.isEmpty)
    }

    @Test func modifierDeliveryDiagnosticsStayWithinVoiceAttemptsWithoutAcquiringSyntheticOwners() throws {
        let target = try #require(OnboardingVoiceTool.weixin.preferredInputSourceID)
        var callback: ((PreferredInputSourceMonitor.FunctionKeyEvent) -> Void)?
        var messages: [String] = []
        let monitor = PreferredInputSourceMonitor(voiceTool: { .weixin },
            currentInputSourceID: { target },
            installMonitor: { callback = $0; return NSObject() }, removeMonitor: { _ in },
            logger: { messages.append($0) })
        monitor.start()
        defer { monitor.stop() }
        let observe = try #require(callback)
        let nativeUp = PreferredInputSourceMonitor.FunctionKeyEvent(keyCode: 63, flags: [], marker: 0)
        observe(nativeUp)
        #expect(messages.isEmpty)
        monitor.beginVoiceSession { #expect($0) }
        monitor.markVoiceTriggerSubmitted()
        messages = []
        observe(.init(keyCode: 63, flags: .maskSecondaryFn, marker: KeyboardInjector.orderedVoiceEventMarker))
        #expect(!monitor.functionKeyIsPressedForDiagnostics)
        observe(nativeUp) // Repeated native up used to be invisible to lifecycle logs.
        #expect(messages.count == 2)
        #expect(messages[0].contains("origin=ordered_voice"))
        #expect(messages[1].contains("origin=external"))
        #expect(messages[1].contains("fn_down=false"))
        #expect(messages.allSatisfy { $0.contains("target_response=unknown") })
        observe(.init(keyCode: 0, flags: [], marker: 0))
        observe(.init(keyCode: 63, flags: .maskSecondaryFn, marker: KeyboardInjector.syntheticEventMarker))
        #expect(messages.count == 2)
        monitor.endVoiceSession()
        messages = []
        observe(nativeUp)
        #expect(messages.isEmpty)
        // Key-up observation can arrive after the explicit owner was released.
        observe(.init(keyCode: 63, flags: [], marker: KeyboardInjector.orderedVoiceEventMarker))
        #expect(messages.count == 1)
        #expect(messages[0].contains("origin=ordered_voice"))
    }

    @Test func orderedEventsCannotAcquireAnExtraGlobalFnOwnerAndRemainSynthetic() throws {
        #expect(!PreferredInputSourceMonitor.shouldObserveFunctionEvent(marker: KeyboardInjector.orderedVoiceEventMarker))
        #expect(PreferredInputSourceMonitor.shouldObserveFunctionEvent(marker: 0))
        // Both software markers must stay outside the physical Fn observer.
        #expect(!PreferredInputSourceMonitor.shouldObserveFunctionEvent(marker: KeyboardInjector.syntheticEventMarker))
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: KeyboardInjector.orderedVoiceEventMarker)
        #expect(KeyboardInjector.isSyntheticEvent(event))
        let ordinarySource = try #require(CGEventSource(stateID: .privateState))
        let ordinaryEvent = try #require(CGEvent(keyboardEventSource: ordinarySource, virtualKey: 63, keyDown: true))
        #expect(!KeyboardInjector.isSyntheticEvent(ordinaryEvent))
    }

    @Test func failedSourceSelectionOrFnDownNeverLeavesTheSourceOwned() throws {
        for selection in [OnboardingInputSourceSwitchResult.failed, .selected] {
            let (model, defaults, suite) = try makeModel()
            defer { defaults.removePersistentDomain(forName: suite) }
            var source = "previous"
            var posts = 0
            model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
                voiceTool: { .doubao }, prepareInputSource: { tool in
                    if selection == .selected { source = tool.automaticVoiceSessionInputSourceID! }
                    return selection
                }, currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
                waitForInputSourceActivation: { target, current, continuing, done in
                    done(current() == target && continuing())
                },
                installMonitor: { _ in nil }, logger: { _ in })
            let started = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
                keySetter: { _, _ in posts += 1; return false })
            #expect(!started)
            #expect(posts == (selection == .selected ? 1 : 0))
            #expect(source == "previous")
            #expect(!model.voiceKeyLatch.isHeld)
            #expect(model.pendingVoiceKeyMode == nil)
        }
    }

    @Test func orderedHardwareFnRequiresNeutralizationAndPostingPermission() {
        #expect(OrderedVoiceActivationPolicy.needsSoftwareFn(mode: .function, fnTapEnabled: false,
            preferredInputSourceID: "weixin"))
        #expect(!OrderedVoiceActivationPolicy.needsSoftwareFn(mode: .function, fnTapEnabled: true,
            preferredInputSourceID: "weixin"))
        #expect(!OrderedVoiceActivationPolicy.needsSoftwareFn(mode: .function, fnTapEnabled: false,
            preferredInputSourceID: nil))
        #expect(!BridgeAppModel.canStartBluetoothVoice(mode: .function, isVoiceKeyNeutralized: false,
            accessibilityGranted: true, requiresOrderedFn: true))
        #expect(!BridgeAppModel.canStartBluetoothVoice(mode: .function, isVoiceKeyNeutralized: true,
            accessibilityGranted: false, requiresOrderedFn: true))
        #expect(BridgeAppModel.canStartBluetoothVoice(mode: .function, isVoiceKeyNeutralized: true,
            accessibilityGranted: true, requiresOrderedFn: true))
        #expect(BridgeAppModel.canStartBluetoothVoice(mode: .function, isVoiceKeyNeutralized: false))
        #expect(VoiceKeySessionPreservationPolicy.shouldPreserveInputSourceSession(latchHeld: true,
            heldMode: .function, pendingMode: nil))
    }

    @Test func multipleVoiceOwnersReleaseKeysWithoutRestoringTheSource() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = "previous"
        var posts: [Bool] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao }, prepareInputSource: { tool in source = tool.automaticVoiceSessionInputSourceID!; return .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { requested, _, continuing, done in source = requested; done(continuing()) },
            installMonitor: { _ in nil }, logger: { _ in })
        let setter: (VoiceKeyMode, Bool) -> Bool = { _, down in posts.append(down); return true }
        let first = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth, keySetter: setter)
        let second = model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .chromecast, keySetter: setter)
        #expect(first && second)
        let firstStop = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth, keySetter: setter)
        #expect(firstStop)
        #expect(source == OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        #expect(posts == [true])
        let secondStop = model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .chromecast, keySetter: setter)
        #expect(secondStop)
        #expect(source == OnboardingVoiceTool.doubao.automaticVoiceSessionInputSourceID)
        #expect(posts == [true, false])
    }
    @Test func toolChangesRemainPendingUntilBothRecordingAndKeyCleanupEnd() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.settings.setAllApplicationIntegrations(enabled: false)
        model.started = true
        model.isStreaming = true
        model.pendingVoiceToolMappingRefresh = true
        var refreshes = 0
        model.flushPendingVoiceToolMappingRefresh(applyMappings: { refreshes += 1 })
        #expect(refreshes == 0)
        model.settings.setOnboardingVoiceTool(.typeless)
        _ = model.voiceKeyLatch.transition(streaming: true, owner: .bluetooth)
        model.isStreaming = false
        model.flushPendingVoiceToolMappingRefresh(applyMappings: { refreshes += 1 })
        #expect(refreshes == 0)
        #expect(model.pendingVoiceToolMappingRefresh)
        model.voiceKeyLatch.reset()
        model.isStreaming = true
        model.endVoiceSessionIfNeeded(flushAudio: false, applyPendingMappings: { refreshes += 1 })
        #expect(refreshes == 1)
        #expect(!model.requiresOrderedVoiceFn)
        #expect(!model.pendingVoiceToolMappingRefresh)
        model.flushPendingVoiceToolMappingRefresh(applyMappings: { refreshes += 1 })
        #expect(refreshes == 1)
        model.started = false
    }

    @Test func lateSelectionReceivesAFullSettlingIntervalWithoutBlocking() {
        var time: TimeInterval = 0
        var queued: (() -> Void)?
        var result: Bool?
        PreferredInputSourceMonitor.waitForActivation(
            target: "target", current: { time >= 0.49 ? "target" : "previous" }, shouldContinue: { true },
            now: { time }, schedule: { _, work in queued = work }, completion: { result = $0 })
        #expect(result == nil)
        while let check = queued {
            queued = nil
            time += 0.01
            check()
        }
        #expect(result == true)
        #expect(time >= 0.54 && time <= 0.550000001)
    }

    @Test func selectionAfterDeadlineAndCancelledActivationFailOnce() {
        for cancelled in [false, true] {
            var time: TimeInterval = 0
            var queued: (() -> Void)?
            var results: [Bool] = []
            PreferredInputSourceMonitor.waitForActivation(
                target: "target", current: { time >= 0.51 ? "target" : "previous" },
                shouldContinue: { !cancelled || time < 0.1 }, now: { time },
                schedule: { _, work in queued = work }, completion: { results.append($0) })
            while let check = queued {
                queued = nil
                time += 0.01
                check()
            }
            #expect(results == [false])
            #expect(time < (cancelled ? 0.12 : 0.51))
        }
    }

    @Test func cancelledDeferredActivationCannotPostOrMutateNewSession() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        var source = "previous"
        var confirmations: [(Bool) -> Void] = []
        var posted: [Bool] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao }, prepareInputSource: { tool in source = tool.automaticVoiceSessionInputSourceID!; return .selected },
            currentInputSourceID: { source }, restoreInputSource: { source = $0; return .selected },
            waitForInputSourceActivation: { _, _, _, done in confirmations.append(done) },
            installMonitor: { _ in nil }, logger: { _ in })
        let setter: (VoiceKeyMode, Bool) -> Bool = { _, down in posted.append(down); return true }
        #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth, keySetter: setter))
        #expect(posted.isEmpty)
        #expect(model.voiceSession.commandAudio.isWaiting)
        #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth, keySetter: setter))
        #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth, keySetter: setter))
        confirmations[0](true)
        #expect(posted.isEmpty)
        #expect(model.pendingVoiceKeyMode == .function)
        confirmations[1](true)
        #expect(posted == [true])
        #expect(model.heldVoiceKeyMode == .function)
        #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth, keySetter: setter))
        #expect(posted == [true, false])
    }

    @Test func unavailableInputSourceTriggersThrottledPromptWithoutPostingVoiceKey() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        model.settings.setOnboardingVoiceTool(.doubao)
        var failures: [(OnboardingVoiceTool, OnboardingInputSourceSwitchResult)] = []
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in .unavailable },
            currentInputSourceID: { "com.apple.keylayout.ABC" },
            restoreInputSource: { _ in .selected },
            waitForInputSourceActivation: { _, _, _, done in done(false) },
            installMonitor: { _ in nil },
            logger: { _ in },
            onSourcePreparationFailure: { [weak model] tool, result in
                failures.append((tool, result))
                model?.handleInputSourcePreparationFailure(for: tool, result: result, now: 100)
            }
        )
        var posted: [Bool] = []
        #expect(!model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in posted.append(down); return true }))
        #expect(posted.isEmpty)
        #expect(failures.count == 1 && failures[0].0 == .doubao && failures[0].1 == .unavailable)
        #expect(model.unavailableVoiceToolPrompt == BridgeAppModel.VoiceToolUnavailablePrompt(
            tool: .doubao, reason: .unavailable))

        // Production mapping ignores non-failure switch results and enforces 10s per-tool throttling across reasons.
        for ignored in [OnboardingInputSourceSwitchResult.selected, .notSelected, .notApplicable] {
            model.unavailableVoiceToolPrompt = nil
            model.handleInputSourcePreparationFailure(for: .doubao, result: ignored, now: 120)
            #expect(model.unavailableVoiceToolPrompt == nil)
        }
        model.handleInputSourcePreparationFailure(for: .doubao, result: .failed, now: 105)
        #expect(model.unavailableVoiceToolPrompt == nil)
        model.handleInputSourcePreparationFailure(for: .weixin, result: .failed, now: 106)
        #expect(model.unavailableVoiceToolPrompt == BridgeAppModel.VoiceToolUnavailablePrompt(
            tool: .weixin, reason: .switchFailed))
        model.unavailableVoiceToolPrompt = nil
        model.handleInputSourcePreparationFailure(for: .doubao, result: .failed, now: 111)
        #expect(model.unavailableVoiceToolPrompt == BridgeAppModel.VoiceToolUnavailablePrompt(
            tool: .doubao, reason: .switchFailed))
    }

    @Test func missingApplicationVoiceToolTriggersPromptAndBlocksAllTriggerModes() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }

        var available = false
        model.voiceToolAvailabilityChecker = { _ in available ? .available : .notInstalled }

        let cases: [(OnboardingVoiceTool, VoiceKeyMode, Bool, Bool)] = [
            (.chatterfly, .suggestedShortcut, false, true),
            (.voiceBuddy, .function, false, false),
            (.bageshuo, .function, true, true),
            (.typeless, .function, true, true),
        ]
        for (tool, mode, tapMode, forceSoftware) in cases {
            model.settings.setOnboardingVoiceTool(tool)
            model.settings.voiceKeyMode = mode
            model.settings.voiceFnTapModeEnabled = tapMode
            model.unavailableVoiceToolPrompt = nil
            var posted: [Bool] = []
            var completionResult: Bool?
            #expect(!model.updateVoiceKeyState(
                streaming: true,
                forceSoftware: forceSoftware,
                owner: .bluetooth,
                keySetter: { _, down in posted.append(down); return true },
                completion: { completionResult = $0 }
            ))
            #expect(completionResult == false)
            #expect(posted.isEmpty)
            #expect(model.unavailableVoiceToolPrompt == BridgeAppModel.VoiceToolUnavailablePrompt(
                tool: tool,
                reason: .applicationUnavailable
            ))
        }

        available = true
        model.settings.setOnboardingVoiceTool(.chatterfly)
        model.settings.voiceKeyMode = .suggestedShortcut
        model.settings.voiceFnTapModeEnabled = false
        model.unavailableVoiceToolPrompt = nil
        var posted: [Bool] = []
        #expect(model.updateVoiceKeyState(
            streaming: true,
            forceSoftware: true,
            owner: .bluetooth,
            keySetter: { _, down in posted.append(down); return true }
        ))
        #expect(posted == [true])
        #expect(model.unavailableVoiceToolPrompt == nil)
        #expect(model.updateVoiceKeyState(
            streaming: false,
            forceSoftware: true,
            owner: .bluetooth,
            keySetter: { _, down in posted.append(down); return true }
        ))
    }

    @Test func asyncActivationTimeoutNotifiesFailureAndCancellationStaysSilent() throws {
        let target = try #require(OnboardingVoiceTool.doubao.preferredInputSourceID)
        var source = "previous"
        var restored: [String] = []
        var finishWait: ((Bool) -> Void)?
        var failures: [(OnboardingVoiceTool, OnboardingInputSourceSwitchResult)] = []
        let monitor = PreferredInputSourceMonitor(
            voiceTool: { .doubao },
            prepareInputSource: { _ in source = target; return .selected },
            currentInputSourceID: { source },
            restoreInputSource: { id in restored.append(id); source = id; return .selected },
            waitForInputSourceActivation: { _, _, _, done in finishWait = done },
            installMonitor: { _ in nil },
            logger: { _ in },
            onSourcePreparationFailure: { tool, result in failures.append((tool, result)) }
        )

        var readyResults: [Bool] = []
        monitor.beginVoiceSession { readyResults.append($0) }
        // Passive path: first wait times out → fallback prepareInputSource → second wait registered.
        // finishWait now points to the second wait's done callback.
        finishWait?(false)
        #expect(readyResults.isEmpty)   // second wait still pending
        // Finish the second wait with failure — now the whole session fails.
        finishWait?(false)
        #expect(readyResults == [false])
        #expect(failures.count == 1 && failures[0].0 == .doubao && failures[0].1 == .failed)
        #expect(restored == ["previous"] && source == "previous")

        failures.removeAll()
        restored.removeAll()
        readyResults.removeAll()
        finishWait = nil
        monitor.beginVoiceSession { readyResults.append($0) }
        monitor.endVoiceSession()
        // After cancellation the first wait's done fires; the passive retry is suppressed
        // because continuing() is false, so no second wait is started.
        finishWait?(false)
        #expect(readyResults == [false])
        #expect(failures.isEmpty)
        #expect(restored == ["previous"])
    }

    @Test func unavailableVoiceToolAlertCopyNavigationAndReentrancy() throws {
        let (model, defaults, suite) = try makeModel()
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: model.settings)

        for language in [AppLanguage.english, .simplifiedChinese] {
            localization.select(language)
            let toolTitle = localization.text(OnboardingVoiceTool.doubao.titleKey)
            let unavailable = UnavailableVoiceToolAlertContent(
                prompt: .init(tool: .doubao, reason: .unavailable),
                using: localization
            )
            let switchFailed = UnavailableVoiceToolAlertContent(
                prompt: .init(tool: .doubao, reason: .switchFailed),
                using: localization
            )
            let appToolTitle = localization.text(OnboardingVoiceTool.chatterfly.titleKey)
            let appUnavailable = UnavailableVoiceToolAlertContent(
                prompt: .init(tool: .chatterfly, reason: .applicationUnavailable),
                using: localization
            )
            for content in [unavailable, switchFailed] {
                #expect(!content.title.isEmpty && !content.title.contains("%@") && content.title.contains(toolTitle))
                #expect(!content.message.isEmpty && !content.message.contains("%@") && content.message.contains(toolTitle))
                #expect(!content.openSettingsTitle.isEmpty && content.openSettingsTitle != "voice_tool.unavailable.alert.open_settings")
                #expect(!content.cancelTitle.isEmpty && content.cancelTitle != "common.action.cancel")
            }
            #expect(!appUnavailable.title.isEmpty && !appUnavailable.title.contains("%@") && appUnavailable.title.contains(appToolTitle))
            #expect(!appUnavailable.message.isEmpty && !appUnavailable.message.contains("%@") && appUnavailable.message.contains(appToolTitle))
            #expect(appUnavailable.message != "voice_tool.application_unavailable.alert.message")
            #expect(appUnavailable.message != unavailable.message)
            #expect(unavailable.title != "voice_tool.unavailable.alert.title")
            #expect(unavailable.message != "voice_tool.unavailable.alert.message")
            #expect(switchFailed.title != "voice_tool.switch_failed.alert.title")
            #expect(switchFailed.message != "voice_tool.switch_failed.alert.message")
            #expect(unavailable.title != switchFailed.title)
            #expect(unavailable.message != switchFailed.message)
        }

        let coordinator = UnavailableVoiceToolAlertCoordinator()
        var shownTitles: [String] = []
        var openedSettings = 0
        var injectedReentrant = false
        model.unavailableVoiceToolPrompt = .init(tool: .doubao, reason: .unavailable)
        coordinator.presentIfIdle(
            model: model,
            localization: localization,
            runModal: { content in
                shownTitles.append(content.title)
                if !injectedReentrant {
                    injectedReentrant = true
                    // A prompt arriving while a modal is active must neither open a nested modal nor be dropped.
                    model.unavailableVoiceToolPrompt = .init(tool: .weixin, reason: .switchFailed)
                    coordinator.presentIfIdle(
                        model: model,
                        localization: localization,
                        runModal: { nested in
                            shownTitles.append("nested:\(nested.title)")
                            return .alertSecondButtonReturn
                        },
                        openSettings: { openedSettings += 1 }
                    )
                    return .alertSecondButtonReturn
                }
                return .alertFirstButtonReturn
            },
            openSettings: { openedSettings += 1 }
        )

        #expect(shownTitles.count == 2)
        #expect(shownTitles[0] != shownTitles[1])
        #expect(!shownTitles.contains { $0.hasPrefix("nested:") })
        #expect(model.requestedSettingsSection == .integration)
        #expect(openedSettings == 1)
        #expect(model.unavailableVoiceToolPrompt == nil)
    }
}
