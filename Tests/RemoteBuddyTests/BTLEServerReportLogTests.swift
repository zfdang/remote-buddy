import Foundation
import Testing
@testable import RemoteBuddy

@Suite("BTLEServer report log")
struct BTLEServerReportLogTests {
    private let remote = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let secondRemote = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    private let keyboard = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    private func indication(_ id: UUID, at time: TimeInterval, kind: String = "indication") -> BTLEServerReportLog.Line {
        BTLEServerReportLog.parse(
            message: "Dispatching GATT \(kind) for device \"\(id.uuidString)\" to session \"com.apple.BTLEServer-central-634-17\"",
            timestamp: time
        )!
    }

    private func report(_ text: String, at time: TimeInterval) -> BTLEServerReportLog.Line {
        BTLEServerReportLog.parse(message: "Updated input report for ID #\(text)", timestamp: time)!
    }

    @Test func parsesTwoByteConsumerAndOneByteIndexedReports() {
        let twoByte = BTLEServerReportLog.parse(
            message: "Updated input report for ID #2: {length = 2, bytes = 0x4200}", timestamp: 1
        )
        #expect(twoByte == .report(.init(reportID: 2, data: Data([0x42, 0x00])), timestamp: 1))

        let oneByte = BTLEServerReportLog.parse(
            message: "Updated input report for ID #1: {length = 1, bytes = 0x03}", timestamp: 2
        )
        #expect(oneByte == .report(.init(reportID: 1, data: Data([0x03])), timestamp: 2))
    }

