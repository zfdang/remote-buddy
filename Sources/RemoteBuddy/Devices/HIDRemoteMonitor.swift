import AppKit
import CryptoKit
import Foundation
import IOKit.hid
import IOKit.hidsystem

final class HIDMonitorContext {
    weak var monitor: HIDRemoteMonitor?
    init(_ monitor: HIDRemoteMonitor) {
        self.monitor = monitor
    }
}

private func hidDeviceMatched(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    nonisolated(unsafe) let context = context
    nonisolated(unsafe) let device = device
    // IOHID callbacks are scheduled on CFRunLoopGetMain().
    MainActor.assumeIsolated {
        guard let context else { return }
        let holder = Unmanaged<HIDMonitorContext>.fromOpaque(context).takeUnretainedValue()
        guard let monitor = holder.monitor else { return }
        monitor.deviceDidMatch(result: result, device: device)
    }
}

private func hidDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    nonisolated(unsafe) let context = context
    nonisolated(unsafe) let device = device
    // IOHID callbacks are scheduled on CFRunLoopGetMain().
    MainActor.assumeIsolated {
        guard let context else { return }
        let holder = Unmanaged<HIDMonitorContext>.fromOpaque(context).takeUnretainedValue()
        guard let monitor = holder.monitor else { return }
        monitor.deviceDidRemove(device: device)
    }
}

private func processHIDReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex,
    timeStamp: UInt64,
    path: HIDReportCallbackPath
) {
    nonisolated(unsafe) let context = context
    nonisolated(unsafe) let sender = sender
    let data = reportLength > 0 ? Data(bytes: report, count: reportLength) : Data()
    // IOHID callbacks are scheduled on CFRunLoopGetMain().
    MainActor.assumeIsolated {
        guard let context else { return }
        let holder = Unmanaged<HIDMonitorContext>.fromOpaque(context).takeUnretainedValue()
        guard let monitor = holder.monitor else { return }
        guard result == kIOReturnSuccess else {
            monitor.reportCallbackRejected(
                reason: "io_error",
                result: result,
                reportLength: reportLength,
                path: path
            )
            return
        }
        guard let sender else {
            monitor.reportCallbackRejected(
                reason: "missing_sender",
                result: result,
                reportLength: reportLength,
                path: path
            )
            return
        }
        guard reportLength > 0 else {
            monitor.reportCallbackRejected(
                reason: "empty_report",
                result: result,
                reportLength: reportLength,
                path: path
            )
            return
        }
        let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
        monitor.handleReport(
            from: device,
            reportID: reportID,
            data: data,
            timestampNanoseconds: HIDReportClock.uptimeNanoseconds(fromMachTime: timeStamp),
            path: path
        )
    }
}

private func hidInputReportWithTimeStamp(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex,
    timeStamp: UInt64
) {
    processHIDReportCallback(
        context: context,
        result: result,
        sender: sender,
        reportID: reportID,
        report: report,
        reportLength: reportLength,
        timeStamp: timeStamp,
        path: .manager
    )
}

private func hidDeviceInputReportWithTimeStamp(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex,
    timeStamp: UInt64
) {
    processHIDReportCallback(
        context: context,
        result: result,
        sender: sender,
        reportID: reportID,
        report: report,
        reportLength: reportLength,
        timeStamp: timeStamp,
        path: .device
    )
}

enum HIDReportRoutingDecision: Equatable {
    case accepted(String)
    case rejected(String)
}

enum HIDDeviceMatchDecision: Equatable {
    case activate(String)
    case probe
    case rejected(String)
}

enum HIDReportOrigin: String, Equatable, Hashable {
    case iohid = "iohid"
    case btleServerLog = "btle_log"
    case simulated = "simulated"
}

@MainActor
final class HIDRemoteMonitor {
    struct ParsedHIDReport {
        let mappedUsages: Set<UInt16>
        let observedPassthroughUsages: Set<UInt16>

        var allObservedUsages: Set<UInt16> {
            mappedUsages.union(observedPassthroughUsages)
        }
    }

