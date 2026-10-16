import SwiftUI

/// Settings › App-Icon: the dictaphone on the app's icon. On the Mac in the colours you like, shown in the Dock while
/// the app runs; on iPhone and iPad one of the presets, each an icon of the app.
struct AppIconSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            #if os(macOS)
            Section {
                HStack(spacing: 36) {
                    Preview(look: model.settings.appIcon, dark: false, caption: String(localized: "Hell", comment: "appearance: light"))
                    Preview(look: model.settings.appIcon, dark: true, caption: String(localized: "Dunkel", comment: "appearance: dark"))
                }
                .frame(maxWidth: .infinity)
            }
            Section {
                LabeledContent("Vorlagen") { presets }
                LabeledContent("Gehäuse") { SwatchRow(swatches: AppIconLook.bodies, color: part(\.body)) }
                LabeledContent("Lautsprecher") { SwatchRow(swatches: AppIconLook.grilles, color: part(\.grille)) }
                LabeledContent("Aufnahmetaste") { SwatchRow(swatches: AppIconLook.buttons, color: part(\.button)) }
                LabeledContent("Hintergrund") { SwatchRow(swatches: AppIconLook.grounds, color: part(\.ground)) }
            } footer: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Dein Icon zeigt das Dock, solange die App läuft, hell oder dunkel wie dein Mac. Getönt und klar gibt es nur das Standard-Icon.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Standard verwenden") { model.setAppIcon(.standard) }
                        .disabled(model.settings.appIcon == .standard)
                }
            }
            #else
            Section {
                presets
                    .padding(.vertical, 6)
            } footer: {
                Text("Jedes Icon passt sich an wie die anderen: hell, dunkel, getönt oder klar.")
            }
            #endif
        }
        .settingsForm()
    }

    private var presets: some View {
        #if os(macOS)
        HStack(spacing: 10) { presetButtons }
        #else
        // In one row where it fits, else in rows of three.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { presetButtons }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 12) { presetButtons }
        }
        #endif
    }

    private var presetButtons: some View {
        ForEach(AppIconPreset.allCases) { preset in
            PresetButton(preset: preset, selected: model.settings.appIcon == preset.look) { model.setAppIcon(preset.look) }
        }
    }

    /// One part's colour; a change shows in the previews right away and in the Dock a moment later.
    private func part(_ keyPath: WritableKeyPath<AppIconLook, IconColor>) -> Binding<IconColor> {
        Binding(
            get: { model.settings.appIcon[keyPath: keyPath] },
            set: { color in
                var look = model.settings.appIcon
                look[keyPath: keyPath] = color
                model.setAppIcon(look)
            }
        )
    }
}

/// One of the presets, with a ring when the icon is that one.
private struct PresetButton: View {
    var preset: AppIconPreset
    var selected: Bool
    var action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Group {
                    if let image = AppIconRenderer.shared.picture(preset.look, dark: colorScheme == .dark) {
                        Image(platformImage: image).resizable().interpolation(.high)
                    } else {
                        Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 52, height: 52)
                .padding(3)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(selected ? Color.accentColor : .clear, lineWidth: 2)
                )
                Text(preset.title)
                    .font(.caption)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(preset.title)
        .accessibilityLabel("App-Icon \(preset.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(macOS)
/// The icon as the Dock will show it, in light or in dark.
private struct Preview: View {
    var look: AppIconLook
    var dark: Bool
    var caption: String

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let image = AppIconRenderer.shared.picture(look, dark: dark) {
                    Image(platformImage: image).resizable().interpolation(.high)
                } else {
                    Color.clear
                }
            }
            .frame(width: 88, height: 88)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("App-Icon \(caption)")
    }
}

/// A row of colours to pick from, like the accent colours in System Settings, and a colour well for any other.
private struct SwatchRow: View {
    let swatches: [AppIconLook.Swatch]
    @Binding var color: IconColor

    var body: some View {
        HStack(spacing: 4) {
            ForEach(swatches) { swatch in
                let selected = swatch.color == color
                Button {
                    color = swatch.color
                } label: {
                    Circle()
                        .fill(swatch.color.color)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .help(swatch.name)
                .accessibilityLabel(swatch.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            ColorPicker("Andere Farbe", selection: Binding(
                get: { color.color },
                set: { color = IconColor(NSColor($0)) }
            ), supportsOpacity: false)
            .labelsHidden()
            .help("Andere Farbe")
        }
        // The row's label lines up with the middle of the colours, not their top.
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }
}
#endif
