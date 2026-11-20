import AppKit
import Combine
import CoreBluetooth
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var integrationPage: some View {
        settingsPage {
            PageHeader(title: localization.text("settings.integration.title"))
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                Text(localization.text("settings.integration.introduction"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localization.text("settings.integration.shortcut_title")).font(.headline)
                        voiceTriggerStatus
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(localization.text("settings.integration.current")).font(.headline)
                        Text(localization.text(settings.onboardingVoiceTool.titleKey))
                            .font(.title3.weight(.medium))

                        if settings.onboardingVoiceTool.preferredInputSourceID != nil {
                            Divider()
                                .padding(.vertical, 2)
                            Toggle(isOn: $settings.bypassInputSourceSwitching) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(bypassSwitchTitle)
                                        .font(.body)
                                    Text(bypassSwitchDetail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .toggleStyle(.switch)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 20) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                    Button(localization.text("settings.integration.configure")) {
                        SettingsPageBehavior.beginIntegrationSetup(
                            tool: settings.onboardingVoiceTool,
                            settings: settings
                        )
                    }
                    .compatibilityButtonStyle(.prominent)
                    .controlSize(.large)
                    .fixedSize()
                    Rectangle()
                        .fill(Color.primary.opacity(0.18))
                        .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                }
                .padding(.vertical, 8)
                Text(localization.text("settings.integration.supported_tools"))
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ForEach(OnboardingVoiceToolVisibilityPolicy.tools) { tool in
                        integrationToolCard(tool)
                    }
                }

                if let warning = model.voiceKeyCompatibilityWarning {
                    voiceKeyCompatibilityWarningPanel(warning)
                }
            }
        }
        .onAppear {
            model.refreshVoiceKeyCompatibilityWarning()
            model.refreshAudioDevices()
        }
    }

    private func integrationToolCard(_ tool: OnboardingVoiceTool) -> some View {
        let isSelected = settings.onboardingVoiceTool == tool
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(localization.text(tool.titleKey))
                    .font(.headline)
                Spacer(minLength: 0)
                if isSelected {
                    Text(localization.text("settings.integration.active_badge"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }
            }
            Text(localization.text(tool.detailKey))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if tool == .voiceBuddy {
                Link(destination: AppLinks.voiceBuddyWebsite(for: localization.locale)) {
                    Text(localization.text("onboarding.voice_tool.voice_buddy.website"))
                        .font(.caption.weight(.semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(
            isSelected ? Color.green.opacity(0.07) : Color.primary.opacity(0.03),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    isSelected ? Color.green.opacity(0.8) : Color.primary.opacity(0.14),
                    lineWidth: isSelected ? 1.5 : 1
                )
        }
        .accessibilityElement(children: tool == .voiceBuddy ? .contain : .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var bypassSwitchTitle: String {
        switch settings.onboardingVoiceTool {
        case .weixin:
            return localization.text("settings.integration.bypass_switch_title.weixin")
        case .doubao:
            return localization.text("settings.integration.bypass_switch_title.doubao")
        default:
            return localization.text("settings.integration.bypass_switch_title")
        }
    }

    private var bypassSwitchDetail: String {
        switch settings.onboardingVoiceTool {
        case .weixin:
            return localization.text("settings.integration.bypass_switch_detail.weixin")
        case .doubao:
            return localization.text("settings.integration.bypass_switch_detail.doubao")
        default:
            return localization.text("settings.integration.bypass_switch_detail")
        }
    }
}
