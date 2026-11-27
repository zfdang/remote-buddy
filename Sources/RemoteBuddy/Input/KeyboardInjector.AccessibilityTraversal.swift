import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

extension KeyboardInjector {
    static func captureFocusedAccessibilityTargetAsync(
        bundleIdentifier: String, completion: @escaping (AccessibilityFocusTarget?) -> Void
    ) {
        nonisolated(unsafe) let completion = completion
        focusQueue.async {
            let target = captureFocusedAccessibilityTarget(bundleIdentifier: bundleIdentifier)
            DispatchQueue.main.async { completion(target) }
        }
    }

    static func captureFocusedAccessibilityTarget(
        bundleIdentifier: String
    ) -> AccessibilityFocusTarget? {
        guard isAccessibilityTrusted else { return nil }
        let systemWideElement = AXUIElementCreateSystemWide()
        guard let focusedElement = axElement(
            systemWideElement,
            attribute: kAXFocusedUIElementAttribute
        ) else { return nil }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success,
              NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier == bundleIdentifier
        else { return nil }

        let role = axString(focusedElement, attribute: kAXRoleAttribute)
        guard role == "AXTextArea" || role == "AXTextField",
              axBool(focusedElement, attribute: kAXEnabledAttribute) ?? true
        else { return nil }

        var contextParts: [String] = []
        var current = axElement(focusedElement, attribute: kAXParentAttribute)
        var window = axElement(focusedElement, attribute: kAXWindowAttribute)
        var ancestorCount = 0
        while let element = current, ancestorCount < 8 {
            let semanticText = axSemanticText(element)
            if !semanticText.isEmpty {
                contextParts.append(semanticText)
            }
            if axString(element, attribute: kAXRoleAttribute) == "AXWindow" {
                window = window ?? element
                break
            }
            current = axElement(element, attribute: kAXParentAttribute)
            ancestorCount += 1
        }

        let context = String(contextParts.joined(separator: " ").suffix(512))
        let target = AccessibilityFocusTarget(
            role: role,
            identifier: axString(focusedElement, attribute: kAXIdentifierAttribute),
            title: axString(focusedElement, attribute: kAXTitleAttribute),
            description: axString(focusedElement, attribute: kAXDescriptionAttribute),
            help: axString(focusedElement, attribute: kAXHelpAttribute),
            placeholder: axString(focusedElement, attribute: kAXPlaceholderValueAttribute),
            context: context,
            windowTitle: window.map { axString($0, attribute: kAXTitleAttribute) } ?? "",
            normalizedFrame: normalizedAccessibilityFrame(
                elementFrame: axFrame(focusedElement),
                windowFrame: window.flatMap(axFrame)
            )
        )
        let semanticText = [
            target.identifier,
            target.title,
            target.description,
            target.help,
            target.placeholder,
            target.context,
        ].joined(separator: " ")
        guard !containsSensitiveAccessibilityTerms(semanticText),
              !semanticText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return target
    }

    static func focusRecordedAccessibilityTarget(
        _ target: AccessibilityFocusTarget,
        processIdentifier: pid_t
    ) -> Bool {
        let applicationElement = AXUIElementCreateApplication(processIdentifier)
        var ranked: [(element: AXUIElement, score: Int)] = []
        for window in applicationWindows(applicationElement) {
            let windowFrame = axFrame(window)
            let windowTitle = axString(window, attribute: kAXTitleAttribute)
            for candidate in accessibilityTextCandidates(in: window) {
                guard let score = recordedAccessibilityCandidateScore(
                    candidate.snapshot,
                    target: target,
                    windowTitle: windowTitle,
                    windowFrame: windowFrame
                ) else { continue }
                ranked.append((candidate.element, score))
            }
        }
        ranked.sort { $0.score > $1.score }
        guard let best = ranked.first,
              ranked.dropFirst().first.map({ best.score - $0.score >= 40 }) ?? true
        else { return false }
        return focusAccessibilityElement(
            best.element,
            applicationElement: applicationElement,
            requiresApplicationFocusedElement: true
        )
    }

    static func recordedAccessibilityCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        target: AccessibilityFocusTarget,
        windowTitle: String,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, !candidate.protectedContent, candidate.subrole != kAXSecureTextFieldSubrole,
              candidate.role == target.role else { return nil }
        let semanticText = [
            candidate.identifier,
            candidate.title,
            candidate.description,
            candidate.help,
            candidate.placeholder,
            candidate.context,
        ].joined(separator: " ")
        guard !containsSensitiveAccessibilityTerms(semanticText) else { return nil }

