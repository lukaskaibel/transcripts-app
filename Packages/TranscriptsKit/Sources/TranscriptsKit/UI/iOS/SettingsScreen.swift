#if os(iOS)
import SwiftUI

/// Settings on iPhone and iPad: the Mac's pages as a list, each the same form the Mac shows (without what only
/// a Mac can do, such as the menu bar or the call's sound).
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var start: AppModel.SettingsTab?
    @State private var path: [AppModel.SettingsTab] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    ForEach(AppModel.SettingsTab.allCases) { tab in
                        NavigationLink(value: tab) {
                            Label {
                                Text(tab.title)
                            } icon: {
                                icon(tab)
                            }
                        }
                        .accessibilityIdentifier("settings.\(tab.rawValue)")
                    }
                } footer: {
                    Text(version)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                }
            }
            .navigationTitle(String(localized: "Einstellungen"))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: AppModel.SettingsTab.self) { tab in
                page(tab)
                    .navigationTitle(tab.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Fertig")) { dismiss() }
                        .accessibilityIdentifier("settings.done")
                }
            }
        }
        .tint(Theme.accent)
        .onAppear {
            if let start, path.isEmpty { path = [start] }
        }
    }

    @ViewBuilder
    private func page(_ tab: AppModel.SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettings()
        case .recording: RecordingSettings()
        case .transcription: TranscriptionSettings()
        case .ai: AISettings()
        case .voices: VoiceSettings()
        case .icon: AppIconSettings()
        }
    }

    @ViewBuilder
    private func icon(_ tab: AppModel.SettingsTab) -> some View {
        Image(systemName: tab.systemImage).foregroundStyle(Theme.accent)
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        return "Transcripts \(short)"
    }
}

/// Naming voices in a sheet: the Mac's view, one voice after another.
struct NamingSheet: View {
    @Environment(AppModel.self) private var model
    var meetingId: String?

    var body: some View {
        ScrollView {
            NameVoicesPanel(meetingId: meetingId)
        }
        .background(Theme.panel)
        .presentationDetents([.fraction(0.75), .large])
        .presentationDragIndicator(.visible)
        .onDisappear {
            model.player.stop()
            if case .naming = model.overlay { model.overlay = nil }
        }
    }
}
#endif
