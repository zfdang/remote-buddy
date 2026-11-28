import AVFoundation
import SwiftUI

extension SettingsView {
    var keyboardMicrophonePanel: some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                Text(localization.text("keyboard_microphone.title")).font(.headline)
                Text(localization.text("keyboard_microphone.help"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(localization.text("keyboard_microphone.device"), selection: $settings.keyboardMicrophoneUID) {
                    Text(localization.text("keyboard_microphone.off")).tag("")
                    if !settings.keyboardMicrophoneUID.isEmpty,
                       !model.keyboardMicrophoneDevices.contains(where: { $0.uid == settings.keyboardMicrophoneUID }) {
                        Text(localization.text("keyboard_microphone.input_unavailable")).tag(settings.keyboardMicrophoneUID)
                    }
                    ForEach(model.keyboardMicrophoneDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .accessibilityIdentifier("keyboard-microphone.device")
                if !settings.keyboardMicrophoneUID.isEmpty {
                    Picker(localization.text("keyboard_microphone.key"), selection: $settings.keyboardMicrophoneToggleKey) {
                        ForEach([VoiceKeyMode.rightCommand, .rightOption]) { key in
                            Text(key.displayName(using: localization)).tag(key)
                        }
                    }
                    .accessibilityIdentifier("keyboard-microphone.toggle-key")
                    Text(localization.text("keyboard_microphone.key_help"))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(model.keyboardMicrophoneStatus.text(using: localization))
                        .accessibilityIdentifier("keyboard-microphone.status")
                    switch AVCaptureDevice.authorizationStatus(for: .audio) {
                    case .notDetermined:
                        Button(localization.text("keyboard_microphone.allow")) {
                            model.requestKeyboardMicrophonePermission()
                        }
                    case .denied, .restricted:
                        Link(localization.text("keyboard_microphone.open_privacy"),
                             destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    default:
                        EmptyView()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refreshKeyboardMicrophoneDevices() }
    }
}
