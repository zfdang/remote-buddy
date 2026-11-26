import AppKit
import AVFoundation
import Combine
import CoreAudio
import CoreBluetooth
import Foundation

struct RemoteButtonObservation: Equatable {
    let profileID: UUID?
    let buttons: Set<RemoteButton>
    let origin: HIDReportOrigin

    init(profileID: UUID?, buttons: Set<RemoteButton>, origin: HIDReportOrigin = .iohid) {
        self.profileID = profileID
        self.buttons = buttons
        self.origin = origin
    }
}

@MainActor
final class BridgeAppModel: ObservableObject, BluetoothRemoteBridgeDelegate {
    static let longRecordingOpenTimeout: TimeInterval = 5
    static let longRecordingCloseTimeout: TimeInterval = 2
    static let rc003VoiceExtensionOpenTimeout: TimeInterval = 5
    static let rc003VoiceExtensionInterval: TimeInterval = 8
    static let rc003VoiceExtensionMaximumDuration: TimeInterval = 120

    let connections = BluetoothConnectionRegistry()
    let voiceSession = VoiceSessionRuntime()
    let audio: AudioRuntime

    let settings: AppSettings
    let commonPhraseStore: CommonPhraseStore
    lazy var commonPhrases = CommonPhraseController(store: commonPhraseStore)
    let loginItemService: LoginItemService

    var applicationIntegrationStatusGeneration: UInt64 = 0
    var applicationIntegrationStatusExpiry: ScheduledOperation?
    var scheduleApplicationIntegrationStatus: OperationScheduler = ScheduledOperation.mainQueue
    @Published var applicationIntegrationStatus: ApplicationIntegrationPreparationState?
    @Published var connectionStatus = LocalizedMessage("bluetooth.status.initializing")
    @Published var hidStatus = LocalizedMessage("button_mapping.status.disabled")
    @Published var hidFilterFailureState: HIDFilterFailureState = .none
    @Published var runtimePermissionIssue: RuntimePermissionIssue?
    @Published var runtimePermissionIssueUpdatedAt: Date?
    @Published var runtimePermissionDiagnosisTrigger: String?
    var lastLoggedRuntimePermissionIssueKey: String?
    @Published var audioStatus = LocalizedMessage("audio.output.none_selected")
    @Published var buddyMicrophoneStatus = LocalizedMessage("audio.compatibility.checking")
    @Published var isStreaming = false
    @Published var isConnected = false
    @Published var isVoiceTriggerEnabled = false
    @Published var activeRemoteButtons = Set<RemoteButton>()
    @Published var lastRemoteButtonPress: RemoteButton?
    @Published var lastObservedRemoteButtonReport: RemoteButtonObservation?
    @Published var connectedRemoteProfileIDs = Set<UUID>()
    @Published var remoteBatteryLevels: [UUID: Int] = [:]
    @Published var remotePowerStates: [UUID: RemotePowerState] = [:]
    var pendingRemoteBatteryLevels: [UUID: Int] = [:]
    var pendingRemotePowerStates: [UUID: RemotePowerState] = [:]
    var pendingRemoteModels: [UUID: RemoteModel] = [:]
    @Published var remoteSystemDeviceNames: [UUID: String] = [:]
    @Published var remoteDeviceInformation: [UUID: RemoteDeviceInformation] = [:]
    @Published var audioDevices: [AudioDeviceInfo] = []
    @Published var isAudioOutputReady = false {
        didSet { if isAudioOutputReady { isAudioOutputVerified = true } }
    }
    /// The last configuration of the selected output succeeded. Idle release stops
    /// the engine but keeps this result; a failed configuration or stop clears it.
    @Published var isAudioOutputVerified = false
    @Published var hasReceivedCurrentVoiceSamples = false
    @Published var activeVoiceSource: RemoteInputSource?
    @Published var voiceShortcutStatus = LocalizedMessage("voice_button.status.preparing")
    @Published var voiceKeyCompatibilityWarning: VoiceKeyCompatibilityWarning?
    @Published var bluetoothLoggingProfileStatus: BluetoothLoggingProfileStatus = .unknown
    @Published var btleServerLogRedactedObserved = false
    var btleServerReportLogSource: BTLEServerReportLogSource?
    var btleServerReportLogGeneration: UInt64 = 0
    var lastBTLEServerLogRedactedAt: TimeInterval = 0
    var consecutiveUnattributedBTLEServerLogRedactions = 0
    var lastUnattributedBTLEServerLogRedactionAt: TimeInterval = 0
    var lastUnattributedBTLEServerLogRedactionReportID: UInt32?
    struct VoiceToolUnavailablePrompt: Equatable {
        enum Reason: Equatable {
            case unavailable
            case applicationUnavailable
            case switchFailed
        }

