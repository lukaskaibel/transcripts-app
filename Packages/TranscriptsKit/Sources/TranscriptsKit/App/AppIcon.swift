import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The icons the app can wear. The automatic one is the app's own: light or dark with the system, and tinted or
/// clear when the system is set to show icons that way. On the Mac the others show in the Dock while the app runs;
/// on iPhone and iPad they are alternate icons on the Home Screen.
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
    var image: PlatformImage? {
        #if os(macOS)
        Bundle.module.image(forResource: "icon-\(rawValue)")
        #else
        UIImage(named: "icon-\(rawValue)", in: .module, with: nil)
        #endif
    }

    /// Name of the alternate icon in the app bundle on iPhone and iPad; nil is the app's own icon.
    var alternateIconName: String? {
        switch self {
        case .automatic: nil
        case .light: "AppIcon-Light"
        case .dark: "AppIcon-Dark"
        case .indigo: "AppIcon-Indigo"
        }
    }

    /// Puts the icon in the Dock or on the Home Screen. The automatic one is the bundle's own.
    @MainActor
    public func apply() {
        #if os(macOS)
        // Nil hands the Dock back to the bundle's icon.
        NSApplication.shared.applicationIconImage = self == .automatic ? nil : image
        #else
        // iOS shows an alert of its own whenever the icon changes, so only ask when it really differs.
        guard UIApplication.shared.supportsAlternateIcons,
              UIApplication.shared.alternateIconName != alternateIconName else { return }
        UIApplication.shared.setAlternateIconName(alternateIconName)
        #endif
    }
}
