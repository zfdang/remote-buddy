import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

extension KeyboardInjector {
    static func weChatComposerFocusPoint(windowFrame: CGRect) -> CGPoint? {
        guard windowFrame.width >= 700, windowFrame.height >= 500 else { return nil }
        return CGPoint(
            x: windowFrame.minX + windowFrame.width * weChatComposerHorizontalRatio,
            y: windowFrame.minY + windowFrame.height * weChatComposerVerticalRatio
        )
    }

    static func usesWeChatComposerFallback(bundleIdentifier: String?) -> Bool {
        bundleIdentifier == weChatBundleIdentifier
    }

    static func weChatComposerWindowFrame(
        _ windows: [(title: String, frame: CGRect)]
    ) -> CGRect? {
        windows
            .filter {
                ($0.title == "微信" || $0.title == "WeChat") &&
                    weChatComposerFocusPoint(windowFrame: $0.frame) != nil
            }
            .map(\.frame)
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    static func focusWeChatComposer(processIdentifier: pid_t) -> Bool {
        guard !AXSelfTargetPolicy.isOwnProcess(processIdentifier) else { return false }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        return focusWeChatComposerFlow(
            isAlreadyFocused: {
                isWeChatComposerFocused(applicationElement: applicationElement)
            },
            performWindowClick: {
                guard let frame = weChatComposerWindowFrame(
                    applicationWindows(applicationElement).compactMap { window in
                        guard let frame = axFrame(window) else { return nil }
                        return (
                            title: axString(window, attribute: kAXTitleAttribute),
                            frame: frame
                        )
                    }
                ),
                      let point = weChatComposerFocusPoint(windowFrame: frame),
                      let source = CGEventSource(stateID: .hidSystemState),
                      let down = CGEvent(
                          mouseEventSource: source,
                          mouseType: .leftMouseDown,
                          mouseCursorPosition: point,
                          mouseButton: .left
                      ),
                      let up = CGEvent(
                          mouseEventSource: source,
                          mouseType: .leftMouseUp,
                          mouseCursorPosition: point,
                          mouseButton: .left
                      )
                else { return false }
                let previousPointerLocation = CGEvent(source: nil)?.location
                down.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
                up.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
                if let previousPointerLocation,
                   let restore = CGEvent(
                       mouseEventSource: source,
                       mouseType: .mouseMoved,
                       mouseCursorPosition: previousPointerLocation,
                       mouseButton: .left
                   ) {
                    restore.setIntegerValueField(.eventSourceUserData, value: syntheticEventMarker)
                    restore.post(tap: .cghidEventTap)
                }
                return true
            },
            pauseAfterClick: { usleep(30_000) },
            confirmFocused: {
                isWeChatComposerFocused(applicationElement: applicationElement)
            },
            moveCaretToEnd: {
                if let focusedElement = axElement(applicationElement, attribute: kAXFocusedUIElementAttribute) {
                    _ = moveAccessibilityCaretToEnd(
                        of: focusedElement,
                        canContinue: {
                            applicationIsFrontmost(processIdentifier) &&
                                isAccessibilityTrusted &&
                                !SecureInputMonitor.isEnabled() &&
                                isWeChatComposerFocused(applicationElement: applicationElement)
                        }
                    )
                }
            }
        )
    }

    static func focusWeChatComposerFlow(
        isAlreadyFocused: () -> Bool,
        performWindowClick: () -> Bool,
        pauseAfterClick: () -> Void = { usleep(30_000) },
        confirmFocused: () -> Bool,
        moveCaretToEnd: () -> Void
    ) -> Bool {
        if isAlreadyFocused() {
            return true
        }
        guard performWindowClick() else { return false }
        pauseAfterClick()
        guard confirmFocused() else { return false }
        moveCaretToEnd()
        return true
    }

    static func isWeChatComposerFocused(applicationElement: AXUIElement) -> Bool {
        guard let focusedElement = axElement(applicationElement, attribute: kAXFocusedUIElementAttribute) else {
            return false
        }
        let attributes = AccessibilityMessaging.attributes(
            focusedElement,
            keys: [
                kAXRoleAttribute,
                kAXSubroleAttribute,
                kAXIdentifierAttribute,
                kAXTitleAttribute,
                kAXDescriptionAttribute,
                kAXHelpAttribute,
                kAXPlaceholderValueAttribute,
                kAXFocusedAttribute
            ]
        )
        let semanticText = [
            attributes[kAXIdentifierAttribute] as? String,
            attributes[kAXTitleAttribute] as? String,
            attributes[kAXDescriptionAttribute] as? String,
            attributes[kAXHelpAttribute] as? String,
            attributes[kAXPlaceholderValueAttribute] as? String
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        return isWeChatComposerElementFocused(
            role: attributes[kAXRoleAttribute] as? String,
            subrole: attributes[kAXSubroleAttribute] as? String,
            identifier: attributes[kAXIdentifierAttribute] as? String,
            semanticText: semanticText,
            isFocused: attributes[kAXFocusedAttribute] as? Bool
        )
    }

    static func isWeChatComposerElementFocused(
        role: String?,
        subrole: String?,
        identifier: String?,
        semanticText: String,
        isFocused: Bool?
    ) -> Bool {
        guard role == "AXTextArea" || role == "AXTextField" else {
            return false
        }
        if subrole == "AXSearchField" || subrole == kAXSecureTextFieldSubrole {
            return false
        }
        let normalizedIdentifier = (identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedIdentifier.isEmpty && normalizedIdentifier != "chat_input_field" {
            return false
        }
        let normalizedSemantic = semanticText.lowercased()
        if containsSensitiveAccessibilityTerms(normalizedSemantic) ||
            ["search", "find", "filter", "搜索", "查找", "筛选"].contains(where: normalizedSemantic.contains) {
            return false
        }
        return isFocused ?? true
    }

    static func normalizedComposerLabel(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".…")))
    }

