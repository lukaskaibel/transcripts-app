#if os(iOS)
import SwiftUI

/// The first start on iPhone and iPad, as on the Mac: the user's name, the permissions, and the speech models.
struct MobileOnboarding: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                icon
                Text("Willkommen bei Transcripts")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 18)
                Text("Leg das \(Platform.deviceName) in Meetings auf den Tisch: Transcripts nimmt den Raum auf, schreibt mit, wer was gesagt hat, und erkennt die Stimmen mit der Zeit wieder. Alles auf diesem \(Platform.deviceName). Ein paar Dinge braucht es dafür:", comment: "iPhone or iPad, twice")
                    .font(.ui)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)

                VStack(spacing: 0) {
                    nameStep
                    divider
                    step(
                        title: String(localized: "Mikrofon"),
                        detail: String(localized: "Für alle Stimmen im Raum."),
                        state: model.microphoneAllowed,
                        request: { Task { await model.requestMicrophone() } },
                        pane: "Privacy_Microphone"
                    )
                    divider
                    step(
                        title: String(localized: "Kalender"),
                        detail: String(localized: "Benennt Meetings, kennt die Teilnehmer und erinnert dich ans Aufnehmen."),
                        state: model.calendarAllowed,
                        request: { Task { await model.requestCalendar() } },
                        pane: "Privacy_Calendars"
                    )
                    divider
                    step(
                        title: String(localized: "Mitteilungen"),
                        detail: String(localized: "Für „Meeting beginnt – Aufnehmen?“."),
                        state: model.notificationsAllowed,
                        request: { Task { await model.requestNotifications() } },
                        pane: nil
                    )
                    divider
                    modelStep
                }
                .cardStyle(radius: 16)
                .padding(.top, 24)

                Button {
                    saveName()
                    model.finishOnboarding()
                } label: {
                    Text("Los geht’s").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.large)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.top, 24)
                .accessibilityIdentifier("onboarding.start")
                Text("Zusammenfassungen richtest du später in den Einstellungen unter KI ein.")
                    .font(.small)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.panel)
        .onAppear {
            name = model.me?.name ?? ""
            model.refreshPermissions()
            // Models already on this device load right away; only the download waits for a tap.
            if model.modelsDownloaded, model.engineState == .idle { model.prepareEngine() }
        }
    }

    private var icon: some View {
        Group {
            if let image = (colorScheme == .dark ? AppIconChoice.dark : AppIconChoice.light).image {
                Image(platformImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    // The pictures carry the margin a Mac icon has around it.
                    .padding(-8)
            }
        }
        .accessibilityHidden(true)
    }

    private var divider: some View {
        Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.leading, 16)
    }

    private var nameStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Dein Name").font(.uiMedium).foregroundStyle(Theme.text)
                Text("So heißt du in Transkripten und Zusammenfassungen.").font(.small).foregroundStyle(Theme.textTertiary)
            }
            TextField("Name", text: $name)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit(saveName)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.control))
                .accessibilityIdentifier("onboarding.name")
        }
        .padding(16)
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var me = try? model.database.mePerson(defaultName: trimmed) else { return }
        me.name = trimmed
        try? model.database.save(me)
    }

    private func step(title: String, detail: String, state: Bool?, request: @escaping () -> Void, pane: String?) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.uiMedium).foregroundStyle(Theme.text)
                Text(detail).font(.small).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if state == true {
                Label("Erlaubt", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(Theme.positive)
                    .accessibilityLabel(Text("\(title): erlaubt"))
            } else if state == false {
                Button("Einstellungen") {
                    if let pane { model.openPrivacySettings(pane) } else { model.openNotificationSettings() }
                }
                .buttonStyle(SecondaryButtonStyle())
            } else {
                Button("Erlauben", action: request)
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityLabel(Text("\(title) erlauben"))
            }
        }
        .padding(16)
    }

    private var modelStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sprachmodelle").font(.uiMedium).foregroundStyle(Theme.text)
                    Text("\(model.settings.transcriptionModel.title) und die Stimmerkennung, etwa 700 MB. Einmal laden, am besten im WLAN, danach läuft alles offline.")
                        .font(.small)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                switch model.engineState {
                case .ready:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.positive)
                        .accessibilityLabel(Text("Geladen", comment: "speech model: its files are downloaded"))
                case .preparing:
                    ProgressView()
                default:
                    Button(model.modelsDownloaded ? String(localized: "Laden", comment: "button: load the downloaded speech models") : String(localized: "Herunterladen")) { model.prepareEngine() }
                        .buttonStyle(SecondaryButtonStyle())
                        .accessibilityIdentifier("onboarding.models")
                }
            }
            if case .preparing(let step, let fraction) = model.engineState {
                HStack(spacing: 8) {
                    ThinBar(fraction: fraction)
                    Text(verbatim: "\(step) · \(fraction.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))")
                        .font(.tiny)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize()
                }
            }
            if case .failed(let message) = model.engineState {
                Text(message).font(.small).foregroundStyle(Theme.warning)
            }
        }
        .padding(16)
    }
}
#endif