    struct CachedDeviceMetadata {
        let fingerprint: String?
        let identity: RemoteHIDIdentity?
        let locationID: UInt32?
        let reportDescriptor: Data?
    }

    let settings: AppSettings
    let allowsG9N9N: Bool
    let allowsT1Remote: Bool
    var currentReportIsGoogle = false
    /// Reports recovered from the BTLEServer log never reached macOS, so no native key event follows them.
    var currentReportOrigin: HIDReportOrigin = .iohid
    var btleLogActiveUsages = Set<UInt16>()
    var btleLogPendingGestureButtons = Set<RemoteButton>()
    var btleLogOwnsAppSwitcher = false
    var nativeGoogleIOHIDObserved = false
    var lastGoogleReportByOrigin: [HIDReportOrigin: (reportID: UInt32, usages: Set<UInt16>, time: TimeInterval)] = [:]
    var currentReportIsT1 = false
    var t1VoiceHoldActive = false

    var t1ReportUsageState = T1ReportUsageState()
    var t1PassthroughUsageState = T1ReportUsageState()
    var activeT1PassthroughUsages: Set<UInt16> = []
    var interceptedT1PassthroughUsages: Set<UInt16> = []
    var t1PassthroughExpiryTokens: [UInt16: UUID] = [:]
    var t1PassthroughExpiryTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    var t1PassthroughHardCeilingTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    var suppressedUntilReleasedT1PassthroughUsages: Set<UInt16> = []
    var suppressedT1PassthroughExpiryTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    var lastT1MouseHeader: Data?
    var lastT1MouseLogTime: TimeInterval = 0
    var currentReportDescriptor: Data?
    var googleIndexedReportsIncludeID = false
    var reportedModel: RemoteModel {
        if currentReportIsGoogle { return .chromecastVoiceRemote }
        if currentReportIsT1 { return .t1Remote }
        return .unknown
    }
    let eventSuppressor: KeyboardEventSuppressor
    let ownsEventSuppressor: Bool
    let scheduler: HIDRemoteScheduling
    let permissionPoll: HIDPermissionPoll
    let permissionSnapshot: () -> HIDPermissionSnapshot
    let nativeSuppressionAvailable: () -> Bool
    let runtimePermissions: () -> Bool
    let actionPerformer: (RemoteButton, ButtonTrigger, ConfiguredButtonAction) -> Bool
    let nativeKeyStatePoster: KeyboardInjector.KeyStatePoster
    let appSwitcherCoordinator: HIDAppSwitcherCoordinator
    let switcherOwnerToken = UUID()
    let frontmostBundleIdentifier: () -> String?
    let diagnosticLogger: (String) -> Void
    let karabinerElementsInstalled: () -> Bool
    let targetFingerprint: String?
    let excludedFingerprints: () -> Set<String>
    var allowedLocationIDs: Set<UInt32>?
    var manager: IOHIDManager?
    var callbackContext: HIDMonitorContext?
    var callbackOpaqueContext: Unmanaged<HIDMonitorContext>?
    struct DeviceReportRegistration {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let length: CFIndex
    }
    var deviceReportRegistrations: [DeviceReportRegistration] = []
    var deviceReportPointers = Set<UInt>()
    var reportDeduplicationCache = HIDReportDeduplicationCache()
    var pathHealth = HIDReportPathHealth()
    var usesDeviceReportCallback: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    var activeDevice: IOHIDDevice?
    var probedDevices: [IOHIDDevice] = []
    var cachedDeviceMetadata: [ObjectIdentifier: CachedDeviceMetadata] = [:]
    var deviceFingerprint: String?
    var profileID: UUID?
    var activeDeviceIsSeized = false
    var activeUsages = Set<UInt16>()
    var nativePassthroughUsages = Set<UInt16>()
    var directPassthroughUsages = Set<UInt16>()
    var suppressedUntilReleasedUsages = Set<UInt16>()
    var suppressedUsageExpiryTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    var usageExpiryTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    var usageHardCeilingTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    var usageExpiryTokens: [UInt16: UUID] = [:]
    var repeatTimers: [UInt16: HIDRemoteScheduledTask] = [:]
    var repeatTokens: [UInt16: UUID] = [:]
    struct CapturedApplicationScope: Equatable {
        let bundleIdentifier: String?
    }