    static func workBuddyComposerControlsMatch(_ labels: [String]) -> Bool {
        let labels = labels.map(normalizedComposerLabel)
        let send = ["发送", "send", "send message", "envoyer", "送信", "kirim", "send-message"]
        let stop = ["停止", "停止生成", "stop", "stop generating", "stop generation"]
        let more = ["更多操作", "more actions", "plus d'actions", "その他の操作", "その他のアクション", "tindakan lainnya", "aksi lainnya", "more-actions"]
        let voice = ["语音输入", "voice input", "saisie vocale", "音声入力", "input suara", "masukan suara", "voice-input"]
        // WorkBuddy replaces Send with Stop while a reply is being generated.
        // Both states still require the same local editor, More and Voice controls.
        return labels.contains(where: { send.contains($0) || stop.contains($0) }) && labels.contains(where: more.contains) &&
            labels.contains { label in voice.contains { label == $0 || label.hasPrefix($0 + " ") } }
    }

    /// Do not depend on WorkBuddy's placeholder being field metadata;
    /// it can be exposed only as editor content. Verify the same composer's surrounding controls instead;
    /// never read the text area's value or the conversation's static text.
    static func workBuddyComposerControlsSurround(_ input: AXUIElement) -> Bool {
        workBuddyComposerAncestorsMatch(input,
            parent: { axElement($0, attribute: kAXParentAttribute) },
            role: { axString($0, attribute: kAXRoleAttribute) },
            equal: { CFEqual($0, $1) },
            matches: { group in workBuddyComposerGroupMatches(group,
                role: { axString($0, attribute: kAXRoleAttribute) },
                children: { axElements($0, attribute: kAXChildrenAttribute) },
                controlLabels: { element in
                    [axString(element, attribute: kAXIdentifierAttribute),
                     axString(element, attribute: kAXTitleAttribute),
                     axString(element, attribute: kAXDescriptionAttribute),
                     axString(element, attribute: kAXHelpAttribute)]
                }) })
    }

    /// The editor is nested inside an inner layout group; its action bar is a
    /// sibling of that group. Stay within a small chain of layout ancestors.
    static func workBuddyComposerAncestorsMatch<Element>(_ input: Element,
        parent: (Element) -> Element?, role: (Element) -> String,
        equal: (Element, Element) -> Bool, matches: (Element) -> Bool) -> Bool {
        var current = input
        var visited = [input]
        var budget = AccessibilityTraversalBudget(maximumNodes: 3, maximumDuration: 0.15)
        while budget.admitNode(), let ancestor = parent(current) {
            guard role(ancestor) == "AXGroup", !visited.contains(where: { equal($0, ancestor) }) else { return false }
            if matches(ancestor) { return true }
            visited.append(ancestor)
            current = ancestor
        }
        return false
    }

    static func workBuddyComposerGroupMatches<Element>(_ root: Element,
        role: (Element) -> String, children: (Element) -> [Element],
        controlLabels: (Element) -> [String]) -> Bool {
        var pending: [(Element, Int)] = [(root, 0)]
        var labels: [String] = []
        var budget = AccessibilityTraversalBudget(maximumNodes: 96, maximumDuration: 0.15)
        var editors = 0
        while let (element, depth) = pending.popLast() {
            guard budget.admitNode() else { return false }
            let currentRole = role(element)
            if currentRole == "AXTextArea" { editors += 1 }
            if currentRole == "AXButton" || currentRole == "AXPopUpButton" {
                labels += controlLabels(element)
            }
            // Only descend through layout groups, not message/editor content.
            if depth == 0 || ["AXGroup", "AXToolbar"].contains(currentRole) {
                let nested = children(element)
                guard depth < 5 || nested.isEmpty else { return false }
                pending += nested.map { ($0, depth + 1) }
            }
        }
        return editors == 1 && workBuddyComposerControlsMatch(labels)
    }

