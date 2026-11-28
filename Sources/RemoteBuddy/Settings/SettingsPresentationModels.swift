import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

enum SettingsSection: String, CaseIterable, Codable, Identifiable {
    case connection
    case integration
    case mapping
    case commonPhrases
    case permissions
    case general
    case applicationIntegration
    case about

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .connection: return "settings.section.connection"
        case .integration: return "settings.section.integration"
        case .mapping: return "settings.section.buttons"
        case .commonPhrases: return "common_phrases.title"
        case .permissions: return "settings.section.permissions"
        case .general: return "settings.section.general"
        case .applicationIntegration: return "application_integration.title"
        case .about: return "settings.section.about"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: return "appletvremote.gen4"
        case .integration: return "waveform"
        case .mapping: return "keyboard"
        case .commonPhrases: return "text.quote"
        case .permissions: return "lock.shield"
        case .general: return "slider.horizontal.3"
        case .applicationIntegration: return "cursorarrow.click"
        case .about: return "info.circle"
        }
    }
}

enum SettingsPermissionKind {
    case bluetooth
    case inputMonitoring
    case accessibility
}

struct SystemPermissionOverrides: Equatable, Sendable {
    var bluetooth: CBManagerAuthorization?
    var inputMonitoring: Bool?
    var accessibility: Bool?
    var postEventAccess: Bool? = nil

    static let allGranted = SystemPermissionOverrides(
        bluetooth: .allowedAlways,
        inputMonitoring: true,
        accessibility: true,
        postEventAccess: true
    )
}

enum SettingsPermissionAction: Equatable {
    case request
    case openSystemSettings(String)

    var titleKey: String {
        switch self {
        case .request:
            "permission.action.request"
        case .openSystemSettings:
            "permission.action.open_settings"
        }
    }
}

struct SettingsDiagnosticSnapshot: Equatable {
    let appVersion: String
    let appBuild: String
    let macosVersion: String
    let architecture: String
    let isRosetta: Bool
    let bluetoothGranted: Bool
    let inputMonitoringGranted: Bool
    let accessibilityGranted: Bool
    let postEventAccessGranted: Bool
    let remoteConnected: Bool
    let remoteModel: String
    let virtualMicrophoneReady: Bool
    let audioOutputReady: Bool
    let voiceTool: String
    let voiceShortcutName: String
    let runtimeLogEnabled: Bool
    let runtimeLogAvailable: Bool
    let runtimeLogPath: String
    let runtimeLogSizeBytes: Int64?
    let runtimePermissionIssue: String
    let runtimePermissionIssueUpdatedAt: Date?
    let runtimePermissionDiagnosisTrigger: String
    let connectionStatusKey: String
    let hidStatusKey: String
    let generatedAt: Date

    init(
        appVersion: String,
        appBuild: String = "1",
        macosVersion: String = FirstUseDiagnosticSnapshot.systemVersion,
        architecture: String = FirstUseDiagnosticSnapshot.architecture,
        isRosetta: Bool = FirstUseDiagnosticSnapshot.runningUnderRosetta == "true",
        bluetoothGranted: Bool,
        inputMonitoringGranted: Bool,
        accessibilityGranted: Bool,
        postEventAccessGranted: Bool? = nil,
        remoteConnected: Bool = false,
        remoteModel: String = "none",
        virtualMicrophoneReady: Bool = false,
        audioOutputReady: Bool = false,
        voiceTool: String = "unselected",
        voiceShortcutName: String = "unknown",
        runtimeLogEnabled: Bool = true,
        runtimeLogAvailable: Bool,
        runtimeLogPath: String = SettingsDiagnosticSnapshot.sanitizePath(AppLogger.shared.logURL.path),
        runtimeLogSizeBytes: Int64? = nil,
        runtimePermissionIssue: String = "none",
        runtimePermissionIssueUpdatedAt: Date? = nil,
        runtimePermissionDiagnosisTrigger: String = "none",
        connectionStatusKey: String = "unknown",
        hidStatusKey: String = "unknown",
        generatedAt: Date = Date()
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macosVersion = macosVersion
        self.architecture = architecture
        self.isRosetta = isRosetta
        self.bluetoothGranted = bluetoothGranted
        self.inputMonitoringGranted = inputMonitoringGranted
        self.accessibilityGranted = accessibilityGranted
        self.postEventAccessGranted = postEventAccessGranted ?? accessibilityGranted
        self.remoteConnected = remoteConnected
        self.remoteModel = remoteModel
        self.virtualMicrophoneReady = virtualMicrophoneReady
        self.audioOutputReady = audioOutputReady
        self.voiceTool = voiceTool
        self.voiceShortcutName = voiceShortcutName
        self.runtimeLogEnabled = runtimeLogEnabled
        self.runtimeLogAvailable = runtimeLogAvailable
        self.runtimeLogPath = Self.sanitizePath(runtimeLogPath)
        self.runtimeLogSizeBytes = runtimeLogSizeBytes
        self.runtimePermissionIssue = runtimePermissionIssue
        self.runtimePermissionIssueUpdatedAt = runtimePermissionIssueUpdatedAt
        self.runtimePermissionDiagnosisTrigger = runtimePermissionDiagnosisTrigger
        self.connectionStatusKey = connectionStatusKey
        self.hidStatusKey = hidStatusKey
        self.generatedAt = generatedAt
    }

