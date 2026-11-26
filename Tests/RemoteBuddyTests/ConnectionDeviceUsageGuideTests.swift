import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Connection device usage guide") @MainActor
struct ConnectionDeviceUsageGuideTests {
    private func makeProfile(
        model: RemoteModel,
        customName: String,
        voiceButtonMode: G9N9NVoiceButtonMode? = nil
    ) -> RemoteDeviceProfile {
        RemoteDeviceProfile(
            model: model,
            customName: customName,
            g9n9nVoiceButtonMode: voiceButtonMode,
            mappings: AppSettings.defaultMappings(for: model)
        )
    }

    @Test func guideMatchesEachSupportedModelAndMode() {
        let rc001 = makeProfile(model: .rc001, customName: "Xiaomi 2")
        let rc003 = makeProfile(model: .rc003, customName: "Xiaomi 2 Pro")
        let t1 = makeProfile(model: .t1Remote, customName: "T1")
        let g9n9nSmart = makeProfile(
            model: .chromecastVoiceRemote,
            customName: "G9N9N",
            voiceButtonMode: .smartToggle
        )
        let g9n9nHold = makeProfile(
            model: .chromecastVoiceRemote,
            customName: "G9N9N",
            voiceButtonMode: .holdToTalk
        )

        let rc001Guide = ConnectionDeviceUsageGuide.make(for: rc001)
        let rc003Guide = ConnectionDeviceUsageGuide.make(for: rc003)
        let t1Guide = ConnectionDeviceUsageGuide.make(for: t1)
        let g9n9nSmartGuide = ConnectionDeviceUsageGuide.make(for: g9n9nSmart)
        let g9n9nHoldGuide = ConnectionDeviceUsageGuide.make(for: g9n9nHold)

        #expect(rc001Guide?.badgeKey == "connection.device_guide.badge.xiaomi_hold_only")
        #expect(rc001Guide == rc003Guide)
        #expect(rc001Guide?.items.map(\.titleKey) == [
            "connection.device_guide.xiaomi.voice.title",
            "connection.device_guide.xiaomi.limit.title",
        ])

        #expect(t1Guide?.badgeKey == "connection.device_guide.badge.t1_toggle")
        #expect(t1Guide?.items.map(\.titleKey) == [
            "connection.device_guide.t1.voice.title",
            "connection.device_guide.t1.hold_compat.title",
        ])

        #expect(g9n9nSmartGuide?.badgeKey == nil)
        #expect(g9n9nSmartGuide?.items.map(\.titleKey) == [
            "connection.device_guide.g9n9n.led.title",
            "connection.device_guide.g9n9n.limit.title",
            "connection.device_guide.g9n9n.other_key_stops.title",
        ])
        #expect(g9n9nHoldGuide?.items.map(\.titleKey) == [
            "connection.device_guide.g9n9n.led.title",
            "connection.device_guide.g9n9n.limit.title",
        ])

        #expect(ConnectionDeviceUsageGuide.make(for: makeProfile(model: .unknown, customName: "Unknown")) == nil)
        #expect(ConnectionDeviceUsageGuide.make(for: makeProfile(model: .appleSiriRemoteA2854, customName: "Siri")) == nil)
        #expect(ConnectionDeviceUsageGuide.make(for: makeProfile(model: .appleSiriRemoteA2540, customName: "Siri")) == nil)
    }

    @Test @MainActor func allGuideKeysResolveInEnglishAndSimplifiedChinese() throws {
        let suite = "connection-guide-locale-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: AppSettings(defaults: defaults))

        let guides = [
            makeProfile(model: .rc001, customName: "Xiaomi 2"),
            makeProfile(model: .rc003, customName: "Xiaomi 2 Pro"),
            makeProfile(model: .t1Remote, customName: "T1"),
            makeProfile(model: .chromecastVoiceRemote, customName: "G9N9N", voiceButtonMode: .smartToggle),
            makeProfile(model: .chromecastVoiceRemote, customName: "G9N9N", voiceButtonMode: .holdToTalk),
        ].compactMap { ConnectionDeviceUsageGuide.make(for: $0) }

        var keys: Set<String> = ["connection.device_guide.title"]
        for guide in guides {
            if let badgeKey = guide.badgeKey {
                keys.insert(badgeKey)
            }
            for item in guide.items {
                keys.insert(item.titleKey)
                keys.insert(item.detailKey)
            }
        }

        for key in keys.sorted() {
            localization.select(.english)
            let english = localization.text(key)
            localization.select(.simplifiedChinese)
            let chinese = localization.text(key)
            #expect(!english.isEmpty && english != key)
            #expect(!chinese.isEmpty && chinese != key)
            #expect(english != chinese)
        }
    }

    @Test @MainActor func safetyLimitItemsFormatConfiguredMinutesInBothLanguages() throws {
        let suite = "connection-guide-duration-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: AppSettings(defaults: defaults))

        for profile in [
            makeProfile(model: .t1Remote, customName: "T1"),
            makeProfile(model: .chromecastVoiceRemote, customName: "G9N9N", voiceButtonMode: .smartToggle),
        ] {
            let guide = try #require(ConnectionDeviceUsageGuide.make(
                for: profile,
                voiceAutoStopDuration: .tenMinutes
            ))
            let itemsWithMinutes = guide.items.filter { $0.titleArguments == ["10"] && $0.detailArguments == ["10"] }
            #expect(itemsWithMinutes.count == 1)
            let item = try #require(itemsWithMinutes.first)

            localization.select(.english)
            let englishTitle = LocalizedMessage(item.titleKey, arguments: item.titleArguments).text(using: localization)
            let englishDetail = LocalizedMessage(item.detailKey, arguments: item.detailArguments).text(using: localization)
            #expect(englishTitle.contains("10"))
            #expect(englishDetail.contains("10"))

            localization.select(.simplifiedChinese)
            let chineseTitle = LocalizedMessage(item.titleKey, arguments: item.titleArguments).text(using: localization)
            let chineseDetail = LocalizedMessage(item.detailKey, arguments: item.detailArguments).text(using: localization)
            #expect(chineseTitle.contains("10"))
            #expect(chineseDetail.contains("10"))
        }
    }
}
