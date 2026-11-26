import AppKit
import Combine

/// Presentation only: a connection is not proof that audio or input permissions are ready.
enum StatusItemPresentation: String, Equatable {
    case disconnected
    case connected
    case preparing
    case streaming

    var descriptionKey: String { "status_item.state.\(rawValue)" }

    static func resolve(physicalConnected: Bool, isStreaming: Bool, isPreparing: Bool = false) -> Self {
        guard physicalConnected else { return .disconnected }
        return isStreaming ? .streaming : (isPreparing ? .preparing : .connected)
    }

    @MainActor
    static func publisher(model: BridgeAppModel) -> AnyPublisher<Self, Never> {
        publisher(physicalConnected: model.$isConnected.eraseToAnyPublisher(),
            isStreaming: model.$isStreaming.eraseToAnyPublisher(),
            isPreparing: model.$applicationIntegrationStatus.map { $0?.isPreparingVoiceInput == true }.eraseToAnyPublisher())
    }

    static func publisher(physicalConnected: AnyPublisher<Bool, Never>,
                          isStreaming: AnyPublisher<Bool, Never>,
                          isPreparing: AnyPublisher<Bool, Never> = Just(false).eraseToAnyPublisher()) -> AnyPublisher<Self, Never> {
        physicalConnected.combineLatest(isStreaming, isPreparing)
            .map { resolve(physicalConnected: $0, isStreaming: $1, isPreparing: $2) }
            .removeDuplicates().eraseToAnyPublisher()
    }

    @MainActor
    func apply(to button: NSStatusBarButton, description: String) {
        let image: NSImage?
        if self == .streaming {
            image = Self.streamingStatusImage(description: description)
        } else {
            let resourceName: String? = self == .preparing ? nil : "StatusIconTemplate"
            let fallbackSymbol = self == .preparing ? "hourglass" : "mic"
            // Named images are shared. Keep localized descriptions local to this status item.
            let loaded = resourceName.flatMap { Self.loadStatusArtwork(named: $0) }
                ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: description)
            // Let macOS tint the monochrome artwork for light and dark menu bars.
            loaded?.isTemplate = true
            loaded?.size = NSSize(width: 22, height: 22)
            image = loaded
        }
        image?.accessibilityDescription = description
        button.image = image
        button.title = image == nil ? description : ""
        button.appearsDisabled = self == .disconnected
        button.toolTip = description
        button.setAccessibilityLabel(description)
    }

    private static func loadStatusArtwork(named resourceName: String) -> NSImage? {
        if let named = NSImage(named: NSImage.Name(resourceName))?.copy() as? NSImage {
            return named
        }
        if let url = RemoteBuddyResourceBundle.mainOrDevelopment.url(
            forResource: resourceName,
            withExtension: "png"
        ), let loaded = NSImage(contentsOf: url) {
            return loaded
        }
        return nil
    }

    @MainActor
    private static func streamingStatusImage(description: String) -> NSImage? {
        let baseArtwork = loadStatusArtwork(named: "StatusIconTemplate")
            ?? NSImage(systemSymbolName: "mic.fill", accessibilityDescription: description)
        guard let baseArtwork else { return nil }
        let canvasSize = NSSize(width: 22, height: 22)
        let rendered = NSImage(size: canvasSize, flipped: false) { rect in
            // Render the base silhouette using the active menu bar appearance so light/dark contrast
            // stays crisp, then overlay an untinted system-red dot as a live recording indicator.
            if let context = NSGraphicsContext.current?.cgContext {
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                baseArtwork.draw(in: rect)
                NSColor.labelColor.setFill()
                rect.fill(using: .sourceAtop)
                context.endTransparencyLayer()
            } else {
                baseArtwork.draw(in: rect)
            }
            let dotRect = NSRect(x: 16.65, y: 17.5, width: 4.0, height: 4.0)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        rendered.isTemplate = false
        return rendered
    }
}