        var score = 0
        var strongMatches = 0
        if semanticValuesMatch(candidate.identifier, target.identifier) {
            score += 500
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.placeholder, target.placeholder) {
            score += 220
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.title, target.title) {
            score += 140
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.description, target.description) {
            score += 140
            strongMatches += 1
        }
        if semanticValuesMatch(candidate.help, target.help) {
            score += 100
            strongMatches += 1
        }
        if semanticValuesMatch(windowTitle, target.windowTitle) {
            score += 100
        }

        let contextSimilarity = accessibilityContextSimilarity(candidate.context, target.context)
        score += Int(contextSimilarity * 180)
        if contextSimilarity >= 0.5 {
            strongMatches += 1
        }

        if let targetFrame = target.normalizedFrame,
           let candidateFrame = normalizedAccessibilityFrame(
               elementFrame: candidate.frame,
               windowFrame: windowFrame
           )
        {
            let distance = abs(targetFrame.x - candidateFrame.x) +
                abs(targetFrame.y - candidateFrame.y) +
                abs(targetFrame.width - candidateFrame.width) +
                abs(targetFrame.height - candidateFrame.height)
            // Geometry contributes at most 120 points. Distant or overflowing
            // coordinates contribute nothing; never convert an unbounded Double
            // from imported metadata or AX geometry to Int.
            if distance.isFinite, distance < 1 {
                score += 120 - Int(distance * 120)
            }
        }

