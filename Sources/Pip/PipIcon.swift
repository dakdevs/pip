import AppKit
import SwiftUI

/// Selected Hugeicons vectors exported from the user's Swift asset download.
enum PipIconName: String, CaseIterable {
    case menuBar = "ai-chat-01"
    case pip = "sparkles", working = "ai-brain-01", unread = "ai-search"
    case attention = "notification-bubble", compose = "pencil-edit-01"
    case collapse = "arrow-down-right-01", warning = "a-alert-circle"
    case voice = "audio-wave-01", send = "arrow-up-02", check = "tick-02"
    case fast = "flash", slow = "flash-off", stop = "stop-circle", close = "cancel-01"
    case settings = "settings-04", keyboard, tools = "puzzle"
    case question = "message-01", permission = "waving-hand-01"
    case selected = "checkmark-circle-02", unselected = "circle"

    private static var resourceBundle: Bundle {
        // SwiftPM's accessor only covers command-line builds; packaged apps
        // place resources under Contents/Resources.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Pip_Pip.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
    }

    @MainActor private static var cache: [Self: NSImage] = [:]

    @MainActor func image(size: CGFloat = 18) -> NSImage {
        let original: NSImage
        if let cached = Self.cache[self] { original = cached }
        else {
            guard let url = Self.resourceBundle.url(forResource: rawValue, withExtension: "svg"),
                  let data = try? Data(contentsOf: url), let loaded = NSImage(data: data) else {
                assertionFailure("Missing Hugeicons asset: \(rawValue)")
                return NSImage(size: NSSize(width: size, height: size))
            }
            loaded.isTemplate = true
            Self.cache[self] = loaded
            original = loaded
        }
        let result = original.copy() as! NSImage
        result.size = NSSize(width: size, height: size)
        return result
    }
}

struct PipIcon: View {
    let name: PipIconName
    var size: CGFloat = 16
    init(_ name: PipIconName, size: CGFloat = 16) { self.name = name; self.size = size }
    var body: some View {
        Image(nsImage: name.image(size: size))
            .resizable().renderingMode(.template).interpolation(.high)
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct PipLabel: View {
    let title: String
    let icon: PipIconName
    init(_ title: String, icon: PipIconName) { self.title = title; self.icon = icon }
    var body: some View { Label { Text(title) } icon: { PipIcon(icon) } }
}
