import Foundation
import Testing
@testable import RemoteBuddy

@Suite("Remote device information")
struct RemoteDeviceInformationTests {
    @Test func missingReadingsDoNotAdvertiseDefaultIdentityOrAudio() {
        let information = RemoteDeviceInformation()
        #expect(information.modelNumber == nil)
        #expect(information.firmwareRevision == nil)
        #expect(information.identityValue == nil)
        #expect(information.hidVersionValue == nil)
        #expect(information.audioFormat == nil)
        #expect(information.protocolVersion == nil)
    }

    @Test func decodesOptionalBluetoothStringsWithoutPadding() {
        #expect(RemoteDeviceInformation.deviceString(Data(" RC003\0\r\n".utf8)) == "RC003")
        #expect(RemoteDeviceInformation.deviceString(Data("\0 \n".utf8)) == nil)
        #expect(RemoteDeviceInformation.deviceString(Data([0xFF])) == nil)
    }

    @Test func displaysReportedIdentityAndNegotiatedAudio() throws {
        let identity = try #require(RemoteHIDIdentity.fromPnP(Data([2, 0xD1, 0x18, 0x50, 0x94, 0, 0])))
        let capabilities = try #require(ATVVCapabilities.parse(Data([0x0B, 1, 0, 2, 3, 0, 120])))
        let information = RemoteDeviceInformation(identity: identity, capabilities: capabilities)
        #expect(information.identityValue == "18D1 / 9450")
        #expect(information.protocolVersion == "ATVV 1.0")
        #expect(information.capabilities?.frameSize == 120)
        #expect(information.audioFormat == "16 kHz · IMA ADPCM")
    }

    @Test func retainsActualEightKilohertzReading() throws {
        let capabilities = try #require(ATVVCapabilities.parse(Data([0x0B, 1, 0, 1, 3, 0, 134])))
        let information = RemoteDeviceInformation(capabilities: capabilities)
        #expect(information.audioFormat == "8 kHz · IMA ADPCM")
    }