    var nonRepeatablePressedButtons = Set<RemoteButton>()
    var nonRepeatableReleaseTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    var gestureRecognizer = RemoteButtonGestureRecognizer()
    var capturedApplicationScopes: [RemoteButton: CapturedApplicationScope] = [:]
    var doubleClickTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    var doubleClickTimerTokens: [RemoteButton: UUID] = [:]
    var longPressTimers: [RemoteButton: HIDRemoteScheduledTask] = [:]
    var longPressTimerTokens: [RemoteButton: UUID] = [:]
    var permissionPollSubscription: HIDPermissionPoll.Subscription?
    private(set) var status = LocalizedMessage("button_mapping.status.disabled")
    var onStatus: ((LocalizedMessage) -> Void)?
    var onActiveButtons: ((UUID?, Set<RemoteButton>) -> Void)?
    var onObservedButtonReport: ((UUID?, Set<RemoteButton>) -> Void)?
    var onButtonPressed: ((UUID?, String, RemoteButton) -> (profileID: UUID, shouldPerformAction: Bool)?)?
    var onPassthroughButtonObserved: ((UUID?, String, RemoteButton) -> UUID?)?
    var onRuntimeButton: ((UUID?, RemoteButton, RemoteButtonPhase) -> Bool)?
    var claimsRuntimeButton: ((UUID?, RemoteButton) -> Bool)?
    var onInputReset: ((UUID?) -> Void)?
    var onMonitoringInterrupted: (() -> Void)?
    var onCandidateAvailable: (() -> Void)?
    var onDeviceConnected: ((UUID?, String) -> Void)?
    private(set) var isWaitingForMatchingServices = false

    var isMonitoring: Bool { manager != nil }
    var onInternalAction: ((UUID?, ButtonAction) -> Void)?
    var onT1VoiceHoldChanged: ((UUID?, Bool) -> Void)?
    var onNativeGoogleIOHIDVerified: ((UUID?) -> Void)?
    var onboardingWindowIsActive: () -> Bool = { true }

