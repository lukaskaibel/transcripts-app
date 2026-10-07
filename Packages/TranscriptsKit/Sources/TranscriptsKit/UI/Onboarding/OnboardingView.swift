import AppKit
import SwiftUI

/// The first start: the user's name, the permissions, and the speech models.
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var name = AppModel.defaultMyName
    @State private var downloading = false

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 36)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // As the system draws it, with the glass; `NSApp.applicationIconImage` is only a placeholder
                    // for icons made in Icon Composer. Its own margin is a tenth of the size on each side.
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .frame(width: 72, height: 72)
                        .padding(-7)
                        .accessibilityHidden(true)
                    Text("Willkommen bei Transcripts")
                        .font(.system(size: 24, weight: .semibold))
                        .padding(.top, 16)
                    Text("Meetings werden auf diesem Mac transkribiert. Die Stimmen der anderen erkennt die App mit der Zeit wieder. Ein paar Dinge braucht sie dafür:")
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)

                    VStack(spacing: 0) {
                        nameStep
                        divider
                        step(
                            title: "Mikrofon",
                            detail: "Für deine eigene Stimme.",
                            state: model.microphoneAllowed,
                            action: ("Erlauben", { Task { await model.requestMicrophone() } }),
                            settingsPane: "Privacy_Microphone"
                        )
                        divider
                        step(
                            title: "Systemaudio",
                            detail: "Für die Stimmen im Call. macOS fragt beim ersten Aufnehmen, ob die App den Ton des Macs aufnehmen darf.",
                            state: nil,
                            action: nil,
                            settingsPane: nil,
                            info: "Beim ersten Aufnehmen"
                        )
                        divider
                        step(
                            title: "Kalender",
                            detail: "Benennt Meetings, kennt die Teilnehmer und erinnert dich ans Aufnehmen.",
                            state: model.calendarAllowed,
                            action: ("Erlauben", { Task { await model.requestCalendar() } }),
                            settingsPane: "Privacy_Calendars"
                        )
                        divider
                        step(
                            title: "Mitteilungen",
                            detail: "Für „Meeting beginnt – Aufnehmen?“. Stelle in den Systemeinstellungen den Stil „Hinweise“ ein, dann bleibt die Mitteilung stehen, bis du klickst.",
                            state: model.notificationsAllowed,
                            action: ("Erlauben", { Task { await model.requestNotifications() } }),
                            settingsPane: nil
                        )
                        divider
                        modelStep
                    }
                    .cardStyle()
                    .padding(.top, 24)

                    HStack {
                        Text("Zusammenfassungen richtest du später in den Einstellungen unter KI ein.")
                            .font(.small)
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button("Los geht’s") {
                            saveName()
                            model.finishOnboarding()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 20)
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 30)
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
        }
        .panelStyle()
        .padding(8)
        .onAppear {
            model.refreshPermissions()
            // Models already on this Mac load right away; only the download waits for a click.
            if model.modelsDownloaded, model.engineState == .idle { model.prepareEngine() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermissions()
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.leading, 16)
    }

    private var nameStep: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dein Name").font(.uiMedium)
                Text("So heißt du in Transkripten und Zusammenfassungen.").font(.small).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit(saveName)
        }
        .padding(16)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var me = try? model.database.mePerson(defaultName: trimmed) else { return }
        me.name = trimmed
        try? model.database.save(me)
    }

    private func step(title: LocalizedStringKey, detail: LocalizedStringKey, state: Bool?, action: (LocalizedStringKey, () -> Void)?, settingsPane: String?, info: LocalizedStringKey? = nil) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.uiMedium)
                Text(detail).font(.small).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            if let info {
                Text(info).font(.small).foregroundStyle(Theme.textTertiary)
            } else if state == true {
                Label("Erlaubt", systemImage: "checkmark.circle.fill")
                    .font(.smallMedium)
                    .foregroundStyle(Theme.positive)
            } else if state == false {
                Button("Systemeinstellungen") {
                    if let settingsPane { model.openPrivacySettings(settingsPane) } else { model.openNotificationSettings() }
                }
                .buttonStyle(SecondaryButtonStyle())
            } else if let action {
                Button(action.0, action: action.1).buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
    }

    private var modelStep: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sprachmodelle").font(.uiMedium)
                Text("\(model.settings.transcriptionModel.title) und die Stimmerkennung, etwa 700 MB. Einmal laden, danach läuft alles offline.")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if case .preparing(let step, let fraction) = model.engineState {
                    HStack(spacing: 8) {
                        ThinBar(fraction: fraction).frame(width: 180)
                        Text(verbatim: "\(step) · \(fraction.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))").font(.tiny).foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.top, 6)
                }
                if case .failed(let message) = model.engineState {
                    Text(message).font(.small).foregroundStyle(Theme.warning).padding(.top, 4)
                }
            }
            Spacer(minLength: 16)
            switch model.engineState {
            case .ready:
                Label("Geladen", systemImage: "checkmark.circle.fill").font(.smallMedium).foregroundStyle(Theme.positive)
            case .preparing:
                ProgressView().controlSize(.small)
            default:
                Button(model.modelsDownloaded ? "Laden" : "Herunterladen") { model.prepareEngine() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(16)
    }
}