    @Test @MainActor func readsAndFormatsPnPHIDVersionAcrossBatchesAndLocales() throws {
        let v0110 = Data([1, 0xD1, 0x18, 0x50, 0x94, 0x10, 0x01])
        let v011B = Data([2, 0xD1, 0x18, 0x50, 0x94, 0x1B, 0x01])
        let vZero = Data([2, 0xD1, 0x18, 0x50, 0x94, 0x00, 0x00])
        #expect(RemoteHIDIdentity.productVersionFromPnP(v0110) == 0x0110)
        #expect(RemoteHIDIdentity.productVersionFromPnP(v011B) == 0x011B)
        #expect(RemoteHIDIdentity.productVersionFromPnP(vZero) == nil)
        #expect(RemoteHIDIdentity.productVersionFromPnP(Data([1, 0xD1, 0x18])) == nil)

        let info0110 = RemoteDeviceInformation(
            identity: RemoteHIDIdentity.fromPnP(v0110),
            hidVersion: RemoteHIDIdentity.productVersionFromPnP(v0110)
        )
        let info011B = RemoteDeviceInformation(
            identity: RemoteHIDIdentity.fromPnP(v011B),
            hidVersion: RemoteHIDIdentity.productVersionFromPnP(v011B)
        )
        #expect(info0110.hidVersionValue == "0x0110")
        #expect(info011B.hidVersionValue == "0x011B")

        let suite = "device-info-locale-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: AppSettings(defaults: defaults))
        localization.select(.english)
        let english = localization.text("connection.device.hid_version")
        localization.select(.simplifiedChinese)
        let chinese = localization.text("connection.device.hid_version")
        #expect(english == "HID version")
        #expect(chinese == "HID 版本")

        let localizedInfo = RemoteDeviceInformation(
            modelNumber: "A0",
            firmwareRevision: "26.2",
            identity: RemoteHIDIdentity.fromPnP(v0110),
            hidVersion: 0x0110
        )
        localization.select(.english)
        #expect(
            localizedInfo.conciseHardwareSummary(using: localization)
                == "Model A0 · VID/PID 18D1/9450 · HID version 0x0110 · Firmware 26.2"
        )
        localization.select(.simplifiedChinese)
        #expect(
            localizedInfo.conciseHardwareSummary(using: localization)
                == "型号 A0 · VID/PID 18D1/9450 · HID 版本 0x0110 · 固件 26.2"
        )
        #expect(RemoteDeviceInformation().conciseHardwareSummary(using: localization) == nil)
    }

    @Test func formatsPnPLogFieldsAcrossBatchesAndMalformedPayloads() {
        let v0110 = Data([1, 0xD1, 0x18, 0x50, 0x94, 0x10, 0x01])
        let v011B = Data([2, 0xD1, 0x18, 0x50, 0x94, 0x1B, 0x01])
        let vZero = Data([2, 0xD1, 0x18, 0x50, 0x94, 0x00, 0x00])
        let malformed = Data([1, 0xD1, 0x18])

        #expect(RemoteHIDIdentity.parsePnPInfo(v0110) == RemoteHIDIdentity.PnPInfo(
            vendorIDSource: 1,
            identity: .chromecast,
            productVersion: 0x0110
        ))
        #expect(RemoteHIDIdentity.pnpLogFields(from: v0110) == "vendor_source=1 vid=18D1 pid=9450 hid_version=0x0110")
        #expect(RemoteHIDIdentity.pnpLogFields(from: v011B) == "vendor_source=2 vid=18D1 pid=9450 hid_version=0x011B")
        #expect(RemoteHIDIdentity.pnpLogFields(from: vZero) == "vendor_source=2 vid=18D1 pid=9450 hid_version=none")
        #expect(RemoteHIDIdentity.pnpLogFields(from: malformed) == "unreadable raw_bytes=3")
    }

    @Test func formatsFirmwareAndHardwareRevisionLogLinesSafely() {
        #expect(RemoteDeviceInformation.firmwareLogLine(from: Data("26.2\0".utf8)) == "BLE FIRMWARE observed firmwareRevision=26.2")
        #expect(RemoteDeviceInformation.hardwareLogLine(from: Data("PVT/MP\r\n".utf8)) == "BLE HARDWARE observed hardwareRevision=PVT/MP")
        #expect(RemoteDeviceInformation.hardwareLogLine(from: Data("CR PVT/MP".utf8)) == "BLE HARDWARE observed hardwareRevision=\"CR PVT/MP\"")
        #expect(RemoteDeviceInformation.firmwareLogLine(from: Data([0xFF, 0xFE])) == "BLE FIRMWARE unreadable bytes=2")
        #expect(RemoteDeviceInformation.hardwareLogLine(from: Data(" \0\n".utf8)) == "BLE HARDWARE unreadable bytes=3")
    }

    @Test func formatsHIDDeviceHardwareInfoLogFields() {
        let complete = HIDDeviceHardwareInfo(
            identity: .chromecast,
            versionNumber: 0x0110,
            maxInputReportSize: 3,
            reportDescriptorBytes: 57,
            indexedConsumerLayout: true,
            modelNumber: "A0",
            firmwareRevision: "26.2",
            hardwareRevision: "PVT/MP"
        )
        #expect(
            complete.logFields
                == "vid=18D1 pid=9450 hid_version=0x0110 max_input_bytes=3 descriptor_bytes=57 indexed_consumer=true model=A0 firmware=26.2 hardware=PVT/MP"
        )

        let spacedHardware = HIDDeviceHardwareInfo(
            identity: .chromecast,
            versionNumber: 0x0110,
            maxInputReportSize: 3,
            reportDescriptorBytes: 57,
            indexedConsumerLayout: true,
            modelNumber: "A0",
            firmwareRevision: "26.0",
            hardwareRevision: "CR PVT/MP"
        )
        #expect(
            spacedHardware.logFields
                == "vid=18D1 pid=9450 hid_version=0x0110 max_input_bytes=3 descriptor_bytes=57 indexed_consumer=true model=A0 firmware=26.0 hardware=\"CR PVT/MP\""
        )

        let empty = HIDDeviceHardwareInfo(
            identity: nil,
            versionNumber: nil,
            maxInputReportSize: nil,
            reportDescriptorBytes: nil,
            indexedConsumerLayout: nil,
            modelNumber: nil,
            firmwareRevision: nil,
            hardwareRevision: nil
        )
        #expect(empty.logFields.isEmpty)
    }
}
