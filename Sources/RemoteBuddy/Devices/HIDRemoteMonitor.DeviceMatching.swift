import AppKit
import Foundation
import IOKit.hid

extension HIDRemoteMonitor {
    func deviceDidMatch(result: IOReturn, device: IOHIDDevice) {
        guard result == kIOReturnSuccess else {
            diagnosticLogger("HID DEVICE rejected reason=match_error result=\(result)")
            updateStatus(LocalizedMessage("button_mapping.error.device_open_failed"))
            return
        }
        // HID may become visible after BLE readiness. Retry association outside the
        // matching callback because learning can restart the manager.
        DispatchQueue.main.async { [weak self] in self?.onCandidateAvailable?() }
        guard !isWaitingForMatchingServices else { return }
        let deviceMetadata = metadata(for: device)
        currentReportIsGoogle = allowsG9N9N && isGoogleDevice(device, metadata: deviceMetadata)
        currentReportIsT1 = !currentReportIsGoogle && allowsT1Remote && isT1Device(device, metadata: deviceMetadata)
        guard !isGoogleCandidateIdentity(device, metadata: deviceMetadata) || currentReportIsGoogle else { return }
        guard !isT1CandidateIdentity(device, metadata: deviceMetadata) || currentReportIsT1 else { return }
        guard currentReportIsGoogle || Self.isLocationAllowed(
            locationID: deviceMetadata.locationID,
            allowedLocationIDs: allowedLocationIDs
        ) else {
            diagnosticLogger("HID DEVICE rejected reason=unsafe_location")
            return
        }
        switch Self.deviceMatchDecision(
            reportingFingerprint: deviceMetadata.fingerprint,
            activeFingerprint: deviceFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints()
        ) {
        case let .activate(fingerprint):
            _ = activateDevice(device, fingerprint: fingerprint)
        case .probe:
            probeDevice(device)
        case let .rejected(reason):
            diagnosticLogger("HID DEVICE rejected reason=\(reason)")
        }
    }

    func probeDevice(_ device: IOHIDDevice) {
        guard !probedDevices.contains(where: { CFEqual($0, device) }) else { return }
        let monitorResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard monitorResult == kIOReturnSuccess else {
            let karabinerInstalled = karabinerElementsInstalled()
            updateStatus(Self.deviceOpenFailureMessage(
                result: monitorResult,
                karabinerElementsInstalled: karabinerInstalled
            ))
            if let reason = Self.deviceOpenFailureLogReason(result: monitorResult) {
                AppLogger.shared.write(
                    "HID DEVICE PROBE BLOCKED reason=\(reason) " +
                        "karabiner_installed=\(karabinerInstalled) monitor=\(monitorResult)"
                )
            }
            diagnosticLogger("HID DEVICE PROBE FAILED monitor=\(monitorResult)")
            return
        }
        probedDevices.append(device)
        registerDeviceReportCallbackIfNeeded(device)
        diagnosticLogger("HID DEVICE probing mode=monitored")
    }

    private func hidConnectionMetadataSuffix(for device: IOHIDDevice) -> String {
        let deviceMetadata = metadata(for: device)
        let fields = RemoteHIDIdentity.readHardwareInfo(
            from: device,
            metadataIdentity: deviceMetadata.identity,
            reportDescriptor: deviceMetadata.reportDescriptor
        ).logFields
        return fields.isEmpty ? "" : " \(fields)"
    }