    static func sanitizePath(_ text: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let normalizedHome = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        guard !normalizedHome.isEmpty else { return text }
        var redacted = text.replacingOccurrences(of: normalizedHome + "/", with: "~/")
        if redacted == normalizedHome {
            return "~"
        }
        redacted = redacted.replacingOccurrences(of: "=\(normalizedHome) ", with: "=~ ")
        if redacted.hasSuffix("=\(normalizedHome)") {
            redacted = String(redacted.dropLast(normalizedHome.count)) + "~"
        }
        return redacted
    }

    var formattedLogSize: String {
        guard let bytes = runtimeLogSizeBytes else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    var summary: String {
        let lines: [String] = [
            "### Remote Buddy 运行环境与诊断信息 / Runtime Diagnostics",
            "- **应用版本 / App Version:** \(appVersion) (Build \(appBuild))",
            "- **系统版本 / macOS:** \(macosVersion) (\(architecture)\(isRosetta ? ", Rosetta" : ""))",
            "- **生成时间 / Generated At:** \(Self.timestamp(generatedAt))",
            "",
            "#### 系统权限状态 / Permissions",
            "- 蓝牙 / Bluetooth: \(bluetoothGranted ? "已授权 (Granted)" : "未授权 (Denied)")",
            "- 输入监控 / Input Monitoring: \(inputMonitoringGranted ? "已授权 (Granted)" : "未授权 (Denied)")",
            "- 辅助功能 / Accessibility: \(accessibilityGranted ? "已授权 (Granted)" : "未授权 (Denied)")",
            "- 全局按键注入 / Post Event Access: \(postEventAccessGranted ? "已授权 (Granted)" : "受限或未授权 (Denied/Restricted)")",
            "- 运行时权限诊断 / Runtime Issue: \(runtimePermissionIssue)",
            "- 权限诊断触发来源 / Permission Diagnosis Trigger: \(runtimePermissionDiagnosisTrigger)",
            "- 权限诊断更新时间 / Permission Issue Updated At: \(runtimePermissionIssueUpdatedAt.map(Self.timestamp) ?? "none")",
            "",
            "#### 设备与驱动 / Devices & Drivers",
            "- 遥控器连接 / Remote Connected: \(remoteConnected ? "已连接 (Yes)" : "未连接 (No)") [\(remoteModel)]",
            "- 虚拟麦克风驱动 / Virtual Mic Driver: \(virtualMicrophoneReady ? "已就绪 (Ready)" : "未就绪 (Not Ready)")",
            "- 音频输出 / Audio Output: \(audioOutputReady ? "已就绪 (Ready)" : "未就绪 (Not Ready)")",
            "- 蓝牙连接状态 / Bluetooth Connection Status: \(connectionStatusKey)",
            "- 按键映射状态 / Button Mapping Status: \(hidStatusKey)",
            "",
            "#### 配置与集成 / Configuration",
            "- 语音工具 / Voice Tool: \(voiceTool)",
            "- 语音快捷键 / Voice Shortcut: \(voiceShortcutName)",
            "",
            "#### 诊断日志 / Runtime Logs",
            "- 日志记录状态 / Logging Enabled: \(runtimeLogEnabled ? "已开启 (Enabled)" : "已关闭 (Disabled)")",
            "- 日志文件状态 / Log Available: \(runtimeLogAvailable ? "存在 (\(formattedLogSize))" : "未找到 (Not Found)")",
            "- 本地路径 / Log Path: \(runtimeLogPath)"
        ]
        return lines.joined(separator: "\n")
    }

    var auditLog: String {
        "SETTINGS DIAGNOSTICS copied app_version=\(appVersion) " +
            "macos=\(macosVersion) arch=\(architecture) " +
            "bluetooth=\(bluetoothGranted) " +
            "input_monitoring=\(inputMonitoringGranted) " +
            "accessibility=\(accessibilityGranted) " +
            "post_event=\(postEventAccessGranted) " +
            "remote_connected=\(remoteConnected) " +
            "remote_model=\(remoteModel)"
    }
}

enum RemoteBatteryPresentationPolicy {
    static func shouldShowBattery(
        model: RemoteModel,
        level: Int?,
        powerState: RemotePowerState?
    ) -> Bool {
        if model.isChromecastRemote { return level != nil }
        guard model.isAppleSiriRemote else { return true }
        guard level == nil else { return true }
        return powerState == .charging || powerState == .externalPower
    }
}

enum SettingsPageBehavior {
    static let sidebarWidth: CGFloat = 108
    static let sidebarDividerWidth: CGFloat = 1
    static var contentLeadingInset: CGFloat { sidebarWidth + sidebarDividerWidth }

