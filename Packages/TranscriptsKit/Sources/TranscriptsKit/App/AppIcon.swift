import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A colour of the dictaphone on the app's icon, in 8-bit sRGB.
public struct IconColor: Codable, Hashable, Sendable {
    public var red: Int
    public var green: Int
    public var blue: Int

    public init(red: Int, green: Int, blue: Int) {
        (self.red, self.green, self.blue) = (red, green, blue)
    }

    public init(hex: UInt32) {
        self.init(red: Int(hex >> 16 & 0xFF), green: Int(hex >> 8 & 0xFF), blue: Int(hex & 0xFF))
    }

    var color: Color { Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }

    #if os(macOS)
    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? .black
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        self.init(red: byte(c.redComponent), green: byte(c.greenComponent), blue: byte(c.blueComponent))
    }

    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
    }
    #endif

    var components: SIMD3<Double> { SIMD3(Double(red), Double(green), Double(blue)) / 255 }

    init(_ components: SIMD3<Double>) {
        let c = (components.clamped(lowerBound: .zero, upperBound: .one) * 255).rounded(.toNearestOrEven)
        self.init(red: Int(c.x), green: Int(c.y), blue: Int(c.z))
    }

    /// The same hue with its saturation and brightness scaled, as Tools/AppIcon/dictaphone.py does it.
    func scaled(saturation: Double, brightness: Double, minimumBrightness: Double = 0) -> IconColor {
        var (h, s, v) = hsv
        s = min(s * saturation, 1)
        v = min(max(v * brightness, minimumBrightness), 1)
        return IconColor(Self.rgb(h: h, s: s, v: v))
    }

    /// Python's colorsys.rgb_to_hsv, so both sides get the same shades.
    private var hsv: (Double, Double, Double) {
        let c = components
        let high = c.max(), low = c.min()
        guard high > 0, high != low else { return (0, 0, high) }
        let s = (high - low) / high
        let r = (high - c.x) / (high - low), g = (high - c.y) / (high - low), b = (high - c.z) / (high - low)
        var h = c.x == high ? b - g : c.y == high ? 2 + r - b : 4 + g - r
        h = (h / 6).truncatingRemainder(dividingBy: 1)
        return (h < 0 ? h + 1 : h, s, high)
    }

    private static func rgb(h: Double, s: Double, v: Double) -> SIMD3<Double> {
        guard s > 0 else { return SIMD3(repeating: v) }
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return SIMD3(v, t, p)
        case 1: return SIMD3(q, v, p)
        case 2: return SIMD3(p, v, t)
        case 3: return SIMD3(p, q, v)
        case 4: return SIMD3(t, p, v)
        default: return SIMD3(v, p, q)
        }
    }
}

/// The dictaphone on the app's icon: its body, the speaker grille, the record button (and its light) and what it
/// stands on.
public struct AppIconLook: Codable, Hashable, Sendable {
    public var body: IconColor
    public var grille: IconColor
    public var button: IconColor
    public var ground: IconColor

    public init(body: IconColor, grille: IconColor, button: IconColor, ground: IconColor) {
        self.body = body
        self.grille = grille
        self.button = button
        self.ground = ground
    }

    /// The dictaphone the app ships with. Transcripts/AppIcon.icon is drawn from the same colours
    /// (Tools/AppIcon/dictaphone.py).
    public static let standard = AppIconLook(body: IconColor(hex: 0x2C2E33), grille: IconColor(hex: 0xE1E3E7),
                                             button: IconColor(hex: 0xE8382D), ground: IconColor(hex: 0xECE8E1))

    public struct Swatch: Identifiable, Sendable {
        public let name: String
        public let color: IconColor
        public var id: String { name }
        init(_ name: String, _ hex: UInt32) { (self.name, color) = (name, IconColor(hex: hex)) }
    }

    public static let bodies = [
        Swatch(String(localized: "Schwarz", comment: "app icon colour"), 0x2C2E33),
        Swatch(String(localized: "Space Grau", comment: "app icon colour"), 0x5E6168),
        Swatch(String(localized: "Silber", comment: "app icon colour"), 0xD6D8DC),
        Swatch(String(localized: "Weiß", comment: "app icon colour"), 0xF2F2EF),
        Swatch(String(localized: "Titan", comment: "app icon colour"), 0xB5AEA3),
        Swatch(String(localized: "Mitternacht", comment: "app icon colour"), 0x273145),
        Swatch(String(localized: "Blau", comment: "app icon colour"), 0x3D5C7B),
        Swatch(String(localized: "Grün", comment: "app icon colour"), 0x4E6253),
        Swatch(String(localized: "Burgund", comment: "app icon colour"), 0x6B2128),
    ]
    public static let grilles = [
        Swatch(String(localized: "Silber", comment: "app icon colour"), 0xE1E3E7),
        Swatch(String(localized: "Space Grau", comment: "app icon colour"), 0x4A4C52),
        Swatch(String(localized: "Schwarz", comment: "app icon colour"), 0x232428),
        Swatch(String(localized: "Titan", comment: "app icon colour"), 0x7E786F),
        Swatch(String(localized: "Gold", comment: "app icon colour"), 0xD9C49B),
    ]
    public static let buttons = [
        Swatch(String(localized: "Rot", comment: "app icon colour"), 0xE8382D),
        Swatch(String(localized: "Orange", comment: "app icon colour"), 0xFF5F1F),
        Swatch(String(localized: "Gelb", comment: "app icon colour"), 0xF5B82E),
        Swatch(String(localized: "Grün", comment: "app icon colour"), 0x34B35A),
        Swatch(String(localized: "Blau", comment: "app icon colour"), 0x2F7BF5),
        Swatch(String(localized: "Weiß", comment: "app icon colour"), 0xF4F4F2),
    ]
    public static let grounds = [
        Swatch(String(localized: "Stein", comment: "app icon colour"), 0xECE8E1),
        Swatch(String(localized: "Nebel", comment: "app icon colour"), 0xE4E9F0),
        Swatch(String(localized: "Salbei", comment: "app icon colour"), 0xE3E7DE),
        Swatch(String(localized: "Sand", comment: "app icon colour"), 0xF0E7DA),
        Swatch(String(localized: "Rosé", comment: "app icon colour"), 0xF1E6E3),
        Swatch(String(localized: "Himmel", comment: "app icon colour"), 0xE5EDF4),
        Swatch(String(localized: "Schiefer", comment: "app icon colour"), 0xBDC1C8),
        Swatch(String(localized: "Graphit", comment: "app icon colour"), 0x70747C),
        Swatch(String(localized: "Weiß", comment: "app icon colour"), 0xFFFFFF),
    ]