    func promoteProbedDevice(_ device: IOHIDDevice, fingerprint: String) -> Bool {
        guard let selectedIndex = probedDevices.firstIndex(where: { CFEqual($0, device) }) else {
            return false
        }
        let selectedDevice = probedDevices.remove(at: selectedIndex)
        let metadataSuffix = hidConnectionMetadataSuffix(for: selectedDevice)
        probedDevices.forEach {
            unregisterDeviceReportCallback($0)
            IOHIDDeviceClose($0, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        probedDevices.removeAll()
        cachedDeviceMetadata.removeAll()
        activeDevice = selectedDevice
        deviceFingerprint = fingerprint
        activeDeviceIsSeized = false
        updateStatus(LocalizedMessage(
            eventSuppressor.isRunning
                ? "button_mapping.status.connected_fallback"
                : "button_mapping.status.connected_system_actions_may_remain"
        ))
        AppLogger.shared.write("HID CONNECTED mode=probed\(metadataSuffix)")
        onDeviceConnected?(profileID, fingerprint)
        return true
    }

    enum DeviceOpenResult: Equatable {
        case seized
        case monitored(seizeAttemptResult: IOReturn?)
        case failed(seizeAttemptResult: IOReturn?, monitorResult: IOReturn)
    }

    nonisolated static func shouldAttemptSeizure(isT1Device: Bool) -> Bool {
        !isT1Device
    }

    nonisolated static func openDevice(
        isT1Device: Bool,
        openWithOptions: (IOOptionBits) -> IOReturn
    ) -> DeviceOpenResult {
        let shouldSeize = shouldAttemptSeizure(isT1Device: isT1Device)
        var seizeAttemptResult: IOReturn?
        if shouldSeize {
            let seizeResult = openWithOptions(IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            if seizeResult == kIOReturnSuccess {
                return .seized
            }
            seizeAttemptResult = seizeResult
        }
        let monitorResult = openWithOptions(IOOptionBits(kIOHIDOptionsTypeNone))
        guard monitorResult == kIOReturnSuccess else {
            return .failed(seizeAttemptResult: seizeAttemptResult, monitorResult: monitorResult)
        }
        return .monitored(seizeAttemptResult: seizeAttemptResult)
    }

    @discardableResult
    func activateDevice(
        _ device: IOHIDDevice,
        fingerprint: String
    ) -> Bool {
        let isT1 = allowsT1Remote && !isGoogleDevice(device) && isT1Device(device)
        switch Self.openDevice(isT1Device: isT1, openWithOptions: { IOHIDDeviceOpen(device, $0) }) {
        case .seized:
            registerDeviceReportCallbackIfNeeded(device)
            activeDevice = device
            deviceFingerprint = fingerprint
            activeDeviceIsSeized = true
            updateStatus(LocalizedMessage("button_mapping.status.connected"))
            AppLogger.shared.write("HID CONNECTED mode=seized\(hidConnectionMetadataSuffix(for: device))")
            onDeviceConnected?(profileID, fingerprint)
            return true
        case let .monitored(seizeAttemptResult):
            registerDeviceReportCallbackIfNeeded(device)
            activeDevice = device
            deviceFingerprint = fingerprint
            activeDeviceIsSeized = false
            updateStatus(
                LocalizedMessage(
                    eventSuppressor.isRunning
                        ? "button_mapping.status.connected_fallback"
                        : "button_mapping.status.connected_system_actions_may_remain"
                )
            )
            let metadataSuffix = hidConnectionMetadataSuffix(for: device)
            AppLogger.shared.write(
                seizeAttemptResult.map {
                    "HID CONNECTED mode=monitored " +
                        AppLogger.errorFields(domain: "io_return", code: Int($0), fieldPrefix: "seize_error") +
                        metadataSuffix
                } ?? "HID CONNECTED mode=monitored reason=t1_passthrough\(metadataSuffix)"
            )
            onDeviceConnected?(profileID, fingerprint)
            return true
        case let .failed(seizeAttemptResult, monitorResult):
            let karabinerInstalled = karabinerElementsInstalled()
            let seizeLabel = seizeAttemptResult.map(String.init) ?? "skipped"
            if let failureMessageKey = Self.deviceOpenFailureMessageKey(
                result: monitorResult,
                karabinerElementsInstalled: karabinerInstalled
            ) {
                let reason = Self.deviceOpenFailureLogReason(result: monitorResult) ?? "blocked"
                updateStatus(LocalizedMessage(failureMessageKey))
                AppLogger.shared.write(
                    "HID DEVICE OPEN BLOCKED reason=\(reason) " +
                        "karabiner_installed=\(karabinerInstalled) " +
                        "seize=\(seizeLabel) monitor=\(monitorResult)"
                )
                return false
            }
            updateStatus(LocalizedMessage("button_mapping.error.device_read_failed", arguments: [String(monitorResult)]))
            AppLogger.shared.write(
                "HID DEVICE OPEN FAILED seize=\(seizeLabel) monitor=\(monitorResult)"
            )
            return false
        }
    }

    enum BTLEServerLogCandidateResolution<Device> {
        case selected(Device)
        case rejected(String)
    }

    func deviceDidRemove(device: IOHIDDevice) {
        cachedDeviceMetadata.removeValue(forKey: ObjectIdentifier(device))
        if let activeDevice, CFEqual(activeDevice, device) {
            unregisterDeviceReportCallback(activeDevice)
            IOHIDDeviceClose(activeDevice, IOOptionBits(kIOHIDOptionsTypeNone))
            self.activeDevice = nil
            deviceFingerprint = nil
            nativeGoogleIOHIDObserved = false
            resetInputState()
            activeDeviceIsSeized = false
            updateStatus(LocalizedMessage("button_mapping.status.disconnected"))
            AppLogger.shared.write("HID DISCONNECTED")
            return
        }
        guard let probeIndex = probedDevices.firstIndex(where: { CFEqual($0, device) }) else {
            return
        }
        let probedDevice = probedDevices.remove(at: probeIndex)
        unregisterDeviceReportCallback(probedDevice)
        IOHIDDeviceClose(probedDevice, IOOptionBits(kIOHIDOptionsTypeNone))
        diagnosticLogger("HID DEVICE probe_removed")
    }

    nonisolated static func resolveBTLEServerLogCandidate<Device>(
        candidates: [(device: Device, fingerprint: String?)],
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> BTLEServerLogCandidateResolution<Device> {
        var unique: [(device: Device, fingerprint: String)] = []
        var seenFingerprints: Set<String> = []
        for candidate in candidates {
            guard case let .accepted(fingerprint) = reportRoutingDecision(
                reportingFingerprint: candidate.fingerprint,
                activeFingerprint: activeFingerprint,
                targetFingerprint: targetFingerprint,
                excludedFingerprints: excludedFingerprints
            ) else { continue }
            if seenFingerprints.insert(fingerprint).inserted {
                unique.append((candidate.device, fingerprint))
            }
        }
        guard !unique.isEmpty else {
            return .rejected("no_google_device")
        }
        guard unique.count == 1 else {
            return .rejected("ambiguous_google_device")
        }
        return .selected(unique[0].device)
    }

    /// Feeds a report recovered from the BTLEServer log through the normal IOHID path,
    /// attributed strictly to a bound and unambiguous matching G9N9N HID device.
    func handleBTLEServerLogReport(reportID: UInt32, data: Data) {
        guard let manager else { return }
        guard targetFingerprint != nil || deviceFingerprint != nil else {
            diagnosticLogger("HID BTLE_LOG report_unrouted reason=unbound_monitor id=\(reportID)")
            return
        }
        let rawCandidates: [IOHIDDevice]
        if let activeDevice {
            rawCandidates = [activeDevice] + probedDevices
        } else if let matched = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            rawCandidates = probedDevices + Array(matched)
        } else {
            rawCandidates = probedDevices
        }
        let googleCandidates = rawCandidates
            .filter { allowsG9N9N && isGoogleDevice($0) }
            .map { ($0, metadata(for: $0).fingerprint) }
        switch Self.resolveBTLEServerLogCandidate(
            candidates: googleCandidates,
            activeFingerprint: deviceFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints()
        ) {
        case let .rejected(reason):
            diagnosticLogger("HID BTLE_LOG report_unrouted reason=\(reason) id=\(reportID)")
        case let .selected(device):
            handleReport(from: device, reportID: reportID, data: data, origin: .btleServerLog)
        }
    }

    func handleReport(
        from device: IOHIDDevice,
        reportID: UInt32,
        data: Data,
        origin: HIDReportOrigin = .iohid,
        timestampNanoseconds: UInt64 = HIDReportClock.uptimeNanoseconds(),
        path: HIDReportCallbackPath = .manager
    ) {
        if origin == .iohid, path != .simulated, usesDeviceReportCallback {
            let dedupKey = HIDReportDeduplicationKey(
                devicePointer: UInt(bitPattern: Unmanaged.passUnretained(device).toOpaque()),
                reportID: reportID,
                data: data
            )
            let duplicate = reportDeduplicationCache.shouldDrop(
                key: dedupKey,
                path: path,
                timestampNanoseconds: timestampNanoseconds
            )
            recordPathReport(
                path: path,
                duplicate: duplicate,
                nowNanoseconds: timestampNanoseconds
            )
            if duplicate { return }
        }
        let previousOrigin = currentReportOrigin
        currentReportOrigin = origin
        defer { currentReportOrigin = previousOrigin }
        let reportSource = origin == .btleServerLog ? "btle_log" : "device"
        guard manager != nil else {
            diagnosticLogger("HID REPORT rejected reason=monitor_inactive path=\(path.logName)")
            return
        }
        guard !isWaitingForMatchingServices else { return }
        let deviceMetadata = metadata(for: device)
        currentReportIsGoogle = allowsG9N9N && isGoogleDevice(device, metadata: deviceMetadata)
        currentReportIsT1 = !currentReportIsGoogle && allowsT1Remote && isT1Device(device, metadata: deviceMetadata)
        currentReportDescriptor = deviceMetadata.reportDescriptor
        guard !isGoogleCandidateIdentity(device, metadata: deviceMetadata) || currentReportIsGoogle else { return }
        guard !isT1CandidateIdentity(device, metadata: deviceMetadata) || currentReportIsT1 else { return }
        guard currentReportIsGoogle || Self.isLocationAllowed(
            locationID: deviceMetadata.locationID,
            allowedLocationIDs: allowedLocationIDs
        ) else {
            diagnosticLogger("HID REPORT rejected reason=unsafe_location path=\(path.logName)")
            return
        }
        let routing = Self.reportRoutingDecision(
            reportingFingerprint: deviceMetadata.fingerprint,
            activeFingerprint: deviceFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints()
        )
        let fingerprint: String
        switch routing {
        case let .accepted(value):
            fingerprint = value
        case let .rejected(reason):
            diagnosticLogger("HID REPORT rejected reason=\(reason) path=\(path.logName)")
            return
        }
        if let rejectReason = shouldRejectBTLEServerLogGoogleReport(reportID: reportID, data: data) {
            diagnosticLogger("HID GOOGLE report dropped reason=\(rejectReason) source=\(reportSource)")
            return
        }
        if currentReportIsGoogle && origin != .btleServerLog {
            let payload = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            diagnosticLogger("HID GOOGLE report id=\(reportID) bytes=\(data.count) payload=\(payload) source=\(origin.rawValue)")
        }
        let discoveryReport: ParsedHIDReport?
        if deviceFingerprint == nil, targetFingerprint == nil {
            guard let parsed = parseReport(reportID: reportID, data: data, source: reportSource) else {
                return
            }
            recordNativeGoogleIOHIDIfNeeded(usages: parsed.mappedUsages, origin: origin)
            if isDuplicateGoogleReport(reportID: reportID, usages: parsed.mappedUsages, origin: origin) {
                if origin == .iohid && !activeDeviceIsSeized {
                    for button in RemoteButton.buttons(for: parsed.mappedUsages) {
                        eventSuppressor.arm(button: button, edge: .down)
                    }
                }
                diagnosticLogger("HID GOOGLE report dropped reason=duplicate source=\(origin.rawValue)")
                return
            }
            let observedUsages = parsed.allObservedUsages
            guard Self.shouldPromoteDiscoveryReport(usages: observedUsages) else {
                diagnosticLogger(
                    "HID REPORT deferred reason=discovery_no_known_button source=\(reportSource) " +
                        "id=\(reportID) bytes=\(data.count) usage_count=\(observedUsages.count) path=\(path.logName)"
                )
                return
            }
            discoveryReport = parsed
        } else {
            discoveryReport = nil
        }
        if deviceFingerprint == nil {
            if !promoteProbedDevice(device, fingerprint: fingerprint) {
                guard activateDevice(
                    device,
                    fingerprint: fingerprint
                ) else {
                    t1ReportUsageState.reset()
                    clearT1PassthroughTracking()
                    diagnosticLogger("HID REPORT rejected reason=device_activation_failed path=\(path.logName)")
                    return
                }
            }
        }
        guard runtimePermissionsAreValid() else {
            diagnosticLogger("HID REPORT rejected reason=runtime_permission_revoked path=\(path.logName)")
            releaseForRevokedPermissions()
            return
        }
        if let discoveryReport {
            processParsedReport(
                reportID: reportID,
                data: data,
                source: reportSource,
                parsed: discoveryReport
            )
        } else {
            parseAndProcess(reportID: reportID, data: data, source: reportSource)
        }
    }

    func reportCallbackRejected(
        reason: String,
        result: IOReturn,
        reportLength: CFIndex,
        path: HIDReportCallbackPath = .manager
    ) {
        diagnosticLogger(
            "HID REPORT callback_rejected reason=\(reason) result=\(result) " +
                "bytes=\(max(0, reportLength)) path=\(path.logName)"
        )
    }

    nonisolated static func acceptsReport(reportingFingerprint: String?, activeFingerprint: String?) -> Bool {
        guard let reportingFingerprint, let activeFingerprint else { return false }
        return reportingFingerprint == activeFingerprint
    }

    nonisolated static func resolvedFingerprintForReport(
        reportingFingerprint: String?,
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> String? {
        switch reportRoutingDecision(
            reportingFingerprint: reportingFingerprint,
            activeFingerprint: activeFingerprint,
            targetFingerprint: targetFingerprint,
            excludedFingerprints: excludedFingerprints
        ) {
        case let .accepted(fingerprint): fingerprint
        case .rejected: nil
        }
    }

    nonisolated static func reportRoutingDecision(
        reportingFingerprint: String?,
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> HIDReportRoutingDecision {
        guard let reportingFingerprint else { return .rejected("fingerprint_unavailable") }
        if let activeFingerprint {
            return reportingFingerprint == activeFingerprint
                ? .accepted(activeFingerprint)
                : .rejected("active_fingerprint_mismatch")
        }
        guard !excludedFingerprints.contains(reportingFingerprint) else {
            return .rejected("excluded_fingerprint")
        }
        if let targetFingerprint {
            return reportingFingerprint == targetFingerprint
                ? .accepted(targetFingerprint)
                : .rejected("target_fingerprint_mismatch")
        }
        return .accepted(reportingFingerprint)
    }

    nonisolated static func deviceMatchDecision(
        reportingFingerprint: String?,
        activeFingerprint: String?,
        targetFingerprint: String?,
        excludedFingerprints: Set<String>
    ) -> HIDDeviceMatchDecision {
        guard let reportingFingerprint else {
            return .rejected("fingerprint_unavailable")
        }
        guard activeFingerprint == nil else {
            return .rejected("active_device_exists")
        }
        guard !excludedFingerprints.contains(reportingFingerprint) else {
            return .rejected("excluded_fingerprint")
        }
        if let targetFingerprint {
            return reportingFingerprint == targetFingerprint
                ? .activate(targetFingerprint)
                : .rejected("target_mismatch")
        }
        return .probe
    }

    nonisolated static func deviceMatchingCriteria(includeXiaomi: Bool, includeGoogle: Bool,
                                       includeT1: Bool = false,
                                       additionalIdentities: [RemoteHIDIdentity] = []) -> [[String: Any]] {
        // IOHIDManager does not constrain matching by Product name. A name-only
        // dictionary acts as a wildcard and can open unrelated keyboards that
        // another remapper owns, failing the entire manager with exclusive access.
        var matches: [[String: Any]] = []
        if includeXiaomi {
            matches.append([kIOHIDVendorIDKey as String: 0x2717,
                            kIOHIDProductIDKey as String: 0x32B8])
        }
        if includeGoogle {
            matches.append([kIOHIDVendorIDKey as String: G9N9NProtocol.vendorID,
                            kIOHIDProductIDKey as String: G9N9NProtocol.productID])
        }
        if includeT1 {
            matches.append(RemoteHIDIdentity.t1Remote.matchingDictionary)
        }
        var included = Set(matches.compactMap { match -> RemoteHIDIdentity? in
            guard let vendor = match[kIOHIDVendorIDKey] as? Int,
                  let product = match[kIOHIDProductIDKey] as? Int else { return nil }
            return RemoteHIDIdentity(vendorID: UInt16(vendor), productID: UInt16(product))
        })
        for identity in additionalIdentities where identity.vendorID != 0 && included.insert(identity).inserted {
            matches.append(identity.matchingDictionary)
        }
        return matches
    }

    nonisolated static func monitorFamilies(targetModel: RemoteModel?, powerKeySuppressed: Bool,
                                allowsGoogle: Bool) -> (xiaomi: Bool, google: Bool) {
        let xiaomi = powerKeySuppressed && (targetModel == nil || targetModel == .unknown || targetModel == .rc001 || targetModel == .rc003)
        let google = allowsGoogle && (targetModel == nil || targetModel?.isChromecastRemote == true)
        return (xiaomi, google)
    }

    nonisolated static func monitorsT1Family(targetModel: RemoteModel?, powerKeySuppressed: Bool,
                                 allowsT1Remote: Bool) -> Bool {
        allowsT1Remote && powerKeySuppressed && (targetModel == nil || targetModel?.isT1Remote == true)
    }

    nonisolated static func matchesGoogleProtocol(identity: RemoteHIDIdentity, fingerprint: String,
                                      profiles: [RemoteDeviceProfile]) -> Bool {
        let matching = profiles.filter { $0.model.isChromecastRemote && $0.hidFingerprint == fingerprint }
        if identity == .chromecast, matching.isEmpty { return true }
        return matching.contains { profile in
            (profile.compatibleHIDBinding?.identity == identity &&
             profile.compatibleHIDBinding?.fingerprint == fingerprint) ||
                (profile.compatibleHIDBinding == nil && identity == .chromecast)
        }
    }

    nonisolated static func matchesT1Protocol(identity: RemoteHIDIdentity, fingerprint: String,
                                  profiles: [RemoteDeviceProfile]) -> Bool {
        let matching = profiles.filter { $0.model.isT1Remote && $0.hidFingerprint == fingerprint }
        if identity == .t1Remote, matching.isEmpty { return true }
        return matching.contains { profile in
            (profile.compatibleHIDBinding?.identity == identity &&
             profile.compatibleHIDBinding?.fingerprint == fingerprint) ||
                (profile.compatibleHIDBinding == nil && identity == .t1Remote)
        }
    }

    func metadata(for device: IOHIDDevice) -> CachedDeviceMetadata {
        let key = ObjectIdentifier(device)
        if let cached = cachedDeviceMetadata[key] {
            return cached
        }
        let resolved = CachedDeviceMetadata(
            fingerprint: Self.fingerprint(for: device),
            identity: RemoteHIDIdentity.read(from: device),
            locationID: Self.locationID(for: device),
            reportDescriptor: IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data
        )
        cachedDeviceMetadata[key] = resolved
        return resolved
    }

    func isGoogleCandidateIdentity(_ device: IOHIDDevice, metadata: CachedDeviceMetadata? = nil) -> Bool {
        guard let identity = (metadata ?? self.metadata(for: device)).identity else { return false }
        return identity == .chromecast || settings.compatibleHIDIdentities(
            includeXiaomi: false, includeGoogle: true).contains(identity)
    }

    func isGoogleDevice(_ device: IOHIDDevice, metadata: CachedDeviceMetadata? = nil) -> Bool {
        let resolved = metadata ?? self.metadata(for: device)
        guard let fingerprint = resolved.fingerprint,
              let identity = resolved.identity else { return false }
        return Self.matchesGoogleProtocol(identity: identity, fingerprint: fingerprint,
            profiles: settings.remoteDeviceProfiles)
    }

    func isT1CandidateIdentity(_ device: IOHIDDevice, metadata: CachedDeviceMetadata? = nil) -> Bool {
        guard let identity = (metadata ?? self.metadata(for: device)).identity else { return false }
        return identity == .t1Remote || settings.compatibleHIDIdentities(
            includeXiaomi: false, includeGoogle: false, includeT1: true).contains(identity)
    }

    func isT1Device(_ device: IOHIDDevice, metadata: CachedDeviceMetadata? = nil) -> Bool {
        let resolved = metadata ?? self.metadata(for: device)
        guard let fingerprint = resolved.fingerprint,
              let identity = resolved.identity else { return false }
        return Self.matchesT1Protocol(identity: identity, fingerprint: fingerprint,
            profiles: settings.remoteDeviceProfiles)
    }

    nonisolated static func shouldPromoteDiscoveryReport(usages: Set<UInt16>) -> Bool {
        !RemoteButton.buttons(for: usages).isEmpty
    }

    nonisolated static func deviceOpenFailureMessageKey(
        result: IOReturn,
        karabinerElementsInstalled: Bool
    ) -> String? {
        if result == kIOReturnExclusiveAccess {
            return karabinerElementsInstalled
                ? "button_mapping.error.exclusive_access.karabiner"
                : "button_mapping.error.exclusive_access"
        }
        if result == kIOReturnNotPermitted {
            return HIDStatusKeys.notPermitted
        }
        return nil
    }

    nonisolated static func deviceOpenFailureLogReason(result: IOReturn) -> String? {
        if result == kIOReturnExclusiveAccess { return "exclusive_access" }
        if result == kIOReturnNotPermitted { return "not_permitted" }
        return nil
    }

    nonisolated static func isKarabinerElementsInstalled(
        applicationURL: URL? = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "org.pqrs.Karabiner-Elements"
        ),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Bool {
        if applicationURL != nil { return true }
        return [
            "/Applications/Karabiner-Elements.app",
            "/Library/Application Support/org.pqrs.Karabiner-Elements",
        ].contains(where: fileExists)
    }

    nonisolated static func isKarabinerElementsRunning(
        bundleIdentifiers: [String] = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    ) -> Bool {
        bundleIdentifiers.contains { identifier in
            let normalized = identifier.lowercased()
            return normalized == "org.pqrs.karabiner-elements" ||
                normalized == "org.pqrs.karabiner-eventviewer" ||
                normalized.hasPrefix("org.pqrs.karabiner.")
        }
    }

    nonisolated static func deviceOpenFailureMessage(
        result: IOReturn,
        karabinerElementsInstalled: Bool
    ) -> LocalizedMessage {
        if let key = deviceOpenFailureMessageKey(
            result: result,
            karabinerElementsInstalled: karabinerElementsInstalled
        ) {
            return LocalizedMessage(key)
        }
        return LocalizedMessage(
            "button_mapping.error.device_read_failed",
            arguments: [String(result)]
        )
    }

    nonisolated static func buttonList(for usages: Set<UInt16>) -> String {
        let buttons = usages.compactMap { RemoteButton.usageMap[$0]?.rawValue }.sorted()
        return buttons.isEmpty ? "none" : buttons.joined(separator: ",")
    }
}

extension HIDRemoteMonitor.BTLEServerLogCandidateResolution: Equatable where Device: Equatable {}
