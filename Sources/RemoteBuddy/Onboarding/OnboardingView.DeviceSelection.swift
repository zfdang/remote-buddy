import AppKit
import Combine
import CoreBluetooth
import SwiftUI

extension OnboardingView {
    var remoteAvailabilityContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            onboardingTitle("onboarding.control_source.title")
            Text(localization.text("onboarding.control_source.detail"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(RemoteSetupDevice.allCases) { device in
                deviceSelectionCard(device)
            }
        }
    }

    func selectDevice(_ device: RemoteSetupDevice) {
        if let source = device.onboardingSource {
            selectControlSource(source)
        }
        settings.selectOnboardingDevice(device)
    }

    private func deviceSelectionCard(_ device: RemoteSetupDevice) -> some View {
        let selected = settings.onboardingDevice == device
        return onboardingActionButton(id: "control-device.\(device.rawValue)") {
            selectDevice(device)
        } label: {
            HStack(spacing: 12) {
                if let image = bundledRemoteImage(resourceName: device.illustrationResource) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 54, height: 76)
                        .accessibilityLabel(localization.text("remote.catalog.illustration"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(localization.text(device.titleKey))
                        .font(.system(size: 13, weight: .semibold))
                    if !device.canStartSetup {
                        Text(localization.text("remote.catalog.unsupported_notice"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(colorSchemeContrast == .increased ? 0.65 : 0.2),
                            lineWidth: colorSchemeContrast == .increased ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("control-device.\(device.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
