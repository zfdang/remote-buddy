import AppKit
import Combine
import Testing
@testable import RemoteBuddy

@Suite("Menu bar presentation")
struct StatusItemPresentationTests {
    @Test @MainActor func connectionStatesUseSystemTintAndDisconnectedAppearance() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        for (state, disabled) in [(StatusItemPresentation.disconnected, true), (.connected, false), (.preparing, false), (.streaming, false)] {
            state.apply(to: button, description: state.rawValue)
            #expect(button.image?.isTemplate == (state != .streaming))
            #expect(button.image?.size == NSSize(width: 22, height: 22))
            #expect(button.appearsDisabled == disabled)
        }
        #expect(StatusItemPresentation.resolve(physicalConnected: true, isStreaming: false) == .connected)
    }

    @Test func preparingIsVisibleBeforeStreamingAndClearsOnCancellation() {
        let connected = CurrentValueSubject<Bool, Never>(true)
        let streaming = CurrentValueSubject<Bool, Never>(false)
        let preparing = CurrentValueSubject<Bool, Never>(false)
        var states: [StatusItemPresentation] = []
        let subscription = StatusItemPresentation.publisher(
            physicalConnected: connected.eraseToAnyPublisher(), isStreaming: streaming.eraseToAnyPublisher(),
            isPreparing: preparing.eraseToAnyPublisher()).sink { states.append($0) }
        defer { subscription.cancel() }
        preparing.send(true)
        #expect(states.last == .preparing)
        streaming.send(true)
        preparing.send(false)
        streaming.send(false)
        preparing.send(true)
        preparing.send(false)
        connected.send(false)
        #expect(states == [.connected, .preparing, .streaming, .connected, .preparing, .connected, .disconnected])
    }
    @Test @MainActor func modelPreparationRemainsVisibleThroughReadinessAndCancellation() throws {
        let suite = "status-preparation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setApplicationIntegration(.chatGPT, enabled: true)
        let model = BridgeAppModel(settings: settings)
        model.isConnected = true
        var focusDone: ((ApplicationFocusResult) -> Void)?
        let controller = ApplicationIntegrationController(settings: settings,
            frontmost: { ("com.openai.codex", 42) }, focus: { _, _, done in
                focusDone = done; return ScheduledOperation {}
            }, onStateChange: { model.recordApplicationIntegrationStatus($0) })
        var states: [StatusItemPresentation] = []
        let subscription = StatusItemPresentation.publisher(model: model).sink { states.append($0) }
        defer { subscription.cancel(); controller.stop() }
        controller.start()
        _ = controller.prepareForVoiceInput { _ in }
        #expect(states.last == .preparing)
        let complete = try #require(focusDone)
        complete(.preserved)
        #expect(states.last == .preparing)
        #expect(states == [.connected, .preparing])
        model.recordApplicationIntegrationStatus(.cancelled(.superseded))
        #expect(states.last == .connected)
        _ = controller.prepareForVoiceInput { _ in }
        controller.cancelPending(reason: .targetChanged)
        #expect(states.last == .connected)
        model.recordApplicationIntegrationStatus(.waiting)
        model.isConnected = false
        #expect(states.last == .disconnected)
        model.isStreaming = true
        #expect(states.last == .disconnected)
    }

    @Test @MainActor func preparingArtworkDiffersFromStreamingArtwork() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        StatusItemPresentation.preparing.apply(to: button, description: "Preparing")
        let preparing = try #require(button.image?.tiffRepresentation)
        StatusItemPresentation.streaming.apply(to: button, description: "Streaming")
        #expect(preparing != button.image?.tiffRepresentation)
    }

    @Test @MainActor func releaseDuringInputSourceWaitClearsTheRealModelPreparation() throws {
        let suite = "status-source-wait-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.setApplicationIntegration(.chatGPT, enabled: true)
        let model = BridgeAppModel(settings: settings)
        model.isConnected = true
        var focusDone: ((ApplicationFocusResult) -> Void)?
        var sourceDone: ((Bool) -> Void)?
        var edges: [Bool] = []
        let controller = ApplicationIntegrationController(settings: settings,
            frontmost: { ("com.openai.codex", 42) }, focus: { _, _, done in
                focusDone = done; return ScheduledOperation {}
            }, onStateChange: { model.recordApplicationIntegrationStatus($0) })
        model.applicationIntegrationController = controller
        model.preferredInputSourceMonitor = PreferredInputSourceMonitor(
            voiceTool: { .weixin }, prepareInputSource: { _ in .selected },
            currentInputSourceID: { "before" }, restoreInputSource: { _ in .selected },
            waitForInputSourceActivation: { _, _, _, done in sourceDone = done },
            installMonitor: { _ in nil }, logger: { _ in })
        var state: StatusItemPresentation?
        let subscription = StatusItemPresentation.publisher(model: model).sink { state = $0 }
        defer { subscription.cancel(); controller.stop() }
        controller.start()
        #expect(model.updateVoiceKeyState(streaming: true, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in edges.append(down); return true }))
        let focus = try #require(focusDone)
        focus(.preserved)
        let source = try #require(sourceDone)
        #expect(state == .preparing)
        #expect(model.updateVoiceKeyState(streaming: false, forceSoftware: true, owner: .bluetooth,
            keySetter: { _, down in edges.append(down); return true }))
        #expect(state == .connected)
        source(true)
        #expect(edges.isEmpty)
        #expect(state == .connected)
    }

    @Test @MainActor func streamingArtworkRendersColoredRecordingDotWhilePreservingBaseGlyph() throws {
        _ = NSApplication.shared
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)

        func redPixelCount(in image: NSImage) -> Int {
            let width = 44
            let height = 44
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return 0 }
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
            }
            NSGraphicsContext.restoreGraphicsState()
            var count = 0
            for y in 0..<height {
                for x in 0..<width {
                    guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.alphaComponent > 0.5 && color.redComponent > 0.7 && color.greenComponent < 0.4 && color.blueComponent < 0.4 {
                        count += 1
                    }
                }
            }
            return count
        }

        StatusItemPresentation.connected.apply(to: button, description: "Connected")
        let connectedImage = try #require(button.image)
        #expect(redPixelCount(in: connectedImage) == 0)

        StatusItemPresentation.streaming.apply(to: button, description: "Streaming")
        let streamingImage = try #require(button.image)
        #expect(!streamingImage.isTemplate)
        #expect(redPixelCount(in: streamingImage) > 20)
    }

}
