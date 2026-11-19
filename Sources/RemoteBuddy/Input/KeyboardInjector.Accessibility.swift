import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import os

extension KeyboardInjector {
    private static let manualAccessibilityLoggedProcesses = OSAllocatedUnfairLock<Set<pid_t>>(initialState: [])
    static func manualAccessibilityResultName(_ result: AXError) -> String {
        switch result {
        case .success: return "success"
        case .attributeUnsupported: return "attribute_unsupported"
        case .cannotComplete: return "cannot_complete"
        case .invalidUIElement: return "invalid_element"
        case .apiDisabled: return "api_disabled"
        case .notImplemented: return "not_implemented"
        default: return "error_\(result.rawValue)"
        }
    }

    /// The fallback only runs when the Chromium attribute is unsupported, so the
    /// log has to name which attribute actually answered.
    static func manualAccessibilityResultToken(primary: AXError, fallback: AXError?) -> String {
        guard let fallback else { return manualAccessibilityResultName(primary) }
        return "fallback_enhanced_\(manualAccessibilityResultName(fallback))"
    }

    /// The fallback answer wins whenever it was attempted, because the primary
    /// attribute was unsupported by that app.
    static func manualAccessibilityEffectiveResult(
        primary: AXError,
        fallback: AXError?
    ) -> AXError {
        if primary == .success { return .success }
        return fallback ?? primary
    }

    /// The attribute is set on every attempt because it is idempotent, but only
    /// the first attempt and the attempt that finally builds the tree carry new
    /// information; the retries in between would repeat the same reason.
    static func shouldLogManualAccessibility(
        result: AXError,
        attempt: Int,
        alreadyLoggedSuccess: Bool
    ) -> Bool {
        if attempt == 0 { return true }
        return result == .success && !alreadyLoggedSuccess
    }

