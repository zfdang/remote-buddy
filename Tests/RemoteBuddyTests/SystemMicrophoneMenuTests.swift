import AppKit
import CoreAudio
import Foundation
import Testing
@testable import RemoteBuddy

@Suite("System microphone menu")
@MainActor
struct SystemMicrophoneMenuTests {
    private final class DummyTarget: NSObject, NSMenuDelegate {
        @objc func selectMic(_ sender: NSMenuItem) {}
    }

    private let noteTitle = "Usually unchanged—select the mic in your voice tool\nChanges here affect all apps"

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
            noteTitle: noteTitle,
            emptyTitle: "No Microphones Available",
            target: DummyTarget(),
            action: #selector(DummyTarget.selectMic(_:))
        )

        #expect(menu.items.count == 3)
        #expect(menu.items[0].title == noteTitle)
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[0].action == nil)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "No Microphones Available")
        #expect(!menu.items[2].isEnabled)
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
            noteTitle: noteTitle,
            emptyTitle: "No Microphones Available",
            target: target,
            action: #selector(DummyTarget.selectMic(_:))
        )

        #expect(menu.items.count == 4)
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[0].action == nil)
        #expect(menu.items[1].isSeparatorItem)
        let deviceItems = Array(menu.items.dropFirst(2))
        #expect(deviceItems.map(\.title) == ["MacBook Pro Microphone", "Remote Buddy Mic"])
        #expect(deviceItems.map { $0.representedObject as? String } == ["mic-1", "mic-2"])
        #expect(deviceItems.map(\.state) == [.off, .on])
        #expect(deviceItems.allSatisfy { $0.target === target && $0.action == #selector(DummyTarget.selectMic(_:)) })

        SystemMicrophoneMenuBuilder.populate(
            menu,
            devices: [devices[0]],
            defaultInputUID: "mic-1",
            noteTitle: noteTitle,
            emptyTitle: "No Microphones Available",
            target: target,
            action: #selector(DummyTarget.selectMic(_:))
        )

        #expect(menu.items.count == 3)
        #expect(!menu.items[0].isEnabled)
        #expect(menu.items[1].isSeparatorItem)
        let refreshedItems = Array(menu.items.dropFirst(2))
        #expect(refreshedItems.map(\.title) == ["MacBook Pro Microphone"])
        #expect(refreshedItems.map(\.state) == [.on])
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
            delegate: target,
            includesCheckForUpdates: true,
            canRestoreClipboard: false,
            supportItem: NSMenuItem(title: "Help & Support", action: nil, keyEquivalent: ""),
            versionItem: NSMenuItem(title: "Version 1.0", action: nil, keyEquivalent: "")
        )

        #expect(built.menu.delegate === target)
        #expect(built.systemMicrophoneSubmenu.delegate === target)
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

        for key in ["menu.system_microphone", "menu.system_microphone.note", "menu.system_microphone.none"] {
            localization.select(.english)
            #expect(localization.text(key) != key)
            localization.select(.simplifiedChinese)
            #expect(localization.text(key) != key)
        }
    }

    @Test func defaultInputFilterExcludesNonDefaultableHiddenDeadAndAggregateDevices() {
        let builtIn = AudioDeviceInfo(id: 93, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
        let buddy = AudioDeviceInfo(id: 98, uid: "BuddyMic2ch_UID", name: "Remote Buddy Mic")
        let teams = AudioDeviceInfo(id: 53, uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio")
        let aggregate = AudioDeviceInfo(id: 120, uid: "CADefaultDeviceAggregate-123", name: "Aggregate")

        #expect(CoreAudioDeviceCatalog.shouldPresentAsDefaultInputDevice(
            builtIn, isAlive: true, isHidden: false, canBeDefaultInput: true))
        #expect(CoreAudioDeviceCatalog.shouldPresentAsDefaultInputDevice(
            buddy, isAlive: nil, isHidden: nil, canBeDefaultInput: nil))
        #expect(!CoreAudioDeviceCatalog.shouldPresentAsDefaultInputDevice(
            teams, isAlive: true, isHidden: false, canBeDefaultInput: false))
        #expect(!CoreAudioDeviceCatalog.shouldPresentAsDefaultInputDevice(
            builtIn, isAlive: true, isHidden: true, canBeDefaultInput: true))
        #expect(!CoreAudioDeviceCatalog.shouldPresentAsDefaultInputDevice(
            builtIn, isAlive: false, isHidden: false, canBeDefaultInput: true))
        #expect(!CoreAudioDeviceCatalog.shouldPresentAsDefaultInputDevice(
            aggregate, isAlive: true, isHidden: false, canBeDefaultInput: true))
    }
}