        guard strongMatches > 0 else { return nil }
        return score >= 180 ? score : nil
    }

    static func normalizedAccessibilityFrame(
        elementFrame: CGRect?,
        windowFrame: CGRect?
    ) -> NormalizedAccessibilityFrame? {
        guard let elementFrame, let windowFrame,
              windowFrame.width > 0, windowFrame.height > 0
        else { return nil }
        return NormalizedAccessibilityFrame(
            x: (elementFrame.minX - windowFrame.minX) / windowFrame.width,
            y: (elementFrame.minY - windowFrame.minY) / windowFrame.height,
            width: elementFrame.width / windowFrame.width,
            height: elementFrame.height / windowFrame.height
        )
    }

    static func semanticValuesMatch(_ lhs: String, _ rhs: String) -> Bool {
        let lhs = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhs = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        return min(lhs.count, rhs.count) >= 4 && (lhs.contains(rhs) || rhs.contains(lhs))
    }

    static func accessibilityContextSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = accessibilityTokens(lhs)
        let right = accessibilityTokens(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(max(left.count, right.count))
    }

    static func accessibilityTokens(_ value: String) -> Set<String> {
        Set(
            value.lowercased().components(
                separatedBy: CharacterSet.alphanumerics.inverted
            ).filter { $0.count >= 2 }
        )
    }

    static func containsSensitiveAccessibilityTerms(_ value: String) -> Bool {
        let value = value.lowercased()
        let terms = [
            "password", "passcode", "secret", "api key", "apikey", "token", "credit card",
            "密码", "口令", "密钥", "令牌", "银行卡", "借记卡", "信用卡",
        ]
        return terms.contains(where: value.contains)
    }

    static func applicationWindows(_ applicationElement: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []
        for window in [
            axElement(applicationElement, attribute: kAXFocusedWindowAttribute),
            axElement(applicationElement, attribute: kAXMainWindowAttribute),
        ].compactMap({ $0 }) + axElements(applicationElement, attribute: kAXWindowsAttribute) {
            if !windows.contains(where: { CFEqual($0, window) }) {
                windows.append(window)
            }
        }
        return windows
    }

    /// Roles whose children only decorate a control or render message content.
    /// Integrated composers are editing controls, never descendants of these leaves.
    static func isIntegratedScanLeaf(_ role: String) -> Bool {
        ["AXStaticText", "AXImage", "AXListMarker", "AXButton", "AXPopUpButton",
         "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXSlider",
         "AXProgressIndicator"].contains(role)
    }

    static func accessibilityTextCandidates(
        in window: AXUIElement, integration: ApplicationIntegration? = nil,
        didScan: ((Int, Bool) -> Void)? = nil
    ) -> [(element: AXUIElement, snapshot: AccessibilityTextCandidate)] {
        struct PendingElement {
            let element: AXUIElement
            let role: String
            let frame: CGRect?
            let context: String
            let selectedContext: Bool
        }
        let contextKeys = [kAXIdentifierAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
                           kAXHelpAttribute, kAXPlaceholderValueAttribute]
        let windowFrame = axFrame(window)
        var stack = [PendingElement(element: window, role: axString(window, attribute: kAXRoleAttribute),
            frame: windowFrame, context: "", selectedContext: false)]
        var visitedElements: [CFHashCode: [AXUIElement]] = [CFHash(window): [window]]
        var budget = AccessibilityTraversalBudget(maximumNodes: maximumAccessibilityTraversalCount)
        var candidates: [(element: AXUIElement, snapshot: AccessibilityTextCandidate)] = []
        var scannedNodes = 0
        var truncated = false
        defer { didScan?(scannedNodes, truncated || !stack.isEmpty) }
        guard budget.admitNode() else { return [] }
        while !stack.isEmpty, budget.hasTimeRemaining {
            let current = stack.removeLast()
            scannedNodes += 1
            let isEditor = current.role == "AXTextArea" || current.role == "AXTextField"
            let keys = contextKeys + [kAXSelectedAttribute] + (isEditor
                ? [kAXSubroleAttribute, "AXProtectedContent", kAXEnabledAttribute, kAXFocusedAttribute] : []) +
                (isEditor && integration != nil ? [] : accessibilityChildAttributes)
            let attributes = accessibilityScanAttributes(current.element, keys: keys)
            let ownContext = contextKeys.compactMap { attributes[$0] as? String }
                .filter { !$0.isEmpty }.joined(separator: " ")
            let combinedContext = [current.context, ownContext].filter { !$0.isEmpty }.joined(separator: " ")
            let selectedContext = current.selectedContext || (attributes[kAXSelectedAttribute] as? Bool ?? false)
            if isEditor {
                candidates.append((current.element,
                    accessibilityTextMetadata(role: current.role, frame: current.frame, context: combinedContext,
                        selectedContext: selectedContext,
                        hasWorkBuddyComposerControls: integration == .workBuddy && current.role == "AXTextArea" &&
                            workBuddyComposerControlsSurround(current.element),
                        read: { attributes[$0] })))
                // Rich editors expose their document contents as children. Other
                // candidate editors remain reachable through their layout parents.
                if integration != nil { continue }
            }
            let childContext = String(combinedContext.suffix(512))
            var children: [(node: PendingElement, priority: Int)] = []
            for attribute in accessibilityChildAttributes {
                guard budget.hasTimeRemaining else { truncated = true; break }
                for child in attributes[attribute] as? [AXUIElement] ?? [] {
                    let hash = CFHash(child)
                    if visitedElements[hash]?.contains(where: { CFEqual($0, child) }) == true { continue }
                    var role = ""
                    var frame: CGRect?
                    guard let priority = accessibilityChildPriority(role: {
                        let metadata = accessibilityScanAttributes(child,
                            keys: [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute])
                        role = metadata[kAXRoleAttribute] as? String ?? ""
                        frame = accessibilityFrame(read: { metadata[$0] })
                        return role
                    }, frame: { frame }, windowFrame: windowFrame, budget: &budget)
                    else { truncated = true; break }
                    visitedElements[hash, default: []].append(child)
                    if integration != nil, isIntegratedScanLeaf(role) { continue }
                    children.append((PendingElement(element: child, role: role, frame: frame,
                        context: childContext, selectedContext: selectedContext), priority))
                }
            }
            children.sort { $0.priority < $1.priority }
            stack.append(contentsOf: children.map(\.node))
        }
        return candidates
    }

    private static func accessibilityScanAttributes(_ element: AXUIElement, keys: [String]) -> [String: Any] {
        let attributes = AccessibilityMessaging.attributes(element, keys: keys)
        if !attributes.isEmpty { return attributes }
        // Some native controls do not implement the batch API. Preserve coverage
        // through the same public metadata keys, without querying editing values.
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            axAttribute(element, attribute: key).map { (key, $0 as Any) }
        })
    }

    /// Metadata-only reader shared by automatic and explicit focus scans. There
    /// is deliberately no text value, text selection, or write operation here.
    static func accessibilityTextMetadata(role: String, frame: CGRect?, context: String,
                                          selectedContext: Bool, hasWorkBuddyComposerControls: Bool = false,
                                          read: (String) -> Any?) -> AccessibilityTextCandidate {
        AccessibilityTextCandidate(role: role,
            subrole: read(kAXSubroleAttribute) as? String ?? "",
            protectedContent: read("AXProtectedContent") as? Bool ?? false,
            identifier: read(kAXIdentifierAttribute) as? String ?? "",
            title: read(kAXTitleAttribute) as? String ?? "",
            description: read(kAXDescriptionAttribute) as? String ?? "",
            help: read(kAXHelpAttribute) as? String ?? "",
            placeholder: read(kAXPlaceholderValueAttribute) as? String ?? "",
            context: context, frame: frame,
            enabled: read(kAXEnabledAttribute) as? Bool ?? true,
            focused: read(kAXFocusedAttribute) as? Bool ?? false, selectedContext: selectedContext,
            hasWorkBuddyComposerControls: hasWorkBuddyComposerControls)
    }

    static func accessibilityChildPriority(role: () -> String, frame: () -> CGRect?,
                                           windowFrame: CGRect?, budget: inout AccessibilityTraversalBudget) -> Int? {
        guard budget.admitNode() else { return nil }
        let roleValue = role()
        guard budget.hasTimeRemaining else { return nil }
        return accessibilityTraversalPriority(role: roleValue, frame: frame(), windowFrame: windowFrame)
    }

    static func accessibilityTraversalPriority(
        role: String,
        frame: CGRect?,
        windowFrame: CGRect?
    ) -> Int {
        var priority = role == "AXTextArea" || role == "AXTextField" ? 1_000_000 : 0
        guard let frame, let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else {
            return priority
        }
        if frame.intersects(windowFrame) {
            priority += 100_000
        }
        let verticalPosition = (frame.midY - windowFrame.minY) / windowFrame.height
        priority += Int(max(0, min(1, verticalPosition)) * 10_000)
        return priority
    }

    static func focusAccessibilityElement(
        _ element: AXUIElement,
        applicationElement: AXUIElement,
        requiresApplicationFocusedElement: Bool = false,
        allowPress: Bool = true,
        canWriteFocus: () -> Bool = { true },
        isFocused: (() -> Bool)? = nil,
        setAttribute: (AXUIElement, CFString, CFTypeRef) -> AXError = AXUIElementSetAttributeValue,
        performAction: (AXUIElement, CFString) -> AXError = AXUIElementPerformAction
    ) -> Bool {
        let focused = isFocused ?? {
            accessibilityElementIsFocused(element, applicationElement: applicationElement,
                requiresApplicationFocusedElement: requiresApplicationFocusedElement)
        }
        if focused() { return true }
        guard canWriteFocus() else { return false }
        _ = setAttribute(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if focused() { return true }
        guard canWriteFocus() else { return false }
        _ = setAttribute(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            element
        )
        if focused() { return true }
        guard allowPress, canWriteFocus() else { return false }
        _ = performAction(element, kAXPressAction as CFString)
        return focused()
    }

    static func accessibilityElementIsFocused(
        _ element: AXUIElement,
        applicationElement: AXUIElement,
        requiresApplicationFocusedElement: Bool
    ) -> Bool {
        let applicationFocusedElementMatches = axElement(
            applicationElement,
            attribute: kAXFocusedUIElementAttribute
        ).map { CFEqual($0, element) }
        return accessibilityFocusIsConfirmed(
            elementFocused: axBool(element, attribute: kAXFocusedAttribute) == true,
            applicationFocusedElementMatches: applicationFocusedElementMatches,
            requiresApplicationFocusedElement: requiresApplicationFocusedElement
        )
    }

    static func accessibilityFocusIsConfirmed(
        elementFocused: Bool,
        applicationFocusedElementMatches: Bool?,
        requiresApplicationFocusedElement: Bool
    ) -> Bool {
        if requiresApplicationFocusedElement {
            return applicationFocusedElementMatches == true
        }
        return elementFocused || applicationFocusedElementMatches == true
    }

    static func bestComposerCandidateIndex(
        _ candidates: [AccessibilityTextCandidate],
        windowFrame: CGRect?
    ) -> Int? {
        var best: (index: Int, score: Int)?
        for index in candidates.indices {
            guard let score = composerCandidateScore(candidates[index], windowFrame: windowFrame) else {
                continue
            }
            if best.map({ score > $0.score }) ?? true {
                best = (index, score)
            }
        }
        return best?.index
    }

    static func composerCandidateScore(
        _ candidate: AccessibilityTextCandidate,
        windowFrame: CGRect?
    ) -> Int? {
        guard candidate.enabled, !candidate.protectedContent,
              candidate.subrole != kAXSecureTextFieldSubrole,
              candidate.role == "AXTextArea" || candidate.role == "AXTextField" else {
            return nil
        }

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

        let excludedTerms = [
            "title", "rename", "api key", "apikey", "token", "password", "secret",
            "command palette", "address bar", "approval", "permission", "code editor", "monaco",
            "标题", "重命名", "密钥", "令牌", "密码", "审批", "权限", "代码编辑器",
        ]
        guard !excludedTerms.contains(where: semanticText.contains) else { return nil }

        let strongTerms = [
            "composer", "prompt-editor", "prompt_editor", "chat-input", "chat_input",
            "message-input", "message_input", "prompt input", "message input",
            "消息输入", "输入消息", "发送消息",
        ]
        let supportingTerms = [
            "message", "prompt", "reply", "ask claude", "ask anything", "chat", "提问", "回复",
        ]
        let explicitlyAllowedTerms = [
            "search", "find", "filter", "settings", "preferences", "terminal", "console", "shell", "xterm",
            "搜索", "查找", "筛选", "设置", "偏好", "终端", "控制台",
        ]
        let hasStrongSemanticMatch = strongTerms.contains(where: semanticText.contains)
        let hasSupportingSemanticMatch = supportingTerms.contains(where: semanticText.contains)
        let hasExplicitlyAllowedMatch = explicitlyAllowedTerms.contains(where: semanticText.contains)
        guard candidate.role == "AXTextArea" || hasStrongSemanticMatch || hasSupportingSemanticMatch ||
                hasExplicitlyAllowedMatch else {
            return nil
        }

        var score = candidate.role == "AXTextArea" ? 50 : 0
        if hasStrongSemanticMatch {
            score += 120
        } else if hasSupportingSemanticMatch {
            score += 70
        } else if hasExplicitlyAllowedMatch {
            score += 80
        }

        if let frame = candidate.frame {
            if frame.width >= 280 { score += 25 }
            if (24...500).contains(frame.height) { score += 10 }
            if let windowFrame, windowFrame.width > 0, windowFrame.height > 0 {
                if frame.width / windowFrame.width >= 0.45 { score += 30 }
                let verticalPosition = (frame.midY - windowFrame.minY) / windowFrame.height
                if verticalPosition >= 0.55 {
                    score += 20
                } else if verticalPosition <= 0.25 {
                    score -= 15
                }
            }
        }

        return score >= 80 ? score : nil
    }

    static func axAttribute(_ element: AXUIElement, attribute: String) -> CFTypeRef? {
        AccessibilityMessaging.prepareQueries()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func axString(_ element: AXUIElement, attribute: String) -> String {
        axAttribute(element, attribute: attribute) as? String ?? ""
    }

    static func axBool(_ element: AXUIElement, attribute: String) -> Bool? {
        axAttribute(element, attribute: attribute) as? Bool
    }

    static func axNumberOfCharacters(_ element: AXUIElement) -> Int? {
        (axAttribute(element, attribute: kAXNumberOfCharactersAttribute) as? NSNumber)?.intValue
    }

    static func axSelectedTextRange(_ element: AXUIElement) -> CFRange? {
        guard let value = axAttribute(element, attribute: kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return range
    }

    static func axSelectedTextRangeIsSettable(_ element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &settable
        ) == .success && settable.boolValue
    }

    static func axWriteSelectedTextRange(_ range: CFRange, to element: AXUIElement) -> Bool {
        var mutableRange = range
        guard let axRange = AXValueCreate(.cfRange, &mutableRange) else { return false }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            axRange
        ) == .success
    }

    static func permitsCaretMoveToEndShortcut(flags: CGEventFlags) -> Bool {
        flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]).isEmpty
    }

    @discardableResult
    static func sendMoveCaretToEndShortcut(
        hardwareFlags: @escaping () -> CGEventFlags = KeyboardHardwareModifierPolicy.current,
        eventPoster: @escaping (CGEvent) -> Bool = ShortcutEventSequence.post,
        logger: @escaping (String) -> Void = { AppLogger.shared.write($0) }
    ) -> Bool {
        let physical = hardwareFlags()
        guard permitsCaretMoveToEndShortcut(flags: physical) else {
            logger("COMPOSER CARET_MOVE skipped reason=modifiers_held flags=\(physical.rawValue)")
            return false
        }
        return ShortcutEventSequence.send(
            keyCode: 125,
            modifiers: .maskCommand,
            hardwareFlags: hardwareFlags,
            eventPoster: eventPoster,
            logger: logger
        )
    }

    /// Moves the caret to the end of a newly auto-focused composer without reading
    /// any text contents: prefers writing `kAXSelectedTextRangeAttribute` to the
    /// character count, falling back to Command+Down when the host editor ignores AX writes.
    @discardableResult
    static func moveAccessibilityCaretToEnd(
        of element: AXUIElement,
        canContinue: () -> Bool,
        postMoveToEndKey: () -> Bool = { sendMoveCaretToEndShortcut() },
        pause: () -> Void = { usleep(20_000) }
    ) -> Bool {
        moveIntegratedComposerCaretToEnd(
            readNumberOfCharacters: { axNumberOfCharacters(element) },
            readSelectedRange: { axSelectedTextRange(element) },
            isSelectedRangeSettable: { axSelectedTextRangeIsSettable(element) },
            writeSelectedRange: { axWriteSelectedTextRange($0, to: element) },
            canContinue: canContinue,
            postMoveToEndKey: postMoveToEndKey,
            pause: pause
        )
    }

    @discardableResult
    static func moveIntegratedComposerCaretToEnd(
        readNumberOfCharacters: () -> Int?,
        readSelectedRange: () -> CFRange?,
        isSelectedRangeSettable: () -> Bool,
        writeSelectedRange: (CFRange) -> Bool,
        canContinue: () -> Bool,
        postMoveToEndKey: () -> Bool,
        pause: () -> Void = { usleep(20_000) }
    ) -> Bool {
        guard canContinue() else { return false }
        if let characterCount = readNumberOfCharacters() {
            guard canContinue() else { return false }
            if characterCount <= 0 {
                return true
            }
            let current = readSelectedRange()
            guard canContinue() else { return false }
            if let current,
               current.location == characterCount,
               current.length == 0 {
                return true
            }
            let settable = isSelectedRangeSettable()
            guard canContinue() else { return false }
            if settable,
               writeSelectedRange(CFRange(location: characterCount, length: 0)) {
                guard canContinue() else { return false }
                if let updated = readSelectedRange() {
                    guard canContinue() else { return false }
                    if let verifiedCount = readNumberOfCharacters() {
                        guard canContinue() else { return false }
                        if updated.location == verifiedCount, updated.length == 0 {
                            return true
                        }
                    }
                }
            }
        }
        guard canContinue() else { return false }
        let sent = postMoveToEndKey()
        if sent { pause() }
        return sent
    }

    static func axElement(_ element: AXUIElement, attribute: String) -> AXUIElement? {
        guard let value = axAttribute(element, attribute: attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // Core Foundation downcasts require as!; the type ID is checked above.
        return (value as! AXUIElement)
    }

    static func axElements(_ element: AXUIElement, attribute: String) -> [AXUIElement] {
        guard let values = axAttribute(element, attribute: attribute) as? [CFTypeRef] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
    }

    static func axFrame(_ element: AXUIElement) -> CGRect? {
        accessibilityFrame(read: { axAttribute(element, attribute: $0) })
    }

    static func accessibilityFrame(read: (String) -> Any?) -> CGRect? {
        guard let positionValue = read(kAXPositionAttribute),
              let sizeValue = read(kAXSizeAttribute),
              CFGetTypeID(positionValue as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue as CFTypeRef) == AXValueGetTypeID()
        else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func axSemanticText(_ element: AXUIElement) -> String {
        [
            axString(element, attribute: kAXIdentifierAttribute),
            axString(element, attribute: kAXTitleAttribute),
            axString(element, attribute: kAXDescriptionAttribute),
            axString(element, attribute: kAXHelpAttribute),
            axString(element, attribute: kAXPlaceholderValueAttribute),
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }
}