    static func focusCmuxTerminal(
        processIdentifier: pid_t,
        canContinue: () -> Bool = { true },
        allowClickFallback: Bool = false,
        didAttemptClick: (() -> Void)? = nil,
        keyPoster: KeyPoster
    ) -> Bool {
        guard !AXSelfTargetPolicy.isOwnProcess(processIdentifier), canContinue() else { return false }
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var terminalFrame: CGRect?
        var primaryTerminalTarget: (
            element: AXUIElement,
            snapshot: AccessibilityTextCandidate,
            windowFrame: CGRect?
        )?
        for window in applicationWindows(applicationElement) {
            guard canContinue() else { return false }
            let windowFrame = axFrame(window)
            let candidates = accessibilityTextCandidates(in: window)
            guard let candidateIndex = bestCmuxTerminalCandidateIndex(
                candidates.map(\.snapshot),
                windowFrame: windowFrame
            ) else { continue }
            let candidate = candidates[candidateIndex]
            terminalFrame = terminalFrame ?? candidate.snapshot.frame
            if primaryTerminalTarget == nil {
                primaryTerminalTarget = (candidate.element, candidate.snapshot, windowFrame)
            }
            if focusAccessibilityElement(
                candidate.element,
                applicationElement: applicationElement,
                requiresApplicationFocusedElement: true,
                canWriteFocus: canContinue
            ) {
                return true
            }
        }

        guard canContinue() else { return false }
        let focusedElementSnapshot = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ).map { focusedElement in
            (
                role: axString(focusedElement, attribute: kAXRoleAttribute),
                frame: axFrame(focusedElement)
            )
        }
        if let keyCode = cmuxFocusRecoveryShortcutKeyCode(
            focusedRole: focusedElementSnapshot?.role,
            focusedFrame: focusedElementSnapshot?.frame,
            terminalFrame: terminalFrame
        ) {
            keyPoster(keyCode, [.maskCommand, .maskShift])
            return false
        }
        if allowClickFallback, let target = primaryTerminalTarget {
            return clickCmuxTerminalCandidate(
                target.snapshot,
                windowFrame: target.windowFrame,
                canContinue: canContinue,
                hitTest: {
                    accessibilityHitTestMatchesTarget(
                        target.element,
                        processIdentifier: processIdentifier,
                        point: $0
                    )
                },
                postClick: { point in
                    didAttemptClick?()
                    return postAccessibilityFocusClick(point)
                },
                isFocused: {
                    accessibilityElementIsFocused(
                        target.element,
                        applicationElement: applicationElement,
                        requiresApplicationFocusedElement: true
                    )
                }
            )
        }
        return false
    }

    static func cmuxTerminalClickPoint(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?
    ) -> CGPoint? {
        guard cmuxTerminalCandidateScore(candidate, windowFrame: windowFrame) != nil,
              let frame = candidate.frame,
              let windowFrame
        else { return nil }
        let visibleFrame = frame.intersection(windowFrame)
        guard !visibleFrame.isNull,
              visibleFrame.width >= 48,
              visibleFrame.height >= 32
        else { return nil }
        let point = CGPoint(
            x: visibleFrame.minX + min(24, visibleFrame.width / 2),
            y: visibleFrame.minY + min(24, visibleFrame.height / 2)
        )
        guard point.x.isFinite, point.y.isFinite, windowFrame.contains(point) else { return nil }
        return point
    }

    static func clickCmuxTerminalCandidate(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?,
        canContinue: () -> Bool,
        hitTest: (CGPoint) -> Bool,
        postClick: (CGPoint) -> Bool = postAccessibilityFocusClick,
        isFocused: () -> Bool,
        pause: () -> Void = { usleep(50_000) }
    ) -> Bool {
        guard canContinue() else { return false }
        if isFocused() { return true }
        guard let point = cmuxTerminalClickPoint(candidate, windowFrame: windowFrame),
              hitTest(point),
              canContinue()
        else { return false }
        if isFocused() { return true }
        guard postClick(point) else { return false }
        for _ in 0..<5 {
            guard canContinue() else { return false }
            if isFocused() { return true }
            pause()
        }
        return canContinue() && isFocused()
    }

    static func cmuxFocusRecoveryShortcutKeyCode(
        focusedRole: String?,
        focusedFrame: CGRect?,
        terminalFrame: CGRect?
    ) -> CGKeyCode? {
        if let focusedFrame, let terminalFrame,
           focusedFrame.minX >= terminalFrame.maxX {
            return 14 // Cmd+Shift+E: cmux Toggle Right Sidebar Focus returns to the terminal.
        }
        switch focusedRole {
        case "AXTextArea", "AXTextField":
            return 0 // Cmd+Shift+A: cmux Focus TextBox Input toggles back to the terminal.
        case nil, "", "AXApplication", "AXWindow":
            return nil
        default:
            return nil // Left-sidebar and other controls are recovered by the scheduled surface.focus retry.
        }
    }

    static func bestCmuxTerminalCandidateIndex(
        _ candidates: [AccessibilityTextCandidate],
        windowFrame: CGRect?
    ) -> Int? {
        var best: (index: Int, score: Int)?
        for index in candidates.indices {
            guard let score = cmuxTerminalCandidateScore(candidates[index], windowFrame: windowFrame) else {
                continue
            }
            if best.map({ score > $0.score }) ?? true {
                best = (index, score)
            }
        }
        return best?.index
    }

    static func cmuxTerminalCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, !candidate.protectedContent, candidate.subrole != kAXSecureTextFieldSubrole,
              candidate.role == "AXTextArea" else { return nil }
        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ]
        .joined(separator: " ")
        .lowercased()
        guard semanticText.contains("terminal content area") else { return nil }

        var score = 200
        if candidate.focused { score += 1_000 }
        if candidate.selectedContext { score += 500 }
        if let frame = candidate.frame {
            score += min(100, Int(frame.width * frame.height / 10_000))
            if let windowFrame, frame.intersects(windowFrame) { score += 100 }
        }
        return score
    }

    @discardableResult
    static func focusCmux(
        applicationURL: URL,
        cliURL: URL? = nil,
        cliResolver: (URL) -> URL? = { cmuxCLIURL(applicationURL: $0) },
        runner: CmuxCommandRunner = runCmuxCommand,
        canContinue: () -> Bool = { true },
        terminalFocuser: (String) -> Bool = { _ in true }
    ) -> Bool {
        guard canContinue() else { return false }
        guard let cliURL = cliURL ?? cliResolver(applicationURL) else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=cli_unavailable")
            return canContinue() && terminalFocuser("")
        }

        let currentResult = runner(cliURL, ["rpc", "surface.current", "{}"], 1)
        guard !currentResult.timedOut, currentResult.terminationStatus == 0 else {
            // Default cmux socket auth rejects external processes not launched inside cmux;
            // fall back directly to Accessibility terminal focus.
            let reason = currentResult.timedOut ? "current_timeout" : "current_failed"
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=\(reason)")
            return canContinue() && terminalFocuser("")
        }
        guard canContinue() else { return false }
        guard let payload = try? JSONSerialization.jsonObject(with: currentResult.standardOutput) as? [String: Any],
              let surfaceType = (payload["surface_type"] as? String) ?? (payload["type"] as? String)
        else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=invalid_current_payload")
            return canContinue() && terminalFocuser("")
        }
        guard surfaceType.caseInsensitiveCompare("terminal") == .orderedSame else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=no_current_terminal")
            return false
        }
        guard let surfaceID = payload["surface_id"] as? String,
              UUID(uuidString: surfaceID) != nil
        else {
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=invalid_current_payload")
            return canContinue() && terminalFocuser("")
        }

        guard let focusParameters = try? JSONSerialization.data(
            withJSONObject: ["surface_id": surfaceID],
            options: [.sortedKeys]
        ), let focusJSON = String(data: focusParameters, encoding: .utf8) else {
            return canContinue() && terminalFocuser(surfaceID)
        }
        guard canContinue() else { return false }

        let focusResult = runner(cliURL, ["rpc", "surface.focus", focusJSON], 1)
        if focusResult.timedOut || focusResult.terminationStatus != 0 {
            let reason = focusResult.timedOut ? "focus_timeout" : "focus_failed"
            AppLogger.shared.write("APP FOCUS failed bundle=\(PresetApplication.cmux.bundleIdentifier) method=cmux_api reason=\(reason)")
        }
        guard canContinue() else { return false }
        return terminalFocuser(surfaceID)
    }

    static func cmuxCLIURL(
        applicationURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let candidates = [
            applicationURL.appendingPathComponent("Contents/bin/cmux"),
            applicationURL.appendingPathComponent("Contents/Resources/bin/cmux"),
            URL(fileURLWithPath: "/opt/homebrew/bin/cmux"),
            URL(fileURLWithPath: "/usr/local/bin/cmux"),
        ]

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private static func runCmuxCommand(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) -> CmuxCommandResult {
        BoundedCommandRunner.run(executableURL: executableURL, arguments: arguments, timeout: timeout)
    }
}