        let tool: OnboardingVoiceTool
        let reason: Reason
    }

    @Published var unavailableVoiceToolPrompt: VoiceToolUnavailablePrompt?
    @Published var requestedSettingsSection: SettingsSection?

    func isOnboardingControlSourceConnected(_ source: OnboardingControlSource) -> Bool {
        switch source {
        case .xiaomiRemote:
            return connectedRemoteProfileIDs.contains { profileID in
                guard let model = settings.remoteDeviceProfiles.first(where: {
                    $0.id == profileID
                })?.model else { return false }
                return !model.usesPrivateAdapter && !model.isATVVRemote
            }
        case .t1Remote:
            return connectedRemoteProfileIDs.contains { id in
                settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model.isT1Remote == true
            }
        case .siriRemote:
            return false
        case .chromecastRemote:
            return connectedRemoteProfileIDs.contains { id in
                settings.remoteDeviceProfiles.first(where: { $0.id == id })?.model.isChromecastRemote == true
            }
        case .unselected:
            return false
        }
    }

    var activePhysicalVoiceControlSource: OnboardingControlSource? {
        if voiceSession.isActive {
            let profile = voiceSession.activeDeviceIdentifier.flatMap { settings.profileID(forBluetoothIdentifier: $0) }
                .flatMap { id in settings.remoteDeviceProfiles.first { $0.id == id } }
            if profile?.model.isChromecastRemote == true {
                return .chromecastRemote
            }
            if profile?.model.isT1Remote == true {
                return .t1Remote
            }
            return .xiaomiRemote
        }
        return nil
    }

    let voiceFunctionMapper: RemoteHIDKeyMapper
    lazy var applicationIntegrationController = ApplicationIntegrationController(settings: settings,
        onStateChange: { [weak self] state in
            self?.recordApplicationIntegrationStatus(state)
        })
    lazy var preferredInputSourceMonitor = PreferredInputSourceMonitor(
        voiceTool: { [weak self] in
            self?.settings.onboardingVoiceTool ?? .unselected
        },
        bypassInputSourceSwitching: { [weak self] in
            self?.settings.bypassInputSourceSwitching ?? false
        },
        isInputSourceAvailable: { [weak self] tool in
            self?.voiceToolAvailabilityChecker(tool) == .available
        },
        onSourcePreparationFailure: { [weak self] tool, result in
            self?.handleInputSourcePreparationFailure(for: tool, result: result)
        }
    )

    private var lastUnavailableVoiceToolPrompt: (tool: OnboardingVoiceTool, uptime: TimeInterval)?
    var voiceToolAvailabilityChecker: (OnboardingVoiceTool) -> OnboardingVoiceToolAvailability = {
        OnboardingInputSourceSwitcher.integrationAvailability(for: $0)
    }

    func ensureVoiceToolApplicationAvailable(
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        let tool = settings.onboardingVoiceTool
        guard tool.applicationBundleIdentifier != nil else { return true }
        guard voiceToolAvailabilityChecker(tool) == .notInstalled else { return true }
        presentUnavailableVoiceToolPromptIfNeeded(
            for: tool,
            reason: .applicationUnavailable,
            now: now
        )
        AppLogger.shared.write("VOICE KEY rejected reason=voice_tool_not_installed tool=\(tool.rawValue)")
        return false
    }

    func handleInputSourcePreparationFailure(
        for tool: OnboardingVoiceTool,
        result: OnboardingInputSourceSwitchResult,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let reason: VoiceToolUnavailablePrompt.Reason
        switch result {
        case .unavailable:
            reason = .unavailable
        case .failed:
            reason = .switchFailed
        case .selected, .notSelected, .notApplicable:
            return
        }
        presentUnavailableVoiceToolPromptIfNeeded(for: tool, reason: reason, now: now)
    }

