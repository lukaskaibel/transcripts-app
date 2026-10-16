import SwiftUI

/// What a meeting's page shows: the summary or the whole transcript, switched as in a segmented control.
enum MeetingTab: Hashable {
    case summary
    case transcript

    /// The summary once there is one; before that (recording, processing, no model) the transcript.
    static func initial(for detail: MeetingDetail) -> MeetingTab {
        detail.summary != nil ? .summary : .transcript
    }
}

struct MeetingTabPicker: View {
    @Binding var tab: MeetingTab

    var body: some View {
        Picker("Ansicht", selection: $tab) {
            Text("Zusammenfassung").tag(MeetingTab.summary)
            Text("Transkript").tag(MeetingTab.transcript)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityIdentifier("meeting.tab")
    }
}

extension View {
    /// Shows the summary as soon as it arrives, if the transcript was only on screen because there was none yet.
    func showsSummaryWhenItArrives(_ detail: MeetingDetail, tab: Binding<MeetingTab>) -> some View {
        onChange(of: detail.summary?.createdAt) { old, new in
            if old == nil, new != nil { tab.wrappedValue = .summary }
        }
    }
}