    static let sidebarTopDragHeight: CGFloat = 5

    static let sidebarSectionGroups: [[SettingsSection]] = [
        [.general, .permissions, .connection, .integration],
        [.mapping, .applicationIntegration],
        [.about],
    ]
    static let sidebarSectionOrder = sidebarSectionGroups.flatMap { $0 }

    static func sidebarSections() -> [SettingsSection] {
        sidebarSectionOrder
    }

    static func initialSection(requestedSection: SettingsSection?) -> SettingsSection {
        requestedSection ?? sidebarSectionOrder.first ?? .about
    }

    @MainActor static func beginDeviceSetup(settings: AppSettings) {
        settings.preserveCompletedOnboarding(returnSection: .connection)
        settings.onboardingPurpose = settings.canDismissOnboarding ? .addDevice : .initialSetup
        settings.discardOnboardingVoiceTrial()
        settings.onboardingDevice = nil
        settings.onboardingControlSource = .unselected
        settings.onboardingRemoteAvailability = .unselected
        settings.onboardingCompletedVersion = 0
        settings.onboardingStep = .remoteAvailability
    }

    @MainActor static func beginIntegrationSetup(tool: OnboardingVoiceTool, settings: AppSettings) {
        settings.synchronizeOnboardingRemoteWithSelectedProfile()
        settings.preserveCompletedOnboarding(returnSection: .integration)
        settings.discardOnboardingVoiceTrial()
        settings.onboardingPurpose = settings.canDismissOnboarding && settings.onboardingControlSource != .unselected
            ? .integration : .initialSetup
        settings.onboardingCompletedVersion = 0
        settings.setOnboardingVoiceTool(tool)
        let start: OnboardingStep = settings.onboardingPurpose == .integration ? .voiceTrigger
            : (settings.canDismissOnboarding ? .remoteAvailability : .permissions)
        settings.setOnboardingStep(start)
    }

    static func showsReconnectAction(for profile: RemoteDeviceProfile) -> Bool {
        profile.bluetoothIdentifier != nil
    }

    static func visibleSection(for requestedSection: SettingsSection) -> SettingsSection {
        requestedSection
    }

    static func showsUpdateBadge(
        for section: SettingsSection,
        hasUnseenUpdate: Bool
    ) -> Bool {
        section == .about && hasUnseenUpdate
    }

    static func marksUpdateAsSeen(whenSelecting section: SettingsSection) -> Bool {
        section == .about
    }

    static func permissionAction(
        for permission: SettingsPermissionKind,
        isGranted: Bool
    ) -> SettingsPermissionAction {
        switch permission {
        case .bluetooth:
            .openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
        case .inputMonitoring:
            isGranted
                ? .openSystemSettings(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
                )
                : .request
        case .accessibility:
            isGranted
                ? .openSystemSettings(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                )
                : .request
        }
    }

    static func perform(
        _ action: SettingsPermissionAction,
        requestPermission: () -> Void,
        openSystemSettings: (String) -> Void
    ) {
        switch action {
        case .request:
            requestPermission()
        case let .openSystemSettings(url):
            openSystemSettings(url)
        }
    }

