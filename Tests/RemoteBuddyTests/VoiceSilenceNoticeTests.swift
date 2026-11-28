import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Voice silence notice")
struct VoiceSilenceNoticeTests {
    @Test func trackerFiresOnceAt60sAfterAudioReceivedAndResetsOnNewSession() {
        var tracker = VoiceSilenceNoticeTracker()

        // No audio ever received (e.g. opened silently under VAD): must not fire yet.
        let initialDue = tracker.consumePresentationIfDue(now: 120)
        #expect(!initialDue)

        // First audio frame starts the countdown from that timestamp.
        tracker.audioReceived(at: 10)
        let beforeThresholdDue = tracker.consumePresentationIfDue(now: 69.9)
        let atThresholdDue = tracker.consumePresentationIfDue(now: 70.0)
        #expect(!beforeThresholdDue)
        #expect(atThresholdDue)

        // Repeated checks in the same session never re-trigger.
        let repeatedDue = tracker.consumePresentationIfDue(now: 130.0)
        #expect(!repeatedDue)
        tracker.audioReceived(at: 135.0)
        let afterMoreAudioDue = tracker.consumePresentationIfDue(now: 250.0)
        #expect(!afterMoreAudioDue)

        // Ending or beginning a new session clears prior state so a new session can warn again.
        tracker.beginSession()
        let resetBeforeAudioDue = tracker.consumePresentationIfDue(now: 300.0)
        #expect(!resetBeforeAudioDue)
        tracker.audioReceived(at: 300.0)
        let nextSessionDue = tracker.consumePresentationIfDue(now: 360.0)
        #expect(nextSessionDue)

        tracker.endSession()
        #expect(tracker.lastAudioAt == nil)
        #expect(!tracker.didPresent)
    }

    @Test @MainActor func bridgeAppModelPresentsLocalizedReminderOncePerHandsFreeSession() throws {
        let defaults = EphemeralUserDefaults()
        let settings = AppSettings(defaults: values(defaults))
        let model = BridgeAppModel(settings: settings, initialAudioDevices: [])

        var presented: [(title: String, text: String)] = []
        model.onVoiceSilenceNoticePresented = { title, text in
            presented.append((title, text))
        }

        model.voiceSilenceNoticeTracker.beginSession()
        model.voiceSilenceNoticeTracker.audioReceived(at: 100)
        #expect(!model.evaluateVoiceSilenceNotice(now: 159))
        #expect(presented.isEmpty)

        #expect(model.evaluateVoiceSilenceNotice(now: 160))
        #expect(presented.count == 1)
        #expect(!presented[0].title.isEmpty)
        #expect(!presented[0].text.isEmpty)

        #expect(!model.evaluateVoiceSilenceNotice(now: 260))
        #expect(presented.count == 1)
    }

    @Test func noticePaletteContrastMeetsAccessibilityThresholds() {
        for dark in [false, true] {
            for tier in NoticeTier.allCases {
                let colors = NoticePalette.bubble(tier, dark: dark)
                let titleRatio = contrastRatio(colors.title, colors.fill)
                let bodyRatio = contrastRatio(colors.body, colors.fill)
                #expect(titleRatio >= 4.5, "Title contrast too low for \(tier) dark=\(dark): \(titleRatio)")
                #expect(bodyRatio >= 4.5, "Body contrast too low for \(tier) dark=\(dark): \(bodyRatio)")
                if dark {
                    let borderRatio = contrastRatio(colors.border, NoticePalette.darkSurface)
                    #expect(borderRatio >= 3.0, "Dark border contrast too low for \(tier): \(borderRatio)")
                }
            }
        }
    }

    private func values(_ defaults: UserDefaults) -> UserDefaults { defaults }

    private func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let l1 = relativeLuminance(a)
        let l2 = relativeLuminance(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func relativeLuminance(_ hex: UInt32) -> Double {
        func linear(_ byte: UInt32) -> Double {
            let s = Double(byte & 0xFF) / 255.0
            return s <= 0.03928 ? (s / 12.92) : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(hex >> 16) + 0.7152 * linear(hex >> 8) + 0.0722 * linear(hex)
    }
}