    func presentUnavailableVoiceToolPromptIfNeeded(
        for tool: OnboardingVoiceTool,
        reason: VoiceToolUnavailablePrompt.Reason = .unavailable,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        // Throttle repeats per tool (even across reason changes) so key presses stay quiet.
        if let last = lastUnavailableVoiceToolPrompt,
           last.tool == tool,
           now - last.uptime < 10 {
            return
        }
        lastUnavailableVoiceToolPrompt = (tool, now)
        unavailableVoiceToolPrompt = VoiceToolUnavailablePrompt(tool: tool, reason: reason)
    }
    lazy var voiceInputDestinationCoordinator = VoiceInputDestinationCoordinator(
        onStateChange: { [weak self] state in
            self?.handleVoiceInputDestinationState(state)
        }
    )
    lazy var voiceTapTrigger = VoiceTapTrigger(selectedMode: { [settings] in settings.effectiveVoiceKeyMode })
    lazy var voiceFnTapSession = makeVoiceFnTapSession()
    private var voiceToolCancellable: AnyCancellable?
    private var applicationIntegrationCancellable: AnyCancellable?
    private var remoteDiscoverySettingsCancellable: AnyCancellable?
    var voiceKeyLatch = VoiceKeyLatch()
    var voiceKeyReleaseRetry: ScheduledOperation?
    var voiceKeyReleaseRetryGeneration: UInt64 = 0
    var scheduleVoiceKeyReleaseRetry: OperationScheduler = ScheduledOperation.mainQueue
    var voiceKeyStateSetter: ((VoiceKeyMode, Bool) -> Bool)?
    var heldVoiceKeyMode: VoiceKeyMode?
    var pendingVoiceKeyMode: VoiceKeyMode?
    // Main-queue state; only input-source waits can pump/reenter that queue.
    var voiceKeyActivationInProgress = false
    var voiceKeyActivationGeneration: UInt64 = 0
    var pendingVoiceKeyActivationOwner: VoiceKeyLatch.Owner?
    var pendingVoiceKeyActivationCompletion: ((Bool) -> Void)?
    var pendingVoiceToolMappingRefresh = false
    weak var longRecordingBridge: BluetoothRemoteBridge?
    var longRecordingRequested = false
    var longRecordingGeneration: UInt64 = 0
    var longRecordingOpenTimer: DispatchSourceTimer?
    var longRecordingCloseTimer: DispatchSourceTimer?
    let rc003VoiceExtensionTestEnabled: Bool
    weak var rc003VoiceExtensionBridge: BluetoothRemoteBridge?
    var rc003VoiceExtensionActive = false
    var rc003VoiceExtensionAwaitingReopen = false
    var rc003VoiceExtensionGeneration: UInt64 = 0
    var rc003VoiceExtensionDidReceiveAudio = false
    var rc003VoiceExtensionTimer: DispatchSourceTimer?
    var rc003VoiceExtensionOpenTimer: DispatchSourceTimer?
    var rc003VoiceExtensionDeadlineTimer: DispatchSourceTimer?
    var g9n9nSmartToggle = G9N9NSmartToggleState()
    weak var g9n9nSmartToggleBridge: BluetoothRemoteBridge?
    var g9n9nSmartToggleReopenTimer: DispatchSourceTimer?
    var g9n9nSmartToggleDeadlineTimer: DispatchSourceTimer?
    let hidEventSuppressor: KeyboardEventSuppressor
    let appSwitcherCoordinator = HIDAppSwitcherCoordinator()
    let permissionSnapshotProvider: () -> HIDPermissionSnapshot
    var onboardingWindowIsActive: () -> Bool
    var hidMonitoringInterrupted = false
    var hidMonitors: [String: HIDRemoteMonitor] = [:]
    var discoveryHIDMonitor: HIDRemoteMonitor?
    var selectedRemoteVoiceCapabilities: RemoteVoiceCapabilities {
        .resolve(model: settings.selectedRemoteProfile?.model, declared: [])
    }

    /// Google readiness derives from the shared public Bluetooth bridges.
    var connectedChromecastProfileIDs = Set<UUID>()
    struct HIDMonitorTargetConfiguration: Equatable {
        let profileID: UUID
        let fingerprint: String
        let model: RemoteModel
    }

    struct HIDMonitoringConfiguration: Equatable {
        let customMappingEnabled: Bool
        let backOnlyMode: Bool
        let powerKeySuppressed: Bool
        let waitForMatchingServices: Bool
        let allowedLocationIDs: Set<UInt32>?
        let targets: [HIDMonitorTargetConfiguration]
        let compatibleHIDIdentities: [RemoteHIDIdentity]
        let excludedDiscoveryFingerprints: Set<String>
        let monitoringPermissions: HIDMonitoringPermissions
    }

