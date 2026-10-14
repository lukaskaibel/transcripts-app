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
    static let shadow = Color(platformColor: .dynamic { isDark in
        PlatformColor.black.withAlphaComponent(isDark ? 0.5 : 0.16)
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

    static func color(for name: String) -> Color {
        let hash = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return avatarPalette[hash % avatarPalette.count]
    }
}

extension Color {
    /// A colour that follows the window's appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(platformColor: .dynamic { isDark in PlatformColor(hex: isDark ? dark : light) })
    }

    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Font {
    #if os(macOS)
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
    /// The live transcript, a little larger than a meeting's.
    static let live = Font.system(size: 15)
    #else
    // On iPhone and iPad the same roles follow the reader's text size, as in Issues for GitHub.
    static let ui = Font.callout
    static let uiMedium = Font.callout.weight(.medium)
    static let uiSemibold = Font.callout.weight(.semibold)
    static let small = Font.footnote
    static let smallMedium = Font.footnote.weight(.medium)
    static let smallSemibold = Font.footnote.weight(.semibold)
    static let tiny = Font.caption
    static let tinySemibold = Font.caption.weight(.semibold)
    static let reading = Font.body
    static let pageTitle = Font.title2.weight(.semibold)
    static let live = Font.body
    #endif
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

/// Sizes of the app's buttons: compact for a pointer on the Mac, big enough for a finger on iPhone and iPad.
enum ButtonMetrics {
    #if os(macOS)
    static let height: CGFloat = 26
    static let radius: CGFloat = 6
    static let padding: CGFloat = 12
    static let font = Font.system(size: 12, weight: .semibold)
    static let secondaryFont = Font.small
    #else
    static let height: CGFloat = 36
    static let radius: CGFloat = 10
    static let padding: CGFloat = 14
    static let font = Font.subheadline.weight(.semibold)
    static let secondaryFont = Font.subheadline.weight(.medium)
    #endif
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ButtonMetrics.font)
            .foregroundStyle(.white)
            .padding(.horizontal, ButtonMetrics.padding)
            .frame(minHeight: ButtonMetrics.height)
            .background(RoundedRectangle(cornerRadius: ButtonMetrics.radius, style: .continuous).fill(Theme.accentFill))
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ButtonMetrics.secondaryFont)
            .foregroundStyle(Theme.textBody)
            .padding(.horizontal, ButtonMetrics.padding - 2)
            .frame(minHeight: ButtonMetrics.height)
            .background(RoundedRectangle(cornerRadius: ButtonMetrics.radius, style: .continuous).fill(configuration.isPressed ? Theme.controlActive : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: ButtonMetrics.radius, style: .continuous).stroke(Theme.chipBorder, lineWidth: 1))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// The red button that ends a recording.
struct StopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(ButtonMetrics.font)
            .foregroundStyle(.white)
            .padding(.horizontal, ButtonMetrics.padding - 1)
            .frame(minHeight: ButtonMetrics.height + 2)
            .background(RoundedRectangle(cornerRadius: ButtonMetrics.radius + 1, style: .continuous).fill(Theme.recordingFill))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}
