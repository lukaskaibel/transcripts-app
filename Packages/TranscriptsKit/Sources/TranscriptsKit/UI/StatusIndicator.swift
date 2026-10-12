import SwiftUI

/// What the app is doing right now, as a dot or a spinner: recording, processing, loading the models, ready.
/// The Mac shows it at the bottom of the sidebar, iPhone and iPad under the title of the meetings.
struct StatusIndicator: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.recording != nil {
            RecordingDot(size: 7)
        } else if model.processingMeetingId != nil {
            ProgressView().controlSize(.mini).frame(width: 12, height: 12)
        } else {
            switch model.engineState {
            case .preparing:
                ProgressView().controlSize(.mini).frame(width: 12, height: 12)
            case .failed:
                Circle().fill(Theme.warning).frame(width: 7, height: 7)
            default:
                Circle().fill(model.modelsDownloaded ? Theme.positive : Theme.warning).frame(width: 7, height: 7)
            }
        }
    }
}

extension AppModel {
    /// The status in words: "Bereit · alles lokal", "Wird verarbeitet · 40 %", "Modelle werden geladen · 12 %".
    public var statusText: String {
        if recording != nil { return String(localized: "Aufnahme läuft") }
        if let id = processingMeetingId, let row = row(for: id) {
            return String(localized: "Wird verarbeitet · \(row.meeting.progress.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))")
        }
        switch engineState {
        case .preparing(_, let fraction): return String(localized: "Modelle werden geladen · \(fraction.formatted(.percent.precision(.fractionLength(0)).locale(AppLocale.current)))")
        case .failed: return String(localized: "Modelle fehlen")
        default: return modelsDownloaded ? String(localized: "Bereit · alles lokal") : String(localized: "Modelle noch nicht geladen")
        }
    }

    /// More about the status, for a tooltip or VoiceOver.
    public var statusHelp: String {
        switch engineState {
        case .failed(let message): return message
        case .preparing(let step, _): return String(localized: "\(step) wird geladen", comment: "%@ is the part being loaded, e.g. Spracherkennung")
        default:
            #if os(macOS)
            return String(localized: "Spracherkennung und Stimmerkennung laufen auf diesem Mac.")
            #else
            return String(localized: "Spracherkennung und Stimmerkennung laufen auf diesem Gerät.")
            #endif
        }
    }
}