    init(
        settings: AppSettings,
        allowsG9N9N: Bool = false,
        allowsT1Remote: Bool = false,
        profileID: UUID? = nil,
        targetFingerprint: String? = nil,
        excludedFingerprints: @escaping () -> Set<String> = { [] },
        eventSuppressor: KeyboardEventSuppressor = KeyboardEventSuppressor(),
        ownsEventSuppressor: Bool = true,
        scheduler: HIDRemoteScheduling = DispatchHIDRemoteScheduler(),
        permissionPoll: HIDPermissionPoll = .shared,
        permissionSnapshot: @escaping () -> HIDPermissionSnapshot = { .current },
        runtimePermissions: @escaping () -> Bool = {
            HIDRemoteMonitor.isInputMonitoringGranted && KeyboardInjector.isAccessibilityTrusted
        },
        nativeSuppressionAvailable: (() -> Bool)? = nil,
        actionPerformer: ((
            RemoteButton,
            ButtonTrigger,
            ConfiguredButtonAction
        ) -> Bool)? = nil,
        frontmostBundleIdentifier: @escaping () -> String? = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        },
        diagnosticLogger: @escaping (String) -> Void = AppLogger.shared.write,
        karabinerElementsInstalled: @escaping () -> Bool = {
            HIDRemoteMonitor.isKarabinerElementsInstalled()
        },
        appSwitcherKeyStatePoster: KeyboardInjector.KeyStatePoster? = nil,
        appSwitcherHardwareFlags: @escaping () -> CGEventFlags = KeyboardHardwareModifierPolicy.currentForAppSwitcher,
        appSwitcherOwnedKeyStatePoster: KeyboardInjector.AppSwitcherSession.OwnedKeyStatePoster? = nil,
        appSwitcherHUDVisible: @escaping () -> Bool? = { KeyboardInjector.isAppSwitcherHUDVisible() },
        appSwitcherCoordinator: HIDAppSwitcherCoordinator? = nil
    ) {
        self.settings = settings
        self.allowsG9N9N = allowsG9N9N
        self.allowsT1Remote = allowsT1Remote
        self.profileID = profileID
        self.targetFingerprint = targetFingerprint
        self.excludedFingerprints = excludedFingerprints
        self.eventSuppressor = eventSuppressor
        self.ownsEventSuppressor = ownsEventSuppressor
        self.scheduler = scheduler
        self.permissionPoll = permissionPoll
        self.permissionSnapshot = permissionSnapshot
        self.runtimePermissions = runtimePermissions
        self.nativeSuppressionAvailable = nativeSuppressionAvailable ?? { eventSuppressor.isRunning }
        self.nativeKeyStatePoster = appSwitcherKeyStatePoster ?? KeyboardInjector.postKeyState
        if let appSwitcherCoordinator {
            self.appSwitcherCoordinator = appSwitcherCoordinator
        } else {
            let sessionScheduler: OperationScheduler = { delay, action in
                nonisolated(unsafe) let task = scheduler.schedule(
                    afterMilliseconds: UInt64(max(0, (delay * 1_000).rounded())),
                    repeatingEveryMilliseconds: nil,
                    action
                )
                return ScheduledOperation { task.cancel() }
            }
            let session: KeyboardInjector.AppSwitcherSession
            if let appSwitcherOwnedKeyStatePoster {
                session = KeyboardInjector.AppSwitcherSession(
                    hardwareFlags: appSwitcherHardwareFlags,
                    keyStatePoster: appSwitcherOwnedKeyStatePoster,
                    scheduleRelease: sessionScheduler
                )
            } else if let appSwitcherKeyStatePoster {
                session = KeyboardInjector.AppSwitcherSession(
                    hardwareFlags: appSwitcherHardwareFlags,
                    keyStatePoster: { code, down, flags, _ in
                        appSwitcherKeyStatePoster(code, down, flags)
                    },
                    scheduleRelease: sessionScheduler
                )
            } else {
                session = KeyboardInjector.AppSwitcherSession(
                    hardwareFlags: appSwitcherHardwareFlags,
                    scheduleRelease: sessionScheduler
                )
            }
            self.appSwitcherCoordinator = HIDAppSwitcherCoordinator(
                session: session,
                scheduler: scheduler,
                frontmostBundleIdentifier: frontmostBundleIdentifier,
                switcherHUDVisible: appSwitcherHUDVisible,
                diagnosticLogger: diagnosticLogger
            )
        }
        self.actionPerformer = actionPerformer ?? { _, _, configured in
            KeyboardInjector.send(
                configured.action,
                shortcut: configured.shortcut,
                applicationProfile: settings.customApplicationProfile(
                    id: configured.applicationProfileID
                ),
                urlString: configured.urlString
            )
        }
        self.frontmostBundleIdentifier = frontmostBundleIdentifier
        self.diagnosticLogger = diagnosticLogger
        self.karabinerElementsInstalled = karabinerElementsInstalled
    }

    func assignProfileID(_ profileID: UUID) {
        self.profileID = profileID
    }

    nonisolated static var inputMonitoringAccess: IOHIDAccessType {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
    }

    nonisolated static var isInputMonitoringGranted: Bool {
        inputMonitoringAccess == kIOHIDAccessTypeGranted
    }

    @discardableResult
    nonisolated static func requestInputMonitoringAccess() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    func start(
        powerKeySuppressed: Bool,
        allowedLocationIDs: Set<UInt32>? = nil,
        waitForMatchingServices: Bool = false
    ) {
        stop()
        self.allowedLocationIDs = allowedLocationIDs
        let targetModel = settings.remoteDeviceProfiles.first { $0.id == profileID }?.model
        // An absent service is a normal reconnect state. Observe matching devices so
        // their arrival can reapply mappings, but never open or route unsafe input.
        let waitingForServices = waitForMatchingServices && !powerKeySuppressed &&
            targetFingerprint != nil && targetModel?.isChromecastRemote != true
        isWaitingForMatchingServices = waitingForServices
        let families = Self.monitorFamilies(targetModel: targetModel,
            powerKeySuppressed: powerKeySuppressed || waitingForServices, allowsGoogle: allowsG9N9N)
        let allowT1 = Self.monitorsT1Family(targetModel: targetModel,
            powerKeySuppressed: powerKeySuppressed || waitingForServices, allowsT1Remote: allowsT1Remote)
        let permissions = permissionSnapshot()
        let inputGranted = permissions.inputMonitoringGranted
        let accessibilityGranted = permissions.accessibilityGranted
        AppLogger.shared.write(
            "HID PERMISSIONS input=\(inputGranted) accessibility=\(accessibilityGranted) post_event=\(permissions.postEventAccessGranted)"
        )
        guard HIDPermissionGate.canMonitor(
            inputMonitoringGranted: inputGranted,
            accessibilityGranted: accessibilityGranted,
            powerKeySuppressed: families.xiaomi || families.google || allowT1
        ) else {
            if !inputGranted {
                updateStatus(LocalizedMessage("button_mapping.permission.input_monitoring_required"))
            } else if !accessibilityGranted {
                updateStatus(LocalizedMessage("button_mapping.permission.accessibility_required"))
            } else {
                updateStatus(LocalizedMessage("button_mapping.error.power_suppression_failed"))
                AppLogger.shared.write("HID START rejected power_suppressed=false")
            }
            return
        }

        let matches = Self.deviceMatchingCriteria(
            includeXiaomi: families.xiaomi,
            includeGoogle: families.google,
            includeT1: allowT1,
            additionalIdentities: settings.compatibleHIDIdentities(
                includeXiaomi: families.xiaomi,
                includeGoogle: families.google,
                includeT1: allowT1
            )
        )
        guard !matches.isEmpty else {
            updateStatus(LocalizedMessage("button_mapping.error.power_suppression_failed"))
            return
        }

        let suppressionReady = eventSuppressor.start()
        AppLogger.shared.write("HID FILTER ready=\(suppressionReady)")

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let holder = HIDMonitorContext(self)
        self.callbackContext = holder
        let unmanaged = Unmanaged.passRetained(holder)
        self.callbackOpaqueContext = unmanaged
        let context = unmanaged.toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, hidDeviceMatched, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, hidDeviceRemoved, context)
        IOHIDManagerRegisterInputReportWithTimeStampCallback(manager, hidInputReportWithTimeStamp, context)
        AppLogger.shared.write(
            "HID REPORT path=\(usesDeviceReportCallback ? "device+manager" : "manager")"
        )
        // Matching immediately enumerates already-connected devices. An unopened
        // manager does not forward callbacks registered after that enumeration
        // to existing devices, so install callbacks before setting the matches.
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        IOHIDManagerScheduleWithRunLoop(
            manager,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )

        // Scheduling/matching discovers devices without opening every interface.
        // Open only a selected/probed device, so its first open can request seizure.
        self.manager = manager
        startPermissionMonitor()
        updateStatus(LocalizedMessage("button_mapping.status.waiting_for_device"))
        AppLogger.shared.write("HID START mode=\(waitingForServices ? "waiting_for_services" : "adaptive")")
    }

    isolated deinit { stop() }

    func stop() {
        isWaitingForMatchingServices = false
        btleLogActiveUsages.removeAll()
        nativeGoogleIOHIDObserved = false
        lastGoogleReportByOrigin.removeAll()
        if ownsEventSuppressor { eventSuppressor.stop() }
        permissionPollSubscription?.cancel()
        permissionPollSubscription = nil
        if let manager {
            IOHIDManagerRegisterDeviceMatchingCallback(manager, nil, nil)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, nil, nil)
            IOHIDManagerRegisterInputReportCallback(manager, nil, nil)
            IOHIDManagerUnscheduleFromRunLoop(
                manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue
            )
        }
        unregisterAllDeviceReportCallbacks()
        callbackContext?.monitor = nil
        callbackContext = nil
        if let opaque = callbackOpaqueContext {
            opaque.release()
            callbackOpaqueContext = nil
        }
        resetInputState()
        reportDeduplicationCache = HIDReportDeduplicationCache()
        pathHealth = HIDReportPathHealth()
        let closingDeviceCount = probedDevices.count + (activeDevice == nil ? 0 : 1)
        let hasIOKitResources = manager != nil || closingDeviceCount > 0
        defer {
            if hasIOKitResources { diagnosticLogger("HID TEARDOWN phase=completed") }
        }
        if hasIOKitResources {
            diagnosticLogger("HID TEARDOWN phase=begin devices=\(closingDeviceCount) manager=\(manager != nil)")
        }
        probedDevices.forEach {
            IOHIDDeviceClose($0, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        probedDevices.removeAll()
        cachedDeviceMetadata.removeAll()
        if let activeDevice {
            IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.activeDevice = nil
            deviceFingerprint = nil
            activeDeviceIsSeized = false
        }
        guard let manager else { return }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
    }

    private func startPermissionMonitor() {
        permissionPollSubscription?.cancel()
        permissionPollSubscription = permissionPoll.subscribe { [weak self] permissionsGranted in
            guard let self, self.manager != nil else { return }
            if !permissionsGranted {
                self.releaseForRevokedPermissions()
            }
        }
    }

    func releaseForRevokedPermissions() {
        // This may be a shared tap. No monitor can safely filter input after revocation.
        eventSuppressor.stop()
        diagnosticLogger("HID TEARDOWN reason=permission_revoked filter=stopped")
        stop()
        onMonitoringInterrupted?()
        updateStatus(LocalizedMessage("button_mapping.permission.system_expired"))
        AppLogger.shared.write("HID RELEASED permission_revoked")
    }

    nonisolated static func fingerprint(for device: IOHIDDevice) -> String? {
        let keys = ["PhysicalDeviceUniqueID", kIOHIDSerialNumberKey, "DeviceAddress"]
        for key in keys {
            guard let value = IOHIDDeviceGetProperty(device, key as CFString) as? String,
                  !value.isEmpty
            else { continue }
            return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        guard let location = IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber else {
            return nil
        }
        return SHA256.hash(data: Data("location:\(location.uint64Value)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func locationID(for device: IOHIDDevice) -> UInt32? {
        (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint32Value
    }

    nonisolated static func isLocationAllowed(
        locationID: UInt32?,
        allowedLocationIDs: Set<UInt32>?
    ) -> Bool {
        guard let allowedLocationIDs else { return true }
        guard let locationID else { return false }
        return allowedLocationIDs.contains(locationID)
    }

    private static func deviceReportPointer(_ device: IOHIDDevice) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque())
    }

    func registerDeviceReportCallbackIfNeeded(_ device: IOHIDDevice) {
        guard usesDeviceReportCallback, let context = callbackOpaqueContext?.toOpaque() else { return }
        let pointer = Self.deviceReportPointer(device)
        guard !deviceReportPointers.contains(pointer) else { return }
        deviceReportPointers.insert(pointer)
        let maxLength = (IOHIDDeviceGetProperty(
            device,
            kIOHIDMaxInputReportSizeKey as CFString
        ) as? NSNumber)?.intValue ?? 4_096
        let length = CFIndex(max(64, maxLength))
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(length))
        buffer.initialize(repeating: 0, count: Int(length))
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            device,
            buffer,
            length,
            hidDeviceInputReportWithTimeStamp,
            context
        )
        IOHIDDeviceScheduleWithRunLoop(
            device,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        deviceReportRegistrations.append(
            DeviceReportRegistration(device: device, buffer: buffer, length: length)
        )
        diagnosticLogger("HID REPORT device_callback registered path=device")
    }

    @discardableResult
    func unregisterDeviceReportCallback(_ device: IOHIDDevice) -> Bool {
        let pointer = Self.deviceReportPointer(device)
        guard let index = deviceReportRegistrations.firstIndex(where: {
            Self.deviceReportPointer($0.device) == pointer
        }) else {
            return false
        }
        let registration = deviceReportRegistrations.remove(at: index)
        deviceReportPointers.remove(pointer)
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(
            registration.device,
            registration.buffer,
            registration.length,
            nil,
            nil
        )
        IOHIDDeviceUnscheduleFromRunLoop(
            registration.device,
            CFRunLoopGetMain(),
            CFRunLoopMode.commonModes.rawValue
        )
        registration.buffer.deinitialize(count: Int(registration.length))
        registration.buffer.deallocate()
        return true
    }

    private func unregisterAllDeviceReportCallbacks() {
        let registrations = deviceReportRegistrations
        deviceReportRegistrations.removeAll()
        deviceReportPointers.removeAll()
        for registration in registrations {
            IOHIDDeviceRegisterInputReportWithTimeStampCallback(
                registration.device,
                registration.buffer,
                registration.length,
                nil,
                nil
            )
            IOHIDDeviceUnscheduleFromRunLoop(
                registration.device,
                CFRunLoopGetMain(),
                CFRunLoopMode.commonModes.rawValue
            )
            registration.buffer.deinitialize(count: Int(registration.length))
            registration.buffer.deallocate()
        }
    }

    func recordPathReport(
        path: HIDReportCallbackPath,
        duplicate: Bool,
        nowNanoseconds: UInt64
    ) {
        guard usesDeviceReportCallback else { return }
        let events = pathHealth.record(
            path: path,
            duplicate: duplicate,
            nowNanoseconds: nowNanoseconds,
            recoveryEnabled: usesDeviceReportCallback
        )
        for event in events {
            switch event {
            case .deviceDeliveryConfirmed:
                diagnosticLogger("HID REPORT PATH device_delivery=confirmed")
            case .deviceDeliveryRecovered:
                diagnosticLogger("HID REPORT PATH device_delivery=recovered")
            case .managerFallback:
                diagnosticLogger("HID REPORT PATH fallback=manager reason=device_silent")
            case let .window(window):
                diagnosticLogger(
                    "HID REPORT PATH WINDOW window_ms=\(window.windowMilliseconds) " +
                        "device_reports=\(window.deviceReports) " +
                        "manager_reports=\(window.managerReports) " +
                        "duplicates=\(window.duplicateReports) " +
                        "manager_fallback=\(window.fallbackReports) " +
                        "device_healthy=\(window.deviceHealthy)"
                )
            case let .recoveryCandidate(attempt, managerReports):
                diagnosticLogger(
                    "HID REPORT PATH watchdog result=candidate reason=device_silent " +
                        "attempt=\(attempt) manager_reports=\(managerReports)"
                )
                requestDeviceCallbackRecovery()
            case let .recoveryExhausted(attempts):
                diagnosticLogger(
                    "HID REPORT PATH watchdog result=exhausted reason=device_silent " +
                        "attempts=\(attempts)"
                )
            }
        }
    }

    private func requestDeviceCallbackRecovery() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.usesDeviceReportCallback, let device = self.activeDevice else {
                self?.diagnosticLogger(
                    "HID REPORT PATH watchdog result=unavailable reason=no_active_device"
                )
                return
            }
            if self.unregisterDeviceReportCallback(device) {
                self.registerDeviceReportCallbackIfNeeded(device)
                self.diagnosticLogger(
                    "HID REPORT PATH watchdog result=callback_reregistered reason=device_silent"
                )
            } else {
                self.diagnosticLogger(
                    "HID REPORT PATH watchdog result=skipped reason=registration_missing"
                )
            }
        }
    }

    func updateStatus(_ value: LocalizedMessage) {
        status = value
        onStatus?(value)
    }
}
