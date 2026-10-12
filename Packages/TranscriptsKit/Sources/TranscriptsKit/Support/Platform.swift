import SwiftUI
#if os(macOS)
import AppKit

typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#else
import UIKit

typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

/// The few things AppKit and UIKit spell differently, so shared code can stay free of `#if` (as in Issues for GitHub).
enum Platform {
    /// Opens a link in the default browser (or the app that handles it).
    @MainActor
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    @MainActor
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    /// "iPhone", "iPad" or "Mac", for texts that name the device (a product name, the same in every language).
    @MainActor
    static var deviceName: String {
        #if os(iOS)
        UIDevice.current.model
        #else
        "Mac"
        #endif
    }

    /// True on an iPhone or iPad; the Mac has a pointer, menus and windows instead.
    static var isMobile: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
}

extension PlatformColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    #if os(iOS)
    convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
    #endif

    /// A colour that is worked out again whenever the appearance changes.
    static func dynamic(_ provider: @escaping @Sendable (_ isDark: Bool) -> PlatformColor) -> PlatformColor {
        #if os(macOS)
        NSColor(name: nil) { appearance in
            provider(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
        #else
        UIColor { traits in provider(traits.userInterfaceStyle == .dark) }
        #endif
    }

}

extension CGColor {
    /// Red, green and blue in sRGB, for colours that come from the system (a calendar's colour).
    var srgbComponents: [Double]? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let color = converted(to: space, intent: .defaultIntent, options: nil),
              let parts = color.components, parts.count >= 3 else { return nil }
        return parts.prefix(3).map { Double(min(max($0, 0), 1)) }
    }
}

extension Color {
    init(platformColor: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: platformColor)
        #else
        self.init(uiColor: platformColor)
        #endif
    }
}

extension Image {
    init(platformImage: PlatformImage) {
        #if os(macOS)
        self.init(nsImage: platformImage)
        #else
        self.init(uiImage: platformImage)
        #endif
    }
}

#if !os(macOS)
extension View {
    /// Escape on a Mac keyboard; an iPad keyboard's Escape reaches the view as a key press instead.
    func onExitCommand(perform action: (() -> Void)?) -> some View {
        onKeyPress(.escape) {
            guard let action else { return .ignored }
            action()
            return .handled
        }
    }
}
#endif