    var hidPowerKeySuppressed = false
    var hidAllowedLocationIDs: Set<UInt32>?
    var started = false
    var remoteDeviceNameRefreshOperation: UInt64 = 0
    var appliedHIDPermissionSnapshot: HIDPermissionSnapshot?
    var appliedHIDMonitoringConfiguration: HIDMonitoringConfiguration?
    var pendingHIDServiceMappingRefresh = false
    var hidServiceMappingRefreshGeneration: UInt64 = 0
    var scheduleHIDServiceMappingRefresh: OperationScheduler = ScheduledOperation.mainQueue
    private var terminationObserver: NSObjectProtocol?
    var completedUpdateHIDRecoveryWorkItem: DispatchWorkItem?
    var hidFilterRetryWorkItem: DispatchWorkItem?
    var hidFilterRetryToken: UUID?
    var hidMappingRecoveryWorkItem: DispatchWorkItem?
    var hidMappingRecoveryAttempt = 0
    var hidMappingRecoveryGeneration: UInt64 = 0
    lazy var audioHardwareListener = Self.makeAudioHardwareListener(owner: self)

    nonisolated private static func makeAudioHardwareListener(owner: BridgeAppModel) -> AudioObjectPropertyListenerBlock {
        { [weak owner] count, addresses in
            let properties = audioHardwarePropertyNames(count: count, addresses: addresses)
            DispatchQueue.main.async { [weak owner] in
                owner?.scheduleAudioRecovery(reason: "hardware_change", details: "properties=\(properties)")
            }
        }
    }

    var isRC003VoiceExtensionTestEnabled: Bool {
        rc003VoiceExtensionTestEnabled
    }