    @discardableResult
    static func announceManualAccessibility(
        processIdentifier: pid_t,
        bundleIdentifier: String,
        attempt: Int
    ) -> Bool {
        AccessibilityMessaging.prepareQueries()
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        let primary = AXUIElementSetAttributeValue(
            applicationElement,
            manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
        var fallback: AXError?
        if primary == .attributeUnsupported {
            fallback = AXUIElementSetAttributeValue(
                applicationElement,
                enhancedUserInterfaceAttribute as CFString,
                kCFBooleanTrue
            )
        }
        let result = manualAccessibilityEffectiveResult(primary: primary, fallback: fallback)

        let shouldLog = manualAccessibilityLoggedProcesses.withLock { loggedProcesses in
            let alreadyLoggedSuccess = loggedProcesses.contains(processIdentifier)
            let shouldLog = shouldLogManualAccessibility(
                result: result,
                attempt: attempt,
                alreadyLoggedSuccess: alreadyLoggedSuccess
            )
            if result == .success {
                if loggedProcesses.count >= 64 {
                    loggedProcesses.removeAll()
                }
                loggedProcesses.insert(processIdentifier)
            }
            return shouldLog
        }

        if shouldLog {
            AppLogger.shared.write(
                "APP FOCUS manual_accessibility bundle=\(bundleIdentifier) " +
                    "attempt=\(attempt) " +
                    "result=\(manualAccessibilityResultToken(primary: primary, fallback: fallback))"
            )
        }
        return result == .success
    }

    static func applicationIsFrontmost(_ processIdentifier: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    static func focusComposer(
        processIdentifier: pid_t,
        emitDiagnostics: Bool = false
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var windowCount = 0
        var candidateCount = 0
        var eligibleCount = 0
        var excludedSensitiveCount = 0
        for window in applicationWindows(applicationElement) {
            windowCount += 1
            let candidates = accessibilityTextCandidates(in: window)
            candidateCount += candidates.count
            for candidate in candidates.map(\.snapshot) {
                let semanticText = [
                    candidate.identifier,
                    candidate.title,
                    candidate.description,
                    candidate.help,
                    candidate.placeholder,
                    candidate.context,
                ].joined(separator: " ").lowercased()
                if composerCandidateScore(candidate, windowFrame: axFrame(window)) != nil {
                    eligibleCount += 1
                } else if containsSensitiveAccessibilityTerms(semanticText) {
                    excludedSensitiveCount += 1
                }
            }
            guard let candidateIndex = bestComposerCandidateIndex(
                candidates.map(\.snapshot),
                windowFrame: axFrame(window)
            ) else { continue }
            let targetElement = candidates[candidateIndex].element
            if focusElementPreservingExistingCaret(
                isAlreadyFocused: {
                    accessibilityElementIsFocused(
                        targetElement,
                        applicationElement: applicationElement,
                        requiresApplicationFocusedElement: false
                    )
                },
                focusElement: {
                    focusAccessibilityElement(
                        targetElement,
                        applicationElement: applicationElement
                    )
                },
                moveCaretToEnd: {
                    _ = moveAccessibilityCaretToEnd(
                        of: targetElement,
                        canContinue: {
                            applicationIsFrontmost(processIdentifier) &&
                                isAccessibilityTrusted &&
                                !SecureInputMonitor.isEnabled() &&
                                accessibilityElementIsFocused(
                                    targetElement,
                                    applicationElement: applicationElement,
                                    requiresApplicationFocusedElement: false
                                )
                        }
                    )
                }
            ) {
                return true
            }
        }
        if emitDiagnostics {
            AppLogger.shared.write(
                "APP FOCUS scan bundle=\(NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier ?? "unknown") " +
                    "windows=\(windowCount) candidates=\(candidateCount) eligible=\(eligibleCount) " +
                    "excluded_sensitive=\(excludedSensitiveCount)"
            )
        }
        return false
    }

    /// Only invoked by an accepted voice start. A separate gate keeps this from
    /// cancelling explicit application-launch/focus button actions.
    static func focusIntegratedApplication(_ integration: ApplicationIntegration,
                                           processIdentifier: pid_t,
                                           completion: @escaping (ApplicationFocusResult) -> Void) -> ScheduledOperation {
        let gate = ApplicationFocusRequestGate()
        let requestID = gate.begin()
        let bundleIdentifier = NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
            ?? "unknown"
        nonisolated(unsafe) let completion = completion
        @Sendable func finish(_ result: ApplicationFocusResult) {
            DispatchQueue.main.async {
                guard gate.isCurrent(requestID) else { return }
                if result == .unavailable {
                    AppLogger.shared.write("APP INTEGRATION failed bundle=\(bundleIdentifier) reason=focus_not_confirmed")
                }
                completion(result)
            }
        }
        @Sendable func attempt(_ number: Int, clickAttempted: Bool) {
            focusQueue.asyncAfter(deadline: .now() + (number == 0 ? 0 : 0.15)) {
                let canContinue = {
                    gate.isCurrent(requestID) && applicationIsFrontmost(processIdentifier) &&
                        isAccessibilityTrusted && !SecureInputMonitor.isEnabled()
                }
                guard canContinue() else { finish(.unavailable); return }
                var nextClickAttempted = clickAttempted
                let result = focusIntegratedComposer(integration, processIdentifier: processIdentifier,
                    clickAttempted: &nextClickAttempted, canContinue: canContinue)
                if result != .unavailable {
                    AppLogger.shared.write("APP INTEGRATION \(result == .preserved ? "preserved" : "focused") bundle=\(bundleIdentifier)")
                    finish(result)
                } else if number < 2, canContinue() {
                    attempt(number + 1, clickAttempted: nextClickAttempted)
                } else {
                    finish(.unavailable)
                }
            }
        }
        attempt(0, clickAttempted: false)
        return ScheduledOperation { _ = gate.begin() }
    }

    private static func focusIntegratedComposer(_ integration: ApplicationIntegration,
                                                processIdentifier: pid_t,
                                                clickAttempted: inout Bool,
                                                canContinue: @escaping () -> Bool) -> ApplicationFocusResult {
        let app = AXUIElementCreateApplication(processIdentifier)
        // Reading the application's standard role is the public AT handshake.
        // Electron's accessibilityRole getter enables native AX APIs on demand;
        // querying only its window can otherwise return the native shell tree.
        // https://github.com/electron/electron/blob/main/shell/browser/mac/electron_application.mm
        guard canContinue(), axString(app, attribute: kAXRoleAttribute) == "AXApplication",
              canContinue() else { return .unavailable }
        var preservedElement: AXUIElement?
        func preserveInput(excluding target: AXUIElement? = nil) -> Bool {
            preservedElement = nil
            guard canContinue(), let input = axElement(app, attribute: kAXFocusedUIElementAttribute),
                  mayPreserveFocusedElement(input, excluding: target, equal: { CFEqual($0, $1) }) else { return false }
            var owner: pid_t = 0
            guard AXUIElementGetPid(input, &owner) == .success, owner == processIdentifier,
                  ["AXTextArea", "AXTextField", "AXComboBox"].contains(axString(input, attribute: kAXRoleAttribute)) else { return false }
            let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXEnabledAttribute, "AXEditable", "AXProtectedContent",
                        kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
            let attributes = AccessibilityMessaging.attributes(input, keys: keys)
            let destination = integratedPreservationSnapshot(bundleIdentifier: integration.bundleIdentifier,
                secureInputEnabled: SecureInputMonitor.isEnabled(), read: { attributes[$0] }, valueIsSettable: {
                    var settable = DarwinBoolean(false)
                    return AXUIElementIsAttributeSettable(input, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
                })
            guard shouldPreserveIntegratedInput(destination, integration: integration), canContinue(),
                  let current = axElement(app, attribute: kAXFocusedUIElementAttribute), CFEqual(input, current) else { return false }
            preservedElement = input
            return true
        }
        let preserveCurrentFocus = { preserveInput() }
        if preserveCurrentFocus() { return .preserved }
        guard canContinue(),
              !VoiceInputDestinationSnapshot.system().isSensitiveDestination,
              let window = axElement(app, attribute: kAXFocusedWindowAttribute),
              axString(window, attribute: kAXSubroleAttribute) != "AXDialog",
              axString(window, attribute: kAXSubroleAttribute) != "AXSystemDialog",
              axBool(window, attribute: "AXModal") != true,
              axElements(window, attribute: "AXSheets").isEmpty else { return .unavailable }
        let frame = axFrame(window)
        let scanStarted = ProcessInfo.processInfo.systemUptime
        var scannedNodes = 0
        var scanTruncated = false
        let candidates = accessibilityTextCandidates(in: window, integration: integration,
            didScan: { scannedNodes = $0; scanTruncated = $1 })
        AppLogger.shared.write("APP INTEGRATION scan bundle=\(integration.bundleIdentifier) candidates=\(candidates.count) " +
            "matches=\(candidates.filter { integratedComposerScore($0.snapshot, integration: integration, windowFrame: frame) != nil }.count) " +
            "nodes=\(scannedNodes) truncated=\(scanTruncated) " +
            "elapsed_ms=\(Int((ProcessInfo.processInfo.systemUptime - scanStarted) * 1_000))")
        let targetIsCurrent = {
            guard canContinue(), !VoiceInputDestinationSnapshot.system().isSensitiveDestination,
                  let current = axElement(app, attribute: kAXFocusedWindowAttribute),
                  CFEqual(window, current), axElements(window, attribute: "AXSheets").isEmpty else { return false }
            return true
        }
        let focusOutcome = focusIntegratedComposerCandidates(
            candidates,
            integration: integration,
            windowFrame: frame,
            canContinue: targetIsCurrent,
            preserveFocus: { preserveInput(excluding: $0) },
            isElementAlreadyFocused: { element in
                accessibilityElementIsFocused(
                    element,
                    applicationElement: app,
                    requiresApplicationFocusedElement: false
                )
            },
            focus: { element in
                if focusAccessibilityElement(element, applicationElement: app,
                    requiresApplicationFocusedElement: true, allowPress: integration == .antigravity,
                    canWriteFocus: { targetIsCurrent() && !preserveInput(excluding: element) }) {
                    return true
                }
                // Electron and Chromium renderers update AXFocusedUIElement asynchronously a few ms after AXFocused writes.
                for _ in 0..<4 {
                    guard targetIsCurrent(), !preserveInput(excluding: element) else { return false }
                    usleep(5_000)
                    guard targetIsCurrent(), !preserveInput(excluding: element) else { return false }
                    if accessibilityElementIsFocused(element, applicationElement: app,
                                                     requiresApplicationFocusedElement: true) {
                        return true
                    }
                }
                return false
            },
            click: { element, snapshot in
                if accessibilityElementIsFocused(element, applicationElement: app,
                                                 requiresApplicationFocusedElement: true) {
                    return true
                }
                guard !clickAttempted else { return false }
                clickAttempted = true
                return clickIntegratedComposer(snapshot, integration: integration, windowFrame: frame,
                    canContinue: targetIsCurrent,
                    preserveFocus: { preserveInput(excluding: element) },
                    hitTest: { accessibilityHitTestMatchesTarget(element, processIdentifier: processIdentifier, point: $0) },
                    isFocused: { accessibilityElementIsFocused(element, applicationElement: app,
                        requiresApplicationFocusedElement: true) })
            }
        )
        guard focusOutcome.resolved, canContinue() else { return .unavailable }
        if let preservedElement {
            guard let current = axElement(app, attribute: kAXFocusedUIElementAttribute),
                  CFEqual(current, preservedElement) else { return .unavailable }
            return .preserved
        }
        if let newlyFocusedElement = focusOutcome.newlyFocusedElement {
            _ = moveAccessibilityCaretToEnd(
                of: newlyFocusedElement,
                canContinue: {
                    targetIsCurrent() &&
                        !preserveInput(excluding: newlyFocusedElement) &&
                        accessibilityElementIsFocused(
                            newlyFocusedElement,
                            applicationElement: app,
                            requiresApplicationFocusedElement: true
                        )
                }
            )
        }
        return .focused
    }

    static func focusElementPreservingExistingCaret(
        isAlreadyFocused: () -> Bool,
        focusElement: () -> Bool,
        moveCaretToEnd: () -> Void
    ) -> Bool {
        let wasAlreadyFocused = isAlreadyFocused()
        guard focusElement() else { return false }
        if !wasAlreadyFocused {
            moveCaretToEnd()
        }
        return true
    }

    static func focusIntegratedComposerCandidates<Element>(
        _ candidates: [(element: Element, snapshot: AccessibilityTextCandidate)],
        integration: ApplicationIntegration,
        windowFrame: CGRect?,
        canContinue: () -> Bool,
        preserveFocus: (Element?) -> Bool,
        isElementAlreadyFocused: (Element) -> Bool,
        focus: (Element) -> Bool,
        click: (Element, AccessibilityTextCandidate) -> Bool
    ) -> (resolved: Bool, newlyFocusedElement: Element?) {
        var newlyFocusedElement: Element?
        var alreadyFocusedBeforeAttempt: Bool?
        let resolved = focusIntegratedCandidates(
            candidates,
            integration: integration,
            windowFrame: windowFrame,
            canContinue: canContinue,
            preserveFocus: preserveFocus,
            focus: { element in
                let wasAlreadyFocused = isElementAlreadyFocused(element)
                alreadyFocusedBeforeAttempt = wasAlreadyFocused
                guard focus(element) else { return false }
                newlyFocusedElement = wasAlreadyFocused ? nil : element
                return true
            },
            click: { element, snapshot in
                let wasAlreadyFocused = alreadyFocusedBeforeAttempt ?? isElementAlreadyFocused(element)
                guard click(element, snapshot) else { return false }
                newlyFocusedElement = wasAlreadyFocused ? nil : element
                return true
            }
        )
        return (resolved, newlyFocusedElement)
    }

    static func focusIntegratedComposerCandidates<Element>(
        _ candidates: [(element: Element, snapshot: AccessibilityTextCandidate)],
        integration: ApplicationIntegration,
        windowFrame: CGRect?,
        canContinue: () -> Bool,
        preserveFocus: @escaping () -> Bool,
        isElementAlreadyFocused: @escaping (Element) -> Bool,
        focus: (Element) -> Bool,
        click: (Element, AccessibilityTextCandidate) -> Bool
    ) -> (resolved: Bool, newlyFocusedElement: Element?) {
        var didAttemptFocus = false
        return focusIntegratedComposerCandidates(
            candidates,
            integration: integration,
            windowFrame: windowFrame,
            canContinue: canContinue,
            preserveFocus: { target in
                if let target, didAttemptFocus, isElementAlreadyFocused(target) {
                    return false
                }
                return preserveFocus()
            },
            isElementAlreadyFocused: isElementAlreadyFocused,
            focus: { element in
                didAttemptFocus = !isElementAlreadyFocused(element)
                return focus(element)
            },
            click: click
        )
    }

    /// The same candidate-to-action pipeline runs against native AX elements and
    /// injected test elements. Its only actions are focus and a verified click.
    static func focusIntegratedCandidates<Element>(_ candidates: [(element: Element, snapshot: AccessibilityTextCandidate)],
                                                   integration: ApplicationIntegration, windowFrame: CGRect?,
                                                   canContinue: () -> Bool, preserveFocus: (Element?) -> Bool,
                                                   focus: (Element) -> Bool,
                                                   click: (Element, AccessibilityTextCandidate) -> Bool) -> Bool {
        guard canContinue() else { return false }
        if preserveFocus(nil) { return true }
        let ranked = candidates.indices.compactMap { index -> (Int, Int)? in
            integratedComposerScore(candidates[index].snapshot, integration: integration,
                                    windowFrame: windowFrame).map { (index, $0) }
        }.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, ranked.count == 1 || best.1 > ranked[1].1, canContinue() else { return false }
        let candidate = candidates[best.0]
        if preserveFocus(nil) { return true }
        if focus(candidate.element) { return true }
        guard canContinue() else { return false }
        if preserveFocus(candidate.element) { return true }
        guard canContinue(),
              integratedComposerClickPoint(candidate.snapshot, integration: integration, windowFrame: windowFrame) != nil
        else { return false }
        return click(candidate.element, candidate.snapshot)
    }

    static func focusIntegratedCandidates<Element>(_ candidates: [(element: Element, snapshot: AccessibilityTextCandidate)],
                                                   integration: ApplicationIntegration, windowFrame: CGRect?,
                                                   canContinue: () -> Bool, preserveFocus: @escaping () -> Bool = { false },
                                                   focus: (Element) -> Bool,
                                                   click: (Element, AccessibilityTextCandidate) -> Bool) -> Bool {
        focusIntegratedCandidates(candidates, integration: integration, windowFrame: windowFrame,
            canContinue: canContinue, preserveFocus: { _ in preserveFocus() }, focus: focus, click: click)
    }

    static func integratedComposerClickPoint(_ candidate: AccessibilityTextCandidate,
                                             integration: ApplicationIntegration,
                                             windowFrame: CGRect?) -> CGPoint? {
        guard isVerifiedIntegratedComposer(candidate, integration: integration),
              integratedComposerScore(candidate, integration: integration, windowFrame: windowFrame) != nil,
              let frame = candidate.frame, let windowFrame else { return nil }
        let point = CGPoint(x: frame.minX + min(24, frame.width / 2),
                            y: frame.minY + min(16, frame.height / 2))
        guard point.x.isFinite, point.y.isFinite, windowFrame.contains(point) else { return nil }
        return point
    }

    static func clickIntegratedComposer(_ candidate: AccessibilityTextCandidate,
                                        integration: ApplicationIntegration,
                                        windowFrame: CGRect?,
                                        canContinue: () -> Bool,
                                        preserveFocus: () -> Bool = { false },
                                        hitTest: (CGPoint) -> Bool,
                                        postClick: (CGPoint) -> Bool = postAccessibilityFocusClick,
                                        isFocused: () -> Bool,
                                        pause: () -> Void = { usleep(50_000) }) -> Bool {
        guard canContinue() else { return false }
        if preserveFocus() { return true }
        guard let point = integratedComposerClickPoint(candidate, integration: integration, windowFrame: windowFrame),
              hitTest(point), canContinue() else { return false }
        if preserveFocus() { return true }
        guard postClick(point) else { return false }
        // The click is delivered asynchronously. Verify the actual focused input
        // before reporting completion or allowing the voice trigger through.
        for _ in 0..<5 {
            guard canContinue() else { return false }
            if isFocused() { return true }
            pause()
        }
        return canContinue() && isFocused()
    }

    private static func postAccessibilityFocusClick(_ point: CGPoint) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return false }
        let previousLocation = CGEvent(source: nil)?.location
        for event in [down, up] {
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
        if let previousLocation,
           let restore = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: previousLocation, mouseButton: .left) {
            restore.flags = []
            restore.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
            restore.post(tap: .cghidEventTap)
        }
        return true
    }

    private static func accessibilityHitTestMatchesTarget(_ target: AXUIElement,
                                                          processIdentifier: pid_t, point: CGPoint) -> Bool {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return false }
        var hitPID: pid_t = 0
        guard AXUIElementGetPid(hit, &hitPID) == .success, hitPID == processIdentifier else { return false }
        return accessibilityAncestorChainContains(hit: hit, target: target, equal: CFEqual,
            parent: { axElement($0, attribute: kAXParentAttribute) })
    }