    /// The ground's gradient from top to bottom: a dark grey of the same tint in dark mode, never black.
    func ground(dark: Bool) -> (IconColor, IconColor) {
        guard dark else { return (ground, ground.scaled(saturation: 1.1, brightness: 0.88)) }
        let top = ground.scaled(saturation: 0.6, brightness: 0.30, minimumBrightness: 0.18)
        return (top, top.scaled(saturation: 1, brightness: 0.55))
    }
}

/// Ready-made dictaphones. On iPhone and iPad they are the icons to choose from (each an icon of its own in the app,
/// Transcripts/AppIcon-*.icon); on the Mac a start for your own colours.
public enum AppIconPreset: String, CaseIterable, Identifiable, Sendable {
    case standard, silver, titanium, white, midnight

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: String(localized: "Standard", comment: "app icon")
        case .silver: String(localized: "Silber", comment: "app icon colour")
        case .titanium: String(localized: "Titan", comment: "app icon colour")
        case .white: String(localized: "Weiß", comment: "app icon colour")
        case .midnight: String(localized: "Mitternacht", comment: "app icon colour")
        }
    }

    /// Keep in step with PRESETS in Tools/AppIcon/dictaphone.py.
    public var look: AppIconLook {
        switch self {
        case .standard: .standard
        case .silver: AppIconLook(body: IconColor(hex: 0xD6D8DC), grille: IconColor(hex: 0x4A4C52),
                                  button: IconColor(hex: 0xE8382D), ground: IconColor(hex: 0xE4E9F0))
        case .titanium: AppIconLook(body: IconColor(hex: 0xB5AEA3), grille: IconColor(hex: 0x7E786F),
                                    button: IconColor(hex: 0xFF5F1F), ground: IconColor(hex: 0xECE8E1))
        case .white: AppIconLook(body: IconColor(hex: 0xF2F2EF), grille: IconColor(hex: 0xE1E3E7),
                                 button: IconColor(hex: 0xE8382D), ground: IconColor(hex: 0xE3E7DE))
        case .midnight: AppIconLook(body: IconColor(hex: 0x273145), grille: IconColor(hex: 0xE1E3E7),
                                    button: IconColor(hex: 0xE8382D), ground: IconColor(hex: 0xE4E9F0))
        }
    }

    /// The alternate icon's name in the app bundle on iPhone and iPad; nil is the app's own icon.
    var alternateIconName: String? {
        switch self {
        case .standard: nil
        case .silver: "AppIcon-Silver"
        case .titanium: "AppIcon-Titanium"
        case .white: "AppIcon-White"
        case .midnight: "AppIcon-Midnight"
        }
    }

    init?(_ look: AppIconLook) {
        guard let preset = Self.allCases.first(where: { $0.look == look }) else { return nil }
        self = preset
    }
}

extension AppIconLook {
    /// Puts the icon in the Dock or on the Home Screen. On the Mac the standard look hands the Dock back to the app's
    /// own icon, with its glass and its tinted and clear looks; any other shows while the app runs.
    @MainActor
    public func apply() {
        #if os(macOS)
        AppIconDock.shared.show(self)
        #else
        // Only the presets are icons of the app. iOS shows an alert of its own whenever the icon changes, so only ask
        // when it really differs.
        let name = AppIconPreset(self)?.alternateIconName
        guard UIApplication.shared.supportsAlternateIcons, UIApplication.shared.alternateIconName != name else { return }
        UIApplication.shared.setAlternateIconName(name)
        #endif
    }
}

/// The app's own icon at Dock proportions, rendered from Transcripts/AppIcon.icon by Tools/AppIcon/make.sh.
enum AppIconPicture {
    static func standard(dark: Bool) -> PlatformImage? {
        let name = dark ? "icon-dark" : "icon-light"
        #if os(macOS)
        return Bundle.module.image(forResource: name)
        #else
        return UIImage(named: name, in: .module, with: nil)
        #endif
    }
}