    init(
        settings: AppSettings? = nil,
        commonPhraseStore: CommonPhraseStore? = nil,
        initialAudioDevices: [AudioDeviceInfo] = [],
        audioRuntime: AudioRuntime? = nil,
        loginItemService: LoginItemService = LoginItemService(),
        voiceFunctionMapper: RemoteHIDKeyMapper? = nil,
        hidEventSuppressor: KeyboardEventSuppressor? = nil,
        permissionSnapshotProvider: @escaping () -> HIDPermissionSnapshot = { .current },
        onboardingWindowIsActive: @escaping () -> Bool = { true },
        rc003VoiceExtensionTestEnabled: Bool =
            ProcessInfo.processInfo.arguments.contains("--rc003-voice-extension-test") ||
            (Bundle.main.object(forInfoDictionaryKey: "RC003VoiceExtensionTestEnabled") as? Bool == true)
    ) {
        let settings = settings ?? AppSettings()
        self.settings = settings
        self.commonPhraseStore = commonPhraseStore ?? CommonPhraseStore()
        self.audio = audioRuntime ?? AudioRuntime()
        self.voiceFunctionMapper = voiceFunctionMapper ?? RemoteHIDKeyMapper()
        self.hidEventSuppressor = hidEventSuppressor ?? KeyboardEventSuppressor()
        self.permissionSnapshotProvider = permissionSnapshotProvider
        self.onboardingWindowIsActive = onboardingWindowIsActive

        self.loginItemService = loginItemService
        self.rc003VoiceExtensionTestEnabled = rc003VoiceExtensionTestEnabled
        commonPhrases.onWillOpen = { [weak self] in self?.cancelPendingCommonPhraseButtonActions() }
        audioDevices = initialAudioDevices
        self.hidEventSuppressor.onSystemDisabled = { [weak self] in
            // Stop mapping as well: an unseized remote must not inject actions without filtering.
            guard let self else { return }
            self.hidMonitoringInterrupted = true
            self.hidFilterFailureState = .systemDisabled
            self.stopHIDMonitors()
            let permissions = self.permissionSnapshotProvider()
            self.appliedHIDPermissionSnapshot = permissions
            self.hidStatus = LocalizedMessage(
                !permissions.inputMonitoringGranted ? HIDStatusKeys.inputMonitoringRequired :
                    (!permissions.accessibilityGranted ? "button_mapping.permission.accessibility_required" :
                        HIDStatusKeys.interrupted)
            )
            self.refreshRuntimePermissionDiagnosis(trigger: "hid_filter_disabled")
            self.scheduleHIDFilterRetry()
        }
        voiceToolCancellable = settings.$onboardingVoiceTool
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.voiceToolDidChange()
            }
        applicationIntegrationCancellable = settings.$enabledApplicationIntegrations
            .removeDuplicates().dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applicationIntegrationController.cancelPending()
                self?.clearApplicationIntegrationStatus()
                self?.voiceToolDidChange()
            }
        remoteDiscoverySettingsCancellable = Publishers.CombineLatest3(
            settings.$onboardingStep, settings.$onboardingCompletedVersion, settings.$remoteDeviceProfiles
        )
            // Published values arrive before the property is committed. Synchronize
            // on the next run-loop turn and let the single demand predicate decide.
            .dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.synchronizeBluetoothDiscovery() }
        audio.output.onConfigurationChange = { @Sendable [weak self] in
            DispatchQueue.main.async { [weak self] in self?.scheduleAudioRecovery(reason: "engine_configuration_change") }
        }

    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        applicationIntegrationController.start()
        startAudioSubsystem()
        applyHIDSettings()
        refreshRemoteDeviceNames(reason: .startup)
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        AppLogger.shared.write(
            "APP START version=\(version) rc003_test=\(rc003VoiceExtensionTestEnabled)"
        )
    }

    isolated deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        cancelAllScheduledWork(reason: "deinit")
    }

    func cancelAllScheduledWork(reason: String = "cancelled") {
        cancelHIDMappingRecovery(reason: reason)
        completedUpdateHIDRecoveryWorkItem?.cancel()
        completedUpdateHIDRecoveryWorkItem = nil
        cancelHIDFilterRetry()
        cancelLongRecordingTimers()
        rc003VoiceExtensionTimer?.cancel()
        rc003VoiceExtensionTimer = nil
        rc003VoiceExtensionOpenTimer?.cancel()
        rc003VoiceExtensionOpenTimer = nil
        rc003VoiceExtensionDeadlineTimer?.cancel()
        rc003VoiceExtensionDeadlineTimer = nil
        cancelG9N9NSmartToggleTimers()
        applicationIntegrationStatusExpiry?.cancel()
        applicationIntegrationStatusExpiry = nil
        voiceKeyReleaseRetry?.cancel()
        voiceKeyReleaseRetry = nil
    }

    private(set) var isTerminating = false

    func setG9N9NInputMode(_ mode: G9N9NInputMode, for profileID: UUID? = nil) {
        guard !settings.isOnboardingComplete,
              settings.onboardingPurpose != .integration,
              let targetID = profileID ?? settings.selectedRemoteProfileID,
              settings.remoteDeviceProfiles.contains(where: { $0.id == targetID && $0.model.isChromecastRemote })
        else { return }
        settings.setG9N9NInputMode(mode, for: targetID)
        for monitor in Array(hidMonitors.values) + (discoveryHIDMonitor.map { [$0] } ?? [])
        where monitor.profileID == nil || monitor.profileID == targetID {
            monitor.clearTransientInputState(emitEmptyActiveButtons: false)
        }
        synchronizeBTLEServerLogSource()
        AppLogger.shared.write("REMOTE HID g9n9n_mode=\(mode.rawValue) profile=\(targetID.uuidString)")
    }

    func prepareForTermination() {
        isTerminating = true
        commonPhrases.close(reason: "app_terminating")
    }

    func stop() {
        applicationIntegrationController.stop()
        clearApplicationIntegrationStatus()
        commonPhrases.close(reason: "app_stop")
        preferredInputSourceMonitor.stop()
        pendingHIDServiceMappingRefresh = false
        hidServiceMappingRefreshGeneration &+= 1
        guard started else {
            audio.invalidatePendingWork()
            return
        }
        started = false
        cancelAllScheduledWork(reason: "app_stop")
        audio.invalidatePendingWork()
        stopObservingAudioHardware()
        stopLongRecording(reason: "app_stop")
        finishRC003VoiceExtensionTest(reason: "app_stop")
        clearG9N9NSmartToggleState(reason: "app_stop")
        voiceInputDestinationCoordinator.shutdown()
        voiceFnTapSession.shutdown()
        connections.stopAll()
        voiceSession.end()
        releaseVoiceKeyIfNeeded()
        stopHIDMonitors()
        stopBTLEServerLogSource(clearingRedactedObservation: true)
        isAudioOutputReady = false
        isAudioOutputVerified = false
        // Stop is serialized with configurations on the engine queue. Enumeration no
        // longer allocates audio resources, so a delayed preparation-queue stop is unsafe.
        audio.output.stop()
        voiceFunctionMapper.restore()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
            self.terminationObserver = nil
        }
        AppLogger.shared.write("APP STOP")
    }

}
