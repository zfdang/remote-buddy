import AppKit
import CoreAudio
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("System microphone menu")
@MainActor
struct SystemMicrophoneMenuTests {
    private final class DummyTarget: NSObject {
        @objc func selectMic(_ sender: NSMenuItem) {}
    }

    @Test func setDefaultInputDeviceWritesMatchedDeviceIDToSystemObject() {
        let devices = [
            AudioDeviceInfo(id: 42, uid: "built-in-mic", name: "MacBook Pro Microphone"),
            AudioDeviceInfo(id: 77, uid: "buddy-mic", name: "Remote Buddy Mic"),
        ]
        var writes: [(AudioObjectID, AudioObjectPropertySelector, AudioObjectPropertyScope, AudioDeviceID)] = []
        let writer: CoreAudioDevicePropertyWriter.Writer = { objectID, address, _, _, size, pointer in
            guard size == UInt32(MemoryLayout<AudioDeviceID>.size) else { return OSStatus(-1) }
            let value = pointer.assumingMemoryBound(to: AudioDeviceID.self).pointee
            writes.append((objectID, address.pointee.mSelector, address.pointee.mScope, value))
            return noErr
        }

        let updated = CoreAudioDeviceCatalog.setDefaultInputDevice(
            uid: "buddy-mic",
            availableInputDevices: { devices },
            isSettable: { _, _ in true },
            writer: writer
        )
        #expect(updated)
        #expect(writes.count == 1)
        #expect(writes[0].0 == AudioObjectID(kAudioObjectSystemObject))
        #expect(writes[0].1 == kAudioHardwarePropertyDefaultInputDevice)
        #expect(writes[0].2 == kAudioObjectPropertyScopeGlobal)
        #expect(writes[0].3 == 77)
    }

    @Test func setDefaultInputDeviceRejectsInvalidUnpluggedOrUnwritableTargets() {
        let devices = [
            AudioDeviceInfo(id: AudioDeviceID(kAudioObjectUnknown), uid: "unknown-id", name: "Broken"),
            AudioDeviceInfo(id: AudioDeviceID(kAudioObjectSystemObject), uid: "system-id", name: "System"),
            AudioDeviceInfo(id: 42, uid: "built-in-mic", name: "MacBook Pro Microphone"),
        ]
        var writeCount = 0
        let countingWriter: CoreAudioDevicePropertyWriter.Writer = { _, _, _, _, _, _ in
            writeCount += 1
            return noErr
        }

        #expect(!CoreAudioDeviceCatalog.setDefaultInputDevice(
            uid: "", availableInputDevices: { devices }, isSettable: { _, _ in true }, writer: countingWriter))
        #expect(!CoreAudioDeviceCatalog.setDefaultInputDevice(
            uid: "missing-uid", availableInputDevices: { devices }, isSettable: { _, _ in true }, writer: countingWriter))
        #expect(!CoreAudioDeviceCatalog.setDefaultInputDevice(
            uid: "unknown-id", availableInputDevices: { devices }, isSettable: { _, _ in true }, writer: countingWriter))
        #expect(!CoreAudioDeviceCatalog.setDefaultInputDevice(
            uid: "system-id", availableInputDevices: { devices }, isSettable: { _, _ in true }, writer: countingWriter))
        #expect(!CoreAudioDeviceCatalog.setDefaultInputDevice(
            uid: "built-in-mic", availableInputDevices: { devices }, isSettable: { _, _ in false }, writer: countingWriter))
        #expect(writeCount == 0)

        #expect(!CoreAudioDeviceCatalog.setDefaultInputDevice(
            uid: "built-in-mic",
            availableInputDevices: { devices },
            isSettable: { _, _ in true },
            writer: { _, _, _, _, _, _ in kAudioHardwareIllegalOperationError }
        ))
    }

    @Test func menuBuilderRendersDisabledEmptyItemWhenNoInputsExist() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Stale", action: nil, keyEquivalent: ""))

        SystemMicrophoneMenuBuilder.populate(
            menu,
            devices: [],
            defaultInputUID: nil,
            emptyTitle: "No Microphones Available",
            target: DummyTarget(),
            action: #selector(DummyTarget.selectMic(_:))
        )

        #expect(menu.items.count == 1)
        #expect(menu.items[0].title == "No Microphones Available")
        #expect(!menu.items[0].isEnabled)
    }

    @Test func menuBuilderPopulatesDevicesMarksDefaultAndReplacesOnRefresh() {
        let menu = NSMenu()
        let target = DummyTarget()
        let devices = [
            AudioDeviceInfo(id: 10, uid: "mic-1", name: "MacBook Pro Microphone"),
            AudioDeviceInfo(id: 20, uid: "mic-2", name: "Remote Buddy Mic"),
        ]

        SystemMicrophoneMenuBuilder.populate(
            menu,
            devices: devices,
            defaultInputUID: "mic-2",
            emptyTitle: "No Microphones Available",
            target: target,
            action: #selector(DummyTarget.selectMic(_:))
        )

        #expect(menu.items.map(\.title) == ["MacBook Pro Microphone", "Remote Buddy Mic"])
        #expect(menu.items.map { $0.representedObject as? String } == ["mic-1", "mic-2"])
        #expect(menu.items.map(\.state) == [.off, .on])
        #expect(menu.items.allSatisfy { $0.target === target && $0.action == #selector(DummyTarget.selectMic(_:)) })

        SystemMicrophoneMenuBuilder.populate(
            menu,
            devices: [devices[0]],
            defaultInputUID: "mic-1",
            emptyTitle: "No Microphones Available",
            target: target,
            action: #selector(DummyTarget.selectMic(_:))
        )

        #expect(menu.items.map(\.title) == ["MacBook Pro Microphone"])
        #expect(menu.items.map(\.state) == [.on])
    }

    @Test func statusMenuPlacesSystemMicrophoneDirectlyBelowOpenSettings() throws {
        let suite = "system-mic-menu-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: AppSettings(defaults: defaults))
        localization.select(.english)

        let target = DummyTarget()
        let built = RemoteBuddyAppDelegate.buildStatusMenu(
            connectionItem: NSMenuItem(title: "Status", action: nil, keyEquivalent: ""),
            localization: localization,
            target: target,
            delegate: nil,
            includesCheckForUpdates: true,
            canRestoreClipboard: false,
            supportItem: NSMenuItem(title: "Help & Support", action: nil, keyEquivalent: ""),
            versionItem: NSMenuItem(title: "Version 1.0", action: nil, keyEquivalent: "")
        )

        let titles = built.menu.items.map(\.title)
        let settingsIndex = try #require(titles.firstIndex(of: localization.text("menu.open_settings")))
        let microphoneIndex = settingsIndex + 1
        #expect(built.menu.items.indices.contains(microphoneIndex))
        let microphoneItem = built.menu.items[microphoneIndex]
        #expect(microphoneItem.title == localization.text("menu.system_microphone"))
        #expect(microphoneItem.submenu === built.systemMicrophoneSubmenu)
    }

    @Test func systemMicrophoneStringsResolveInBothLanguages() throws {
        let suite = "system-mic-l10n-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let localization = LocalizationStore(settings: AppSettings(defaults: defaults))

        for key in ["menu.system_microphone", "menu.system_microphone.none"] {
            localization.select(.english)
            #expect(localization.text(key) != key)
            localization.select(.simplifiedChinese)
            #expect(localization.text(key) != key)
        }
    }
}