    /// Hit testing must start at the system-wide element so overlapping windows
    /// from any application are considered. Only the target or a descendant is safe.
    static func accessibilityAncestorChainContains<Element>(hit: Element?, target: Element,
                                                           equal: (Element, Element) -> Bool,
                                                           parent: (Element) -> Element?) -> Bool {
        var current = hit
        var visited: [Element] = []
        for _ in 0..<32 {
            guard let element = current, !visited.contains(where: { equal($0, element) }) else { return false }
            if equal(element, target) { return true }
            visited.append(element)
            current = parent(element)
        }
        return false
    }

    static func isAntigravityMessageInput(_ candidate: AccessibilityTextCandidate) -> Bool {
        [candidate.title, candidate.description, candidate.help, candidate.placeholder]
            .contains { $0.lowercased() == "message input" }
    }

    static func integratedPreservationSnapshot(bundleIdentifier: String?, secureInputEnabled: Bool = false, read: (String) -> Any?,
                                               valueIsSettable: () -> Bool) -> VoiceInputDestinationSnapshot {
        let role = read(kAXRoleAttribute) as? String ?? ""
        let inputRole = ["AXTextArea", "AXTextField", "AXComboBox"].contains(role)
        let editable = inputRole && ((read("AXEditable") as? Bool) ?? valueIsSettable())
        let semantic = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXPlaceholderValueAttribute]
            .compactMap { read($0) as? String }.joined(separator: " ")
        return .init(bundleIdentifier: bundleIdentifier, role: role,
            subrole: read(kAXSubroleAttribute) as? String ?? "", enabled: read(kAXEnabledAttribute) as? Bool ?? true,
            editable: editable, protectedContent: read("AXProtectedContent") as? Bool ?? false,
            semanticText: semantic, secureInputEnabled: secureInputEnabled)
    }

    static func mayPreserveFocusedElement<Element>(_ input: Element, excluding target: Element?,
                                                    equal: (Element, Element) -> Bool) -> Bool {
        target.map { !equal(input, $0) } ?? true
    }

    static func shouldPreserveIntegratedInput(_ destination: VoiceInputDestinationSnapshot,
                                              integration: ApplicationIntegration) -> Bool {
        ApplicationIntegration.matching(destination.bundleIdentifier) == integration &&
            destination.enabled && destination.editable && !destination.isSensitiveDestination &&
            ["AXTextArea", "AXTextField", "AXComboBox"].contains(destination.role)
    }

    /// Labels observed in the applications' user-visible accessibility trees.
    /// Only these explicit composers may use the hit-tested click fallback.
    static func isVerifiedIntegratedComposer(_ candidate: AccessibilityTextCandidate,
                                            integration: ApplicationIntegration) -> Bool {
        let labels = [candidate.title, candidate.description, candidate.help, candidate.placeholder]
            .map(normalizedComposerLabel)
        switch integration {
        case .antigravity: return isAntigravityMessageInput(candidate)
        case .claude:
            let identifiers = ["chat-input", "prompt-textarea", "prompt-editor"]
            let prompts = ["write your prompt to claude", "write your reply to claude", "write your draft", "write your message",
                           "向 claude 发送消息", "回复 claude", "给 claude 发消息", "输入消息", "输入提示词"]
            return identifiers.contains(candidate.identifier.lowercased()) || labels.contains(where: prompts.contains)
        case .deepSeek:
            return candidate.role == "AXTextArea" && labels.contains {
                $0.hasPrefix("message or run a task")
            }
        case .workBuddy:
            return candidate.role == "AXTextArea" && candidate.hasWorkBuddyComposerControls
        case .weChat, .chatGPT: return false
        }
    }

    static func integratedComposerScore(_ candidate: AccessibilityTextCandidate,
                                        integration: ApplicationIntegration,
                                        windowFrame: CGRect?) -> Int? {
        guard candidate.enabled, !candidate.protectedContent,
              candidate.subrole != "AXSecureTextField",
              candidate.role == "AXTextArea" || candidate.role == "AXTextField",
              let frame = candidate.frame, frame.width > 0, frame.height > 0,
              let windowFrame, windowFrame.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
        // Ancestor/window titles are not evidence that a field is a composer.
        let ownText = [candidate.identifier, candidate.title, candidate.description,
                       candidate.help, candidate.placeholder].joined(separator: " ").lowercased()
        let excluded = ["search", "find", "filter", "password", "passcode", "secret", "api key",
                        "token", "rename", "title", "terminal", "console", "monaco", "code editor",
                        "搜索", "查找", "筛选", "密码", "密钥", "令牌", "重命名", "标题", "终端", "代码编辑器"]
        guard !containsSensitiveAccessibilityTerms(ownText),
              !excluded.contains(where: ownText.contains),
              !["monaco", "code editor", "terminal content area"].contains(where: candidate.context.lowercased().contains)
        else { return nil }
        let common = ["composer", "prompt-editor", "prompt_editor", "chat-input", "chat_input",
                      "message-input", "message_input", "message input", "prompt input", "chat input",
                      "输入消息", "消息输入", "发送消息"]
        let specific: [String]
        switch integration {
        case .chatGPT: specific = ["do anything", "work with chatgpt", "message chatgpt", "ask anything", "ask chatgpt", "询问任何问题", "询问 chatgpt"]
        case .antigravity: specific = ["ask anything", "ask agent", "message agent", "agent input", "向 agent 提问"]
        case .weChat: specific = ["message", "输入", "编辑消息"]
        case .claude, .deepSeek, .workBuddy: specific = []
        }
        // Verified in the live WeChat accessibility tree. Avoid its unlabeled
        // search field and message list even if they move or resize.
        if integration == .weChat {
            return candidate.identifier == "chat_input_field" ? 400 : nil
        }
        // Verified Antigravity's current conversation composer is labeled Message input.
        if isVerifiedIntegratedComposer(candidate, integration: integration) { return 400 }
        if integration == .claude || integration == .deepSeek || integration == .workBuddy { return nil }
        if (common + specific).contains(where: ownText.contains) {
            return 200 + (candidate.role == "AXTextArea" ? 20 : 0)
        }
        return nil
    }
}