    static func copyDiagnosticSummary(
        _ snapshot: SettingsDiagnosticSnapshot,
        writeToPasteboard: (String) -> Void,
        writeAuditLog: (String) -> Void
    ) {
        writeToPasteboard(snapshot.summary)
        writeAuditLog(snapshot.auditLog)
    }
}


enum PermissionVisualState {
    case granted
    case pending

    @MainActor
    func title(using localization: LocalizationStore) -> String {
        switch self {
        case .granted: return localization.text("permission.status.enabled")
        case .pending: return localization.text("permission.status.pending")
        }
    }

    var tint: Color {
        switch self {
        case .granted: return .green
        case .pending: return .orange
        }
    }
}

struct ShortcutEditingTarget: Identifiable, Equatable {
    let button: RemoteButton
    let trigger: ButtonTrigger

    var id: String { "\(button.rawValue)-\(trigger.rawValue)" }
}

struct ShortcutCaptureFeedback: Equatable {
    enum Result: Equatable {
        case succeeded
        case failed(ShortcutCaptureStartFailure)
    }

    let contextID: String
    let result: Result
}

enum CustomApplicationLearningState: Equatable {
    case recording
    case succeeded
    case failed
    case applicationMissing
    case openFailed

    var messageKey: String {
        switch self {
        case .recording: return "custom_application.accessibility.learning"
        case .succeeded: return "custom_application.accessibility.learn_succeeded"
        case .failed: return "custom_application.accessibility.learn_failed"
        case .applicationMissing: return "custom_application.error.not_installed"
        case .openFailed: return "custom_application.error.open_failed"
        }
    }

    var tint: Color {
        switch self {
        case .recording: return .orange
        case .succeeded: return .green
        case .failed, .applicationMissing, .openFailed: return .red
        }
    }

    var systemImage: String {
        switch self {
        case .recording: return "timer"
        case .succeeded: return "checkmark.circle.fill"
        case .failed, .applicationMissing, .openFailed: return "exclamationmark.triangle.fill"
        }
    }
}

enum MappingActionFilter: String, CaseIterable, Identifiable {
    case directPassthrough
    case basicKeys
    case systemAndMedia
    case applications
    case commonPhrases
    case custom

    var id: String { rawValue }

    static func visibleCases(for button: RemoteButton? = nil, trigger: ButtonTrigger? = nil) -> [Self] {
        if let button, button.isDirectional, trigger == nil || trigger == .singleClick {
            return [.directPassthrough, .basicKeys, .systemAndMedia, .applications, .commonPhrases, .custom]
        }
        return [.basicKeys, .systemAndMedia, .applications, .commonPhrases, .custom]
    }

    static var visibleCases: [Self] {
        [.basicKeys, .systemAndMedia, .applications, .commonPhrases, .custom]
    }

    var localizationKey: String {
        switch self {
        case .directPassthrough: return ButtonActionCategory.directPassthrough.localizationKey
        case .basicKeys: return ButtonActionCategory.basicKeys.localizationKey
        case .systemAndMedia: return ButtonActionCategory.systemAndMedia.localizationKey
        case .applications: return ButtonActionCategory.applications.localizationKey
        case .commonPhrases: return ButtonActionCategory.commonPhrases.localizationKey
        case .custom: return ButtonActionCategory.custom.localizationKey
        }
    }

    var category: ButtonActionCategory {
        switch self {
        case .directPassthrough: return .directPassthrough
        case .basicKeys: return .basicKeys
        case .systemAndMedia: return .systemAndMedia
        case .applications: return .applications
        case .commonPhrases: return .commonPhrases
        case .custom: return .custom
        }
    }

    init(category: ButtonActionCategory) {
        switch category {
        case .directPassthrough: self = .directPassthrough
        case .basicKeys: self = .basicKeys
        case .systemAndMedia: self = .systemAndMedia
        case .applications: self = .applications
        case .commonPhrases: self = .commonPhrases
        case .custom: self = .custom
        }
    }
}

enum MappingSelectionPolicy {
    static func selection(
        current: RemoteButton,
        activeButtons: Set<RemoteButton>,
        isLocked: Bool
    ) -> RemoteButton {
        guard !isLocked else { return current }
        return RemoteButton.allCases.first(where: activeButtons.contains) ?? current
    }
}
