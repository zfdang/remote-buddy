import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var bluetoothPermissionState: PermissionVisualState {
        bluetoothAuthorization == .allowedAlways ? .granted : .pending
    }

    func refreshPermissionStates() {
        bluetoothAuthorization = permissionOverrides?.bluetooth ?? CBManager.authorization
        inputMonitoringGranted = permissionOverrides?.inputMonitoring ?? HIDRemoteMonitor.isInputMonitoringGranted
        accessibilityGranted = permissionOverrides?.accessibility ?? KeyboardInjector.isAccessibilityTrusted
        if permissionOverrides == nil {
            integrationToolAvailability = OnboardingInputSourceSwitcher.integrationAvailability(
                for: settings.onboardingVoiceTool
            )
            model.refreshRuntimePermissionDiagnosis(
                trigger: "settings_permission_refresh",
                bluetoothGranted: bluetoothAuthorization == .allowedAlways
            )
        }
    }
}
