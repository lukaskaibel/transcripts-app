import SwiftUI

/// Settings › Allgemein › iCloud: sync on or off, the recordings with it or not, how it is doing.
struct ICloudSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.settings.iCloudSync }, set: { model.setICloudSync($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mit iCloud abgleichen")
                    Text("Meetings, Personen und Stimmen auf all deinen Geräten: auf dem iPhone aufnehmen, auf dem Mac nachlesen. Sie liegen in deinem privaten iCloud, nur du hast Zugriff darauf.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!model.iCloudAvailable)
            .accessibilityIdentifier("settings.icloud")
            if model.settings.iCloudSync {
                Toggle(isOn: Binding(get: { model.settings.iCloudAudio }, set: { model.setICloudAudio($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aufnahmen mitnehmen")
                        Text("Zum Nachhören und neu Transkribieren auf jedem Gerät. Belegt etwa 20 bis 60 MB iCloud-Speicher pro Stunde Meeting.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Status") {
                    HStack(spacing: 10) {
                        status
                        if model.syncState != .syncing, model.syncState != .noAccount {
                            Button("Jetzt abgleichen") { model.syncNow() }
                        }
                    }
                }
            } else if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.iCloudAvailable {
                Button("Aus iCloud löschen …", role: .destructive) { confirmDelete = true }
                    .disabled(model.syncState == .syncing && !model.settings.iCloudSync)
            }
        } header: {
            Text(verbatim: "iCloud")
        }
        .confirmationDialog("Alles aus iCloud löschen?", isPresented: $confirmDelete) {
            Button("Aus iCloud löschen", role: .destructive) {
                Task { await model.deleteICloudData() }
            }
        } message: {
            Text("Meetings, Personen, Stimmen und Aufnahmen verschwinden aus iCloud, und deine anderen Geräte gleichen nicht mehr ab. Was auf diesem \(Platform.deviceName) liegt, bleibt.", comment: "Mac, iPhone or iPad")
        }
    }

    /// Why sync is off, when it isn't the user's choice.
    private var note: String? {
        switch model.syncState {
        case .unavailable:
            String(localized: "In diesem Build nicht verfügbar: iCloud braucht eine Signatur mit einem Apple-Developer-Team (siehe Config/Local.xcconfig.example).")
        case .deletedInICloud:
            String(localized: "Die Daten in iCloud wurden auf einem anderen Gerät gelöscht. Schalte den Abgleich wieder ein, um mit dem Stand dieses Geräts neu anzufangen.")
        default:
            nil
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.syncState {
        case .syncing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Gleicht ab …").foregroundStyle(.secondary)
            }
        case .upToDate(let date):
            Text("Aktuell · \(date.formatted(.dateTime.hour().minute().locale(AppLocale.current)))", comment: "iCloud sync: up to date, with the time of the last sync")
                .foregroundStyle(.secondary)
        case .noAccount:
            Text("Kein iCloud-Account angemeldet").foregroundStyle(Theme.warning)
        case .failed(let message):
            Text(message).foregroundStyle(Theme.warning).lineLimit(2)
        case .off, .unavailable, .deletedInICloud:
            Text("Aus", comment: "iCloud sync: off").foregroundStyle(.secondary)
        }
    }
}
