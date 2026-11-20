import AppKit
import Carbon
import Foundation

enum OnboardingInputSourceSwitchResult: String, Equatable {
    case notApplicable
    case selected
    case notSelected = "not_selected"
    case unavailable
    case failed
}

enum OnboardingSystemFunctionKeyUsage: Equatable {
    case available
    case assigned
    case unknown

    static var current: Self {
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox"),
              let value = defaults.object(forKey: "AppleFnUsageType") as? NSNumber
        else {
            return .unknown
        }
        return value.intValue == 0 ? .available : .assigned
    }
}

enum OnboardingInputSourceSwitcher {
    static func validApplicationURL(
        forBundleIdentifier bundleIdentifier: String,
        lookup: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        guard let url = lookup(bundleIdentifier),
              !url.pathComponents.contains(".Trash"),
              fileExists(url.path) else {
            return nil
        }
        return url
    }

    static func applicationURL(for voiceTool: OnboardingVoiceTool) -> URL? {
        guard let bundleIdentifier = voiceTool.applicationBundleIdentifier else {
            return nil
        }
        return validApplicationURL(forBundleIdentifier: bundleIdentifier)
    }

    static func runtimeState(
        for voiceTool: OnboardingVoiceTool
    ) -> OnboardingVoiceToolRuntimeState {
        guard OnboardingVoiceToolRuntimePolicy.requiresRunningApplication(for: voiceTool) else {
            return .notApplicable
        }
        guard let applicationURL = applicationURL(for: voiceTool) else {
            return .unknown
        }

        let bundleIdentifier = Bundle(url: applicationURL)?.bundleIdentifier
        let isRunning = NSWorkspace.shared.runningApplications.contains { application in
            if let bundleIdentifier,
               application.bundleIdentifier == bundleIdentifier {
                return true
            }
            return application.bundleURL?.standardizedFileURL == applicationURL.standardizedFileURL
        }
        return isRunning ? .running : .notRunning
    }

    static func selectionState(
        for voiceTool: OnboardingVoiceTool
    ) -> OnboardingInputSourceSwitchResult {
        guard let inputSourceID = voiceTool.preferredInputSourceID else {
            return .notApplicable
        }
        guard inputSource(withID: inputSourceID, includeAllInstalled: true) != nil else {
            return .unavailable
        }
        return isSelected(voiceTool) ? .selected : .notSelected
    }

    @discardableResult
    static func launchApplication(
        for voiceTool: OnboardingVoiceTool,
        activates: Bool,
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard let applicationURL = applicationURL(for: voiceTool) else {
            completion?(false)
            return false
        }
        nonisolated(unsafe) let completion = completion
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { app, error in
            completion?(app != nil && error == nil)
        }
        return true
    }

    static func availability(
        for voiceTool: OnboardingVoiceTool
    ) -> OnboardingVoiceToolAvailability {
        let profile = VoiceToolAdapterProfile.profile(for: voiceTool)
        if let inputSourceID = voiceTool.preferredInputSourceID {
            return inputSource(withID: inputSourceID, includeAllInstalled: true) == nil
                ? .notInstalled
                : .available
        }

        if let bundleIdentifier = voiceTool.applicationBundleIdentifier {
            return validApplicationURL(forBundleIdentifier: bundleIdentifier) == nil
                ? .notInstalled
                : .available
        }

        return profile.installationProbe == .none ? .unknown : .available
    }

    /// Checks whether the configured voice tool is ready for live voice sessions (including
    /// being enabled in Keyboard Input Sources for input-method tools such as Doubao or WeType).
    static func integrationAvailability(
        for voiceTool: OnboardingVoiceTool,
        hasInputSource: (_ id: String, _ includeAllInstalled: Bool) -> Bool = { id, includeAllInstalled in
            inputSource(withID: id, includeAllInstalled: includeAllInstalled) != nil
        },
        hasApplication: (_ bundleIdentifier: String) -> Bool = { bundleIdentifier in
            validApplicationURL(forBundleIdentifier: bundleIdentifier) != nil
        }
    ) -> OnboardingVoiceToolAvailability {
        if let targetID = voiceTool.preferredInputSourceID {
            return hasInputSource(targetID, false) ? .available : .notInstalled
        }
        if let bundleIdentifier = voiceTool.applicationBundleIdentifier {
            return hasApplication(bundleIdentifier) ? .available : .notInstalled
        }
        return availability(for: voiceTool)
    }

