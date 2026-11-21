import AppKit
import CoreGraphics
import Foundation

extension KeyboardInjector {
    static func open(
        _ application: PresetApplication,
        focusRequestID: UInt64,
        applicationURL: (String) -> URL?,
        applicationOpener: ApplicationOpener,
        applicationFocuser: @escaping ApplicationFocuser
    ) {
        guard let url = application.bundleIdentifiers.lazy.compactMap(applicationURL).first else {
            AppLogger.shared.write("APP ACTION unavailable bundle=\(application.bundleIdentifier)")
            return
        }

        applicationOpener(url, application) { processIdentifier, error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) " +
                        AppLogger.errorFields(error)
                )
            } else {
                AppLogger.shared.write("APP ACTION opened bundle=\(application.bundleIdentifier)")
                if application.focusStrategy != nil, let processIdentifier {
                    applicationFocuser(url, application, processIdentifier, focusRequestID)
                }
            }
        }
    }

    static func openApplication(
        at url: URL,
        application: PresetApplication,
        completion: @escaping @Sendable (pid_t?, Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
            completion(runningApplication?.processIdentifier, error)
        }
    }

    static func open(
        _ application: CustomApplicationProfile,
        focusRequestID: UInt64,
        applicationURL: (CustomApplicationProfile) -> URL?,
        applicationOpener: CustomApplicationOpener,
        applicationFocuser: @escaping CustomApplicationFocuser
    ) {
        guard let url = applicationURL(application) else {
            AppLogger.shared.write(
                "APP ACTION unavailable bundle=\(application.bundleIdentifier) custom=true"
            )
            return
        }

        applicationOpener(url, application) { processIdentifier, error in
            if let error {
                AppLogger.shared.write(
                    "APP ACTION failed bundle=\(application.bundleIdentifier) custom=true " +
                        AppLogger.errorFields(error)
                )
                return
            }
            AppLogger.shared.write(
                "APP ACTION opened bundle=\(application.bundleIdentifier) custom=true"
            )
            guard application.focusStrategy != .none, let processIdentifier else { return }
            applicationFocuser(application, processIdentifier, focusRequestID)
        }
    }

    static func resolveCustomApplicationURL(
        _ application: CustomApplicationProfile
    ) -> URL? {
        let savedURL = URL(fileURLWithPath: application.applicationPath)
        if Bundle(url: savedURL)?.bundleIdentifier == application.bundleIdentifier {
            return savedURL
        }
        return NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: application.bundleIdentifier
        )
    }

    static func openCustomApplication(
        at url: URL,
        application: CustomApplicationProfile,
        completion: @escaping @Sendable (pid_t?, Error?) -> Void
    ) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { runningApplication, error in
            completion(runningApplication?.processIdentifier, error)
        }
    }

    static func focusCustomApplication(
        application: CustomApplicationProfile,
        processIdentifier: pid_t,
        requestID: UInt64
    ) {
        scheduleCustomApplicationFocus(
            application: application,
            processIdentifier: processIdentifier,
            requestID: requestID,
            attempt: 0
        )
    }

    private static func scheduleCustomApplicationFocus(
        application: CustomApplicationProfile,
        processIdentifier: pid_t,
        requestID: UInt64,
        attempt: Int
    ) {
        let maximumAttempts = 8
        let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(0) : .milliseconds(200)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard focusRequests.isCurrent(requestID) else { return }
            if isAccessibilityTrusted, application.focusStrategy == .recordedAccessibility {
                announceManualAccessibility(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: application.bundleIdentifier,
                    attempt: attempt
                )
            }
            if applicationIsFrontmost(processIdentifier) {
                guard isAccessibilityTrusted else {
                    AppLogger.shared.write(
                        "APP FOCUS skipped bundle=\(application.bundleIdentifier) " +
                            "method=custom reason=not_trusted"
                    )
                    return
                }
                switch application.focusStrategy {
                case .none:
                    return
                case .keyboardShortcut:
                    if let shortcut = application.focusShortcut {
                        postKey(code: CGKeyCode(shortcut.keyCode), flags: shortcut.cgEventFlags)
                        AppLogger.shared.write(
                            "APP FOCUS succeeded bundle=\(application.bundleIdentifier) " +
                                "method=custom_shortcut"
                        )
                        return
                    }
                case .recordedAccessibility:
                    if let target = application.accessibilityTarget,
                       focusRecordedAccessibilityTarget(
                           target,
                           processIdentifier: processIdentifier
                       )
                    {
                        AppLogger.shared.write(
                            "APP FOCUS succeeded bundle=\(application.bundleIdentifier) " +
                                "method=custom_accessibility"
                        )
                        return
                    }
                }
            }

            let nextAttempt = attempt + 1
            if nextAttempt < maximumAttempts {
                scheduleCustomApplicationFocus(
                    application: application,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    attempt: nextAttempt
                )
            } else if focusRequests.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(application.bundleIdentifier) " +
                        "method=custom reason=target_not_focused"
                )
            }
        }
    }

    static func focusApplication(
        at applicationURL: URL,
        application: PresetApplication,
        processIdentifier: pid_t,
        requestID: UInt64
    ) {
        guard focusRequests.isCurrent(requestID), let strategy = application.focusStrategy else { return }

        switch strategy {
        case .accessibilityComposer:
            scheduleAccessibilityComposerFocus(
                bundleIdentifier: application.bundleIdentifier,
                processIdentifier: processIdentifier,
                requestID: requestID,
                requestGate: focusRequests,
                attempt: 0
            )
        case .cmuxSurfaceAPI:
            scheduleCmuxFocus(
                applicationURL: applicationURL,
                application: application,
                processIdentifier: processIdentifier,
                requestID: requestID,
                attempt: 0
            )
        }
    }

    static func testCustomApplicationInput(_ profile: CustomApplicationProfile, completion: @escaping (Bool) -> Void) {
        guard isAccessibilityTrusted, let target = profile.accessibilityTarget,
            let url = resolveCustomApplicationURL(profile) else { completion(false); return }
        nonisolated(unsafe) let completion = completion
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            guard error == nil, let application else { completion(false); return }
            focusQueue.asyncAfter(deadline: .now() + .milliseconds(500)) {
                let success = focusRecordedAccessibilityTarget(target, processIdentifier: application.processIdentifier)
                DispatchQueue.main.async { completion(success) }
            }
        }
    }

    @discardableResult
    static func focusFrontmostComposer(completion: @escaping @Sendable (Bool) -> Void) -> Bool {
        guard isAccessibilityTrusted,
              let application = NSWorkspace.shared.frontmostApplication
        else { return false }
        let requestID = frontmostFocusRequests.begin()
        if application.bundleIdentifier == PresetApplication.cmux.bundleIdentifier,
           let applicationURL = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: PresetApplication.cmux.bundleIdentifier
           ) {
            scheduleCmuxFocus(
                applicationURL: applicationURL,
                application: .cmux,
                processIdentifier: application.processIdentifier,
                requestID: requestID,
                attempt: 0,
                requestGate: frontmostFocusRequests,
                completion: completion
            )
            return true
        }
        scheduleAccessibilityComposerFocus(
            bundleIdentifier: application.bundleIdentifier ?? "unknown",
            processIdentifier: application.processIdentifier,
            requestID: requestID,
            requestGate: frontmostFocusRequests,
            attempt: 0,
            completion: completion
        )
        return true
    }

    private static func scheduleCmuxFocus(
        applicationURL: URL,
        application: PresetApplication,
        processIdentifier: pid_t,
        requestID: UInt64,
        attempt: Int,
        requestGate: ApplicationFocusRequestGate = focusRequests,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        let maximumAttempts = 4
        let delay: DispatchTimeInterval = attempt == 0 ? .milliseconds(100) : .milliseconds(200)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard requestGate.isCurrent(requestID) else { return }
            let nextAttempt = attempt + 1
            if !applicationIsFrontmost(processIdentifier) {
                if nextAttempt < maximumAttempts {
                    scheduleCmuxFocus(
                        applicationURL: applicationURL,
                        application: application,
                        processIdentifier: processIdentifier,
                        requestID: requestID,
                        attempt: nextAttempt,
                        requestGate: requestGate,
                        completion: completion
                    )
                } else {
                    completeComposerFocus(
                        false,
                        requestID: requestID,
                        requestGate: requestGate,
                        completion: completion
                    )
                }
                return
            }
            let canContinue = {
                requestGate.isCurrent(requestID) && applicationIsFrontmost(processIdentifier)
            }
            let focused = focusCmux(
                applicationURL: applicationURL,
                canContinue: canContinue,
                terminalFocuser: { _ in
                    guard isAccessibilityTrusted else {
                        AppLogger.shared.write(
                            "APP FOCUS failed bundle=\(application.bundleIdentifier) method=cmux_accessibility reason=not_trusted"
                        )
                        return false
                    }
                    return focusCmuxTerminal(
                        processIdentifier: processIdentifier,
                        keyPoster: { postKey(code: $0, flags: $1) }
                    )
                }
            )
            if focused {
                AppLogger.shared.write(
                    "APP FOCUS succeeded bundle=\(application.bundleIdentifier) method=cmux_api_accessibility"
                )
                completeComposerFocus(
                    true,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
                return
            }

            if nextAttempt < maximumAttempts {
                scheduleCmuxFocus(
                    applicationURL: applicationURL,
                    application: application,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    attempt: nextAttempt,
                    requestGate: requestGate,
                    completion: completion
                )
            } else if requestGate.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(application.bundleIdentifier) method=cmux_accessibility reason=terminal_not_focused"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
            }
        }
    }

    private static func scheduleAccessibilityComposerFocus(
        bundleIdentifier: String,
        processIdentifier: pid_t,
        requestID: UInt64,
        requestGate: ApplicationFocusRequestGate,
        attempt: Int,
        completion: (@Sendable (Bool) -> Void)? = nil
    ) {
        let delay: DispatchTimeInterval = attempt == 0
            ? .milliseconds(0)
            : .milliseconds(composerFocusRetryMilliseconds)
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard requestGate.isCurrent(requestID) else { return }

            if applicationIsFrontmost(processIdentifier), !isAccessibilityTrusted {
                AppLogger.shared.write(
                    "APP FOCUS skipped bundle=\(bundleIdentifier) method=accessibility reason=not_trusted"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
                return
            }
            if isAccessibilityTrusted {
                announceManualAccessibility(
                    processIdentifier: processIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    attempt: attempt
                )
            }
            if applicationIsFrontmost(processIdentifier), isAccessibilityTrusted {
                if focusComposer(
                    processIdentifier: processIdentifier,
                    emitDiagnostics: attempt == 0 || attempt + 1 == composerFocusMaximumAttempts
                ) {
                    AppLogger.shared.write(
                        "APP FOCUS succeeded bundle=\(bundleIdentifier) method=accessibility"
                    )
                    completeComposerFocus(
                        true,
                        requestID: requestID,
                        requestGate: requestGate,
                        completion: completion
                    )
                    return
                }
            }
            if attempt == 0,
               usesWeChatComposerFallback(bundleIdentifier: bundleIdentifier),
               applicationIsFrontmost(processIdentifier),
               focusWeChatComposer(processIdentifier: processIdentifier) {
                AppLogger.shared.write(
                    "APP FOCUS succeeded bundle=\(bundleIdentifier) method=wechat_window_click"
                )
                completeComposerFocus(
                    true,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
                return
            }

            let nextAttempt = attempt + 1
            if nextAttempt < composerFocusMaximumAttempts {
                scheduleAccessibilityComposerFocus(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifier: processIdentifier,
                    requestID: requestID,
                    requestGate: requestGate,
                    attempt: nextAttempt,
                    completion: completion
                )
            } else if requestGate.isCurrent(requestID) {
                AppLogger.shared.write(
                    "APP FOCUS failed bundle=\(bundleIdentifier) method=accessibility reason=composer_not_found"
                )
                completeComposerFocus(
                    false,
                    requestID: requestID,
                    requestGate: requestGate,
                    completion: completion
                )
            }
        }
    }

    private static func completeComposerFocus(
        _ focused: Bool,
        requestID: UInt64,
        requestGate: ApplicationFocusRequestGate,
        completion: (@Sendable (Bool) -> Void)?
    ) {
        guard let completion else { return }
        DispatchQueue.main.async {
            guard requestGate.isCurrent(requestID) else { return }
            completion(focused)
        }
    }
}
