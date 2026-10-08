import AppKit
import SwiftUI

/// Design tokens, shared with the Issues app. Every colour has a light and a dark value.
enum Theme {
    static let window = Color(light: 0xF1F2F4, dark: 0x0B0C0E)
    static let panel = Color(light: 0xFBFBFC, dark: 0x111214)
    static let panelBorder = Color(light: 0xE3E4E8, dark: 0x1F2126)
    static let groupHeader = Color(light: 0xF5F6F8, dark: 0x191B1F)
    static let rowSeparator = Color(light: 0xEDEEF1, dark: 0x191B1F)

    static let card = Color(light: 0xFFFFFF, dark: 0x17181B)
    static let cardBorder = Color(light: 0xE6E7EB, dark: 0x212327)

    static let hover = Color(light: 0xE8E9ED, dark: 0x1A1C20)
    static let selected = Color(light: 0xECEDF1, dark: 0x1C1E23)
    static let control = Color(light: 0xE7E8EC, dark: 0x191B1F)
    static let controlActive = Color(light: 0xE4E5E9, dark: 0x2A2D33)
    static let chipBorder = Color(light: 0xDCDDE2, dark: 0x2A2D33)
    static let selectionFill = Color(light: 0xEDEEFC, dark: 0x1D1F33)
    static let selectionBorder = Color(light: 0x8D93E6, dark: 0x5C63C9)

    static let popover = Color(light: 0xFFFFFF, dark: 0x1B1D21)
    static let popoverBorder = Color(light: 0xDDDEE3, dark: 0x2C2F36)
    static let popoverSelected = Color(light: 0xEEEFF2, dark: 0x2A2D33)
    /// The row the keyboard is on, in a list inside a popover.
    static let popoverActiveRow = Color(light: 0xF7F8FA, dark: 0x202227)
    static let keycapBorder = Color(light: 0xD0D2D8, dark: 0x3A3E46)
    /// Behind a small icon or avatar under the pointer.
    static let partHover = Color(light: 0xE4E5E9, dark: 0x2A2D33)
    static let started = Color(light: 0xD29A0A, dark: 0xF0B429)
    static let noticeFill = Color(light: 0xFBF6EC, dark: 0x2A2216)
    static let noticeText = Color(light: 0x7A4E0E, dark: 0xE5C48B)

    static let text = Color(light: 0x1A1B1E, dark: 0xE8E9EB)
    static let textSecondary = Color(light: 0x5F636B, dark: 0x9A9FA8)
    static let textTertiary = Color(light: 0x696D76, dark: 0x7C818A)
    static let textBody = Color(light: 0x2E3035, dark: 0xC9CCD1)