    static func selectIfNeeded(
        _ voiceTool: OnboardingVoiceTool
    ) -> OnboardingInputSourceSwitchResult {
        guard voiceTool.preferredInputSourceID != nil else { return .notApplicable }
        return isSelected(voiceTool) ? .selected : select(voiceTool)
    }

    static func isInputSourceAvailable(
        for voiceTool: OnboardingVoiceTool,
        includeAllInstalled: Bool = false
    ) -> Bool {
        guard let targetID = voiceTool.preferredInputSourceID else { return true }
        return inputSource(withID: targetID, includeAllInstalled: includeAllInstalled) != nil
    }

    static func prepareForVoiceSession(
        _ voiceTool: OnboardingVoiceTool
    ) -> OnboardingInputSourceSwitchResult {
        guard let targetID = voiceTool.preferredInputSourceID else { return .notApplicable }
        guard !isSelected(voiceTool) else { return .selected }
        guard let source = inputSource(withID: targetID, includeAllInstalled: false) else {
            return .unavailable
        }

        return TISSelectInputSource(source) == noErr ? .selected : .failed
    }

    static func currentInputSourceID() -> String? {
        currentInputSourceID(copyCurrent: { TISCopyCurrentKeyboardInputSource() })
    }

    static func currentInputSourceID(copyCurrent: () -> Unmanaged<TISInputSource>?) -> String? {
        guard let reference = copyCurrent() else { return nil }
        let current = reference.takeRetainedValue()
        return stringProperty(kTISPropertyInputSourceID, from: current)
    }

    static func selectEnabledInputSource(
        withID targetID: String
    ) -> OnboardingInputSourceSwitchResult {
        guard let source = inputSource(withID: targetID, includeAllInstalled: false) else {
            return .unavailable
        }
        return TISSelectInputSource(source) == noErr ? .selected : .failed
    }

    static func select(_ voiceTool: OnboardingVoiceTool) -> OnboardingInputSourceSwitchResult {
        guard let targetID = voiceTool.preferredInputSourceID else { return .notApplicable }
        guard let source = inputSource(withID: targetID, includeAllInstalled: true) else {
            return .unavailable
        }

        let enableStatus = TISEnableInputSource(source)
        guard enableStatus == noErr else { return .failed }

        return TISSelectInputSource(source) == noErr ? .selected : .failed
    }

    static func isSelected(_ voiceTool: OnboardingVoiceTool) -> Bool {
        guard let targetID = voiceTool.preferredInputSourceID else { return false }
        return currentInputSourceID() == targetID
    }

    private static func inputSource(
        withID targetID: String,
        includeAllInstalled: Bool
    ) -> TISInputSource? {
        inputSource(withID: targetID, createList: { TISCreateInputSourceList(nil, includeAllInstalled) })
    }

    static func inputSource(withID targetID: String, createList: () -> Unmanaged<CFArray>?) -> TISInputSource? {
        guard let reference = createList() else { return nil }
        let sources = reference.takeRetainedValue() as NSArray
        for sourceObject in sources {
            let reference = sourceObject as CFTypeRef
            guard CFGetTypeID(reference) == TISInputSourceGetTypeID() else { continue }
            let source = unsafeBitCast(reference, to: TISInputSource.self)
            if stringProperty(kTISPropertyInputSourceID, from: source) == targetID {
                return source
            }
        }
        return nil
    }

    private static func stringProperty(
        _ key: CFString,
        from source: TISInputSource
    ) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFTypeRef>
            .fromOpaque(pointer)
            .takeUnretainedValue() as? String
    }
}