    @Test func redactedPayloadAndNotificationLinesParseProperly() {
        #expect(
            BTLEServerReportLog.parse(message: "Updated input report for ID #2: <private>", timestamp: 1)
                == .redactedReport(reportID: 2, timestamp: 1)
        )
        #expect(
            BTLEServerReportLog.parse(
                message: "Dispatching GATT notification for device \"\(remote.uuidString)\" to session \"com.apple.BTLEServer-central-1\"",
                timestamp: 3
            ) == .indication(peripheral: remote, timestamp: 3)
        )
    }

    @Test func abbreviatedPayloadIsIgnored() {
        #expect(
            BTLEServerReportLog.parse(
                message: "Updated input report for ID #1: {length = 20, bytes = 0x00000000 ... 00000000}",
                timestamp: 1
            ) == nil
        )
    }

    @Test func parsesNdjsonTimestamp() {
        let line = #"{"timestamp":"2026-11-18 23:39:30.485000+0800","eventMessage":"Updated input report for ID #2: {length = 2, bytes = 0x2402}"}"#
        guard case let .report(parsed, time)? = BTLEServerReportLog.parse(ndjsonLine: line) else {
            Issue.record("not parsed")
            return
        }
        #expect(parsed == .init(reportID: 2, data: Data([0x24, 0x02])))
        #expect(abs(time - 1_795_016_370.485) < 0.001)
    }

    @Test func forwardsOnlyReportsAttributedToConfiguredRemotesAndIsolatesMultipleRemotes() {
        var attributor = BTLEServerReportLog.Attributor()
        #expect(attributor.accept(indication(remote, at: 10.000), peripherals: [remote, secondRemote]) == nil)
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x4500}", at: 10.007), peripherals: [remote, secondRemote])
                == .report(.init(peripheral: remote, reportID: 2, data: Data([0x45, 0x00])))
        )

        _ = attributor.accept(indication(secondRemote, at: 10.500, kind: "notification"), peripherals: [remote, secondRemote])
        #expect(
            attributor.accept(report("1: {length = 1, bytes = 0x03}", at: 10.508), peripherals: [remote, secondRemote])
                == .report(.init(peripheral: secondRemote, reportID: 1, data: Data([0x03])))
        )

        _ = attributor.accept(indication(keyboard, at: 11.000), peripherals: [remote, secondRemote])
        #expect(attributor.accept(report("2: {length = 2, bytes = 0xe900}", at: 11.004), peripherals: [remote, secondRemote]) == nil)
    }

    @Test func releaseWithoutItsOwnIndicationReachesRemoteForReport2AndShortenedReport1Chords() {
        var attributor = BTLEServerReportLog.Attributor()
        // Report 2 (0x011B): 2-byte press -> 2-byte zero release without dispatch.
        _ = attributor.accept(indication(remote, at: 44.844), peripherals: [remote])
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x4200}", at: 44.890), peripherals: [remote])
                == .report(.init(peripheral: remote, reportID: 2, data: Data([0x42, 0x00])))
        )
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x0000}", at: 44.989), peripherals: [remote])
                == .report(.init(peripheral: remote, reportID: 2, data: Data([0x00, 0x00])))
        )
        #expect(attributor.accept(report("2: {length = 2, bytes = 0x0000}", at: 45.5), peripherals: [remote]) == nil)

        // Report 1 (FW 26.7): 2-byte chord press -> 1-byte 0x00 release without dispatch.
        _ = attributor.accept(indication(remote, at: 50.000), peripherals: [remote])
        #expect(
            attributor.accept(report("1: {length = 2, bytes = 0x030b}", at: 50.010), peripherals: [remote])
                == .report(.init(peripheral: remote, reportID: 1, data: Data([0x03, 0x0B])))
        )
        #expect(
            attributor.accept(report("1: {length = 1, bytes = 0x00}", at: 50.120), peripherals: [remote])
                == .report(.init(peripheral: remote, reportID: 1, data: Data([0x00])))
        )
        #expect(attributor.accept(report("1: {length = 1, bytes = 0x00}", at: 50.250), peripherals: [remote]) == nil)
    }

    @Test func keyboardZeroReportDoesNotReleaseTheRemoteAndTaintsDispatchlessFallback() {
        var attributor = BTLEServerReportLog.Attributor()
        _ = attributor.accept(indication(remote, at: 1.0), peripherals: [remote])
        _ = attributor.accept(report("2: {length = 2, bytes = 0x4300}", at: 1.01), peripherals: [remote])
        _ = attributor.accept(indication(keyboard, at: 1.5), peripherals: [remote])
        #expect(
            attributor.accept(report("1: {length = 8, bytes = 0x0000000000000000}", at: 1.51), peripherals: [remote])
                == nil
        )
        // A dispatch-less release after an intervening peripheral indication is ambiguous and must drop.
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x0000}", at: 1.6), peripherals: [remote])
                == nil
        )
        // A release accompanied by the remote's own dispatch line still succeeds.
        _ = attributor.accept(indication(remote, at: 1.9), peripherals: [remote])
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x0000}", at: 1.91), peripherals: [remote])
                == .report(.init(peripheral: remote, reportID: 2, data: Data([0x00, 0x00])))
        )
    }

    @Test func interleavedIndicationsAndMultipleHeldRemotesAreDroppedWhenAmbiguous() {
        var attributor = BTLEServerReportLog.Attributor()

        // Interleaved keyboard + remote indications within attributionWindow -> drop ambiguous report.
        _ = attributor.accept(indication(remote, at: 10.00), peripherals: [remote, secondRemote])
        _ = attributor.accept(indication(keyboard, at: 10.02), peripherals: [remote, secondRemote])
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x4200}", at: 10.03), peripherals: [remote, secondRemote])
                == nil
        )

        // Interleaved indications from two configured G9N9N remotes -> drop instead of guessing.
        _ = attributor.accept(indication(remote, at: 11.00), peripherals: [remote, secondRemote])
        _ = attributor.accept(indication(secondRemote, at: 11.03), peripherals: [remote, secondRemote])
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x4300}", at: 11.04), peripherals: [remote, secondRemote])
                == nil
        )

        // Two simultaneously held remotes -> dispatch-less zero release must never pick most recently held.
        _ = attributor.accept(indication(remote, at: 20.00), peripherals: [remote, secondRemote])
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x4200}", at: 20.01), peripherals: [remote, secondRemote])
                == .report(.init(peripheral: remote, reportID: 2, data: Data([0x42, 0x00])))
        )
        _ = attributor.accept(indication(secondRemote, at: 20.50), peripherals: [remote, secondRemote])
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x4300}", at: 20.51), peripherals: [remote, secondRemote])
                == .report(.init(peripheral: secondRemote, reportID: 2, data: Data([0x43, 0x00])))
        )
        #expect(
            attributor.accept(report("2: {length = 2, bytes = 0x0000}", at: 20.60), peripherals: [remote, secondRemote])
                == nil
        )
    }

    @Test func staleIndicationAndSinglePressPerIndicationAreEnforced() {
        var attributor = BTLEServerReportLog.Attributor()
        _ = attributor.accept(indication(remote, at: 10.0), peripherals: [remote])
        #expect(attributor.accept(report("2: {length = 2, bytes = 0x4200}", at: 10.5), peripherals: [remote]) == nil)

        _ = attributor.accept(indication(remote, at: 20.0), peripherals: [remote])
        #expect(attributor.accept(report("2: {length = 2, bytes = 0x4200}", at: 20.005), peripherals: [remote]) != nil)
        #expect(attributor.accept(report("2: {length = 2, bytes = 0x4300}", at: 20.010), peripherals: [remote]) == nil)
    }

    @Test func redactedReportsSignalMissingProfileWhenTargetPeripheralsExist() {
        var attributor = BTLEServerReportLog.Attributor()
        let line = BTLEServerReportLog.parse(message: "Updated input report for ID #2: <private>", timestamp: 1)!
        #expect(attributor.accept(line, peripherals: []) == nil)
        #expect(attributor.accept(line, peripherals: [remote]) == .redacted(.init(peripheral: nil, reportID: 2)))

        _ = attributor.accept(indication(keyboard, at: 2.0), peripherals: [remote])
        let keyboardRedacted = BTLEServerReportLog.parse(
            message: "Updated input report for ID #2: <private>", timestamp: 2.01
        )!
        #expect(attributor.accept(keyboardRedacted, peripherals: [remote]) == nil)
    }

    @Test func recoveredReportsDecodeAll14ButtonsForBothReport2AndShortenedReport1() {
        let report2Cases: [(UInt8, UInt8, RemoteButton)] = [
            (0x42, 0x00, .up), (0x43, 0x00, .down), (0x44, 0x00, .left), (0x45, 0x00, .right),
            (0x41, 0x00, .ok), (0x24, 0x02, .back), (0x23, 0x02, .home), (0xE2, 0x00, .mute),
            (0x77, 0x00, .youtube), (0x78, 0x00, .netflix), (0x9E, 0x01, .power), (0x89, 0x01, .input),
            (0xE9, 0x00, .volumeUp), (0xEA, 0x00, .volumeDown),
        ]
        for (low, high, button) in report2Cases {
            #expect(G9N9NProtocol.usages(reportID: 2, data: Data([low, high]), payloadOnly: true) == [button.hidUsage])
        }
        #expect(G9N9NProtocol.usages(reportID: 2, data: Data([0, 0]), payloadOnly: true) == [])

        let report1Cases: [(UInt8, RemoteButton)] = [
            (1, .power), (3, .up), (4, .down), (5, .left), (6, .right),
            (7, .ok), (8, .mute), (10, .home), (11, .back),
            (12, .volumeUp), (13, .volumeDown), (14, .youtube), (15, .netflix), (17, .input),
        ]
        let descriptor = G9N9NProtocol.indexedConsumerDescriptor
        for (index, button) in report1Cases {
            #expect(
                G9N9NProtocol.usages(reportID: 1, data: Data([index]), descriptor: descriptor, payloadOnly: true)
                    == [button.hidUsage]
            )
        }
        #expect(G9N9NProtocol.usages(reportID: 1, data: Data([0]), descriptor: descriptor, payloadOnly: true) == [])
        #expect(
            G9N9NProtocol.usages(reportID: 1, data: Data([0x03, 0x0B]), descriptor: descriptor, payloadOnly: true)
                == [RemoteButton.up.hidUsage, RemoteButton.back.hidUsage]
        )
    }

    @Test func profileServiceParsesBluetoothScopedAndUnrelatedProfiles() {
        let scopedXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>_computerlevel</key>
            <array>
                <dict>
                    <key>ProfileIdentifier</key>
                    <string>com.zfdang.remote-buddy.g9n9n-bluetooth-logging</string>
                    <key>ProfileItems</key>
                    <array>
                        <dict>
                            <key>PayloadType</key>
                            <string>com.apple.system.logging</string>
                            <key>PayloadContent</key>
                            <dict>
                                <key>Subsystems</key>
                                <dict>
                                    <key>com.apple.bluetooth</key>
                                    <dict>
                                        <key>DEFAULT-OPTIONS</key>
                                        <dict>
                                            <key>Enable-Private-Data</key>
                                            <true/>
                                        </dict>
                                    </dict>
                                </dict>
                            </dict>
                        </dict>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """.data(using: .utf8)!
        #expect(BluetoothLoggingProfileService.isBluetoothPrivateLoggingInstalled(profilesXMLData: scopedXML))

        let unrelatedComputerLevelXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>_computerlevel</key>
            <array>
                <dict>
                    <key>ProfileItems</key>
                    <array>
                        <dict>
                            <key>PayloadType</key>
                            <string>com.apple.applicationaccess</string>
                            <key>PayloadContent</key>
                            <dict/>
                        </dict>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """.data(using: .utf8)!
        let userOnlyXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>zfdang</key>
            <array/>
        </dict>
        </plist>
        """.data(using: .utf8)!
        #expect(BluetoothLoggingProfileService.status(fromProfilesXMLData: scopedXML) == .installed)
        #expect(BluetoothLoggingProfileService.status(fromProfilesXMLData: unrelatedComputerLevelXML) == .notInstalled)
        // Non-root `profiles list` omits `_computerlevel`; absence of a system profile from user scope stays `.unknown`.
        #expect(BluetoothLoggingProfileService.status(fromProfilesXMLData: userOnlyXML) == .unknown)
        #expect(BluetoothLoggingProfileService.status(fromProfilesXMLData: Data()) == .unknown)
        #expect(!BluetoothLoggingProfileService.isBluetoothPrivateLoggingInstalled(profilesXMLData: unrelatedComputerLevelXML))
        #expect(!BluetoothLoggingProfileService.isBluetoothPrivateLoggingInstalled(profilesXMLData: userOnlyXML))
        #expect(!BluetoothLoggingProfileService.isBluetoothPrivateLoggingInstalled(profilesXMLData: Data()))
    }

    @Test func bundledMobileconfigResourceIsValidAndScopedOnlyToBluetooth() throws {
        let url = try #require(BluetoothLoggingProfileService.bundledProfileURL())
        let data = try Data(contentsOf: url)
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
        #expect((plist["PayloadType"] as? String) == "Configuration")
        #expect((plist["PayloadRemovalDisallowed"] as? Bool) == false)
        let items = try #require(plist["PayloadContent"] as? [[String: Any]])
        let logging = try #require(items.first { ($0["PayloadType"] as? String) == "com.apple.system.logging" })
        #expect((logging["System"] as? [String: Any])?["Enable-Private-Data"] as? Bool != true)
        let bluetooth = try #require((logging["Subsystems"] as? [String: Any])?["com.apple.bluetooth"] as? [String: Any])
        let defaults = try #require(bluetooth["DEFAULT-OPTIONS"] as? [String: Any])
        #expect((defaults["Enable-Private-Data"] as? Bool) == true)
    }
}