    static let accent = Color(light: 0x5B63D3, dark: 0x8F96F2)
    static let accentFill = Color(light: 0x5B63D3, dark: 0x5B63D3)
    static let positive = Color(light: 0x2F9B67, dark: 0x4CB782)
    static let warning = Color(light: 0xB8791C, dark: 0xE5A84B)
    static let recording = Color(light: 0xD64545, dark: 0xEB6A6A)
    /// The stop button: dark enough for white text in both appearances.
    static let recordingFill = Color(hex: 0xC93C3C)
    static let barOff = Color(light: 0xD5D7DC, dark: 0x3A3E46)
    static let segmentActive = Color(light: 0xFFFFFF, dark: 0x2A2D33)
    static let onColor = Color(light: 0xFFFFFF, dark: 0x111214)
    static let scrim = Color(light: 0x14161A, dark: 0x000000).opacity(0.4)
    static let shadow = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor.black.withAlphaComponent(appearance.isDark ? 0.5 : 0.16)
    })

    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.82)
    static let quick = Animation.easeOut(duration: 0.14)
    static let overlay = Animation.spring(response: 0.26, dampingFraction: 0.86)

    static let sidebarWidth: CGFloat = 236
    static let headerHeight: CGFloat = 44
    static let rowHeight: CGFloat = 38
    static let inspectorWidth: CGFloat = 280

    static let avatarPalette: [Color] = [
        Color(hex: 0x8F96F2), Color(hex: 0x4CB782), Color(hex: 0xE5A84B),
        Color(hex: 0x5AB0D8), Color(hex: 0xD98BC4), Color(hex: 0xC792EA),
    ]
    static let meColor = Color(hex: 0xB4B8C0)

    /// GitHub's eight option colours, tuned for each ground (as in Issues for GitHub).
    static func optionColor(_ name: String) -> Color? {
        switch name {
        case "BLUE": Color(light: 0x2F86B5, dark: 0x5AB0D8)
        case "GREEN": Color(light: 0x2F9B67, dark: 0x4CB782)
        case "YELLOW": Color(light: 0xD29A0A, dark: 0xF0B429)
        case "ORANGE": Color(light: 0xE07B2A, dark: 0xF2994A)
        case "RED": Color(light: 0xD64545, dark: 0xEB6A6A)
        case "PINK": Color(light: 0xC45FA6, dark: 0xD98BC4)
        case "PURPLE": Color(light: 0x5B63D3, dark: 0x8F96F2)
        default: nil
        }
    }

    static func statusColor(_ option: GitHubStatusOption?) -> Color {
        guard let option else { return textTertiary }
        if let color = optionColor(option.color) { return color }
        switch option.category {
        case .backlog, .canceled: return textTertiary
        case .unstarted: return textBody
        case .started: return started
        case .completed: return accent
        }
    }

    /// Label colours come from GitHub as hex. Very dark ones are lifted on the dark ground and very light ones
    /// deepened on the light ground, so a label never disappears.
    static func labelColor(_ hex: String) -> Color {
        guard let value = UInt32(hex, radix: 16) else { return textSecondary }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return Color(nsColor: NSColor(name: nil) { appearance in
            if appearance.isDark, luminance < 0.25 {
                let lift = 0.45
                return NSColor(srgbRed: r + (1 - r) * lift, green: g + (1 - g) * lift, blue: b + (1 - b) * lift, alpha: 1)
            }
            if !appearance.isDark, luminance > 0.7 {
                let keep = 0.62
                return NSColor(srgbRed: r * keep, green: g * keep, blue: b * keep, alpha: 1)
            }
            return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
        })
    }

    static func color(for name: String) -> Color {
        let hash = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return avatarPalette[hash % avatarPalette.count]
    }
}

extension Color {
    /// A colour that follows the window's appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(hex: appearance.isDark ? dark : light)
        })
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

extension Font {
    static let ui = Font.system(size: 13)
    static let uiMedium = Font.system(size: 13, weight: .medium)
    static let uiSemibold = Font.system(size: 13, weight: .semibold)
    static let small = Font.system(size: 12)
    static let smallMedium = Font.system(size: 12, weight: .medium)
    static let smallSemibold = Font.system(size: 12, weight: .semibold)
    static let tiny = Font.system(size: 11)
    static let tinySemibold = Font.system(size: 11, weight: .semibold)
    static let reading = Font.system(size: 14)
    static let pageTitle = Font.system(size: 22, weight: .semibold)
}

/// A button that looks like plain content and dims slightly while pressed.
struct PlainPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// Background that lights up on hover, used for sidebar rows, toolbar buttons and menu rows.
struct HoverFill: ViewModifier {
    var active = false
    var radius: CGFloat = 6
    var fill = Theme.hover
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(active || hovering ? fill : .clear)
            )
            .onHover { hovering = $0 }
            .animation(Theme.quick, value: hovering)
    }
}

extension View {
    func hoverFill(active: Bool = false, radius: CGFloat = 6, fill: Color = Theme.hover) -> some View {
        modifier(HoverFill(active: active, radius: radius, fill: fill))
    }

    /// The rounded, bordered panel the content of a window sits in.
    func panelStyle(radius: CGFloat = 10) -> some View {
        background(Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.panelBorder, lineWidth: 1))
    }

    func cardStyle(radius: CGFloat = 10) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accentFill))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.small)
            .foregroundStyle(Theme.textBody)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(configuration.isPressed ? Theme.controlActive : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.chipBorder, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// The red button that ends a recording.
struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.recordingFill))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}
