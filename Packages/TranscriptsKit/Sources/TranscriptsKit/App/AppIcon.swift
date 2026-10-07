import AppKit

/// The icons the app can wear in the Dock. The automatic one is the app's own: light or dark with the system,
/// and tinted or clear when macOS is set to show icons that way. The others show while the app runs.
public enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    case automatic, light, dark, indigo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic: String(localized: "Automatisch")
        case .light: String(localized: "Hell", comment: "app icon: light")
        case .dark: String(localized: "Dunkel", comment: "app icon: dark")
        case .indigo: String(localized: "Indigo", comment: "app icon color")
        }
    }

    /// The picture for Settings, rendered from the Icon Composer documents by Tools/render-icons.sh.
    public var image: NSImage? {
        Bundle.module.image(forResource: "icon-\(rawValue)")
    }

    /// Puts the icon in the Dock. The automatic one is the bundle's own; nil hands the Dock back to it.
    @MainActor
    public func apply() {
        NSApplication.shared.applicationIconImage = self == .automatic ? nil : image
    }
}
