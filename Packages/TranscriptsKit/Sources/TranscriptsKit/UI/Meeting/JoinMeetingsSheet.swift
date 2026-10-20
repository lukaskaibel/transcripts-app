import SwiftUI

/// Joining meetings recorded one after another into one: the meetings of that day that can be joined, those right
/// before and after the one asked about already ticked. The Mac shows it as a sheet on the window, iPhone and iPad as
/// a sheet from the bottom.
struct JoinMeetingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let meetingId: String
    /// After joining: the meetings joined, the one they are in now first.
    var onJoined: ([String]) -> Void = { _ in }

    @State private var candidates: [Meeting] = []
    @State private var chosen: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Meetings zusammenführen")
                .font(Platform.isMobile ? .title2.bold() : .system(size: 20, weight: .bold))
            Text("Die Aufnahmen kommen nacheinander in das erste Meeting, das danach neu transkribiert wird. Namen, Markierungen und Aufgaben bleiben, die anderen Meetings werden gelöscht.", comment: "joining meetings: what happens")
                .font(Platform.isMobile ? .subheadline : .ui)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(candidates) { meeting in row(meeting) }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 14)
            buttons
        }
        .padding(.horizontal, Platform.isMobile ? 20 : 22)
        .padding(.top, Platform.isMobile ? 24 : 20)
        .padding(.bottom, Platform.isMobile ? 12 : 18)
        #if os(macOS)
        .frame(width: 440)
        #else
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
        .foregroundStyle(Theme.text)
        .interactiveDismissDisabled(model.joiningMeetings)
        .onAppear {
            candidates = model.joinCandidates(for: meetingId)
            chosen = model.likelyParts(of: meetingId)
        }
        .onDisappear {
            if case .joining = model.overlay { model.overlay = nil }
        }
    }

    private func row(_ meeting: Meeting) -> some View {
        let on = chosen.contains(meeting.id)
        return Button {
            if on { chosen.remove(meeting.id) } else { chosen.insert(meeting.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: Platform.isMobile ? 22 : 16))
                    .foregroundStyle(on ? Theme.accent : Theme.textTertiary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(meeting.title)
                        .font(Platform.isMobile ? .body.weight(.medium) : .uiMedium)
                        .lineLimit(1)
                    Text(verbatim: "\(TimeFormat.time(meeting.startedAt))–\(TimeFormat.time(meeting.endedAt)) · \(TimeFormat.duration(meeting.duration))")
                        .font(.small)
                        .monospacedDigit()
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Platform.isMobile ? 9 : 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Theme.selectionFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .disabled(model.joiningMeetings)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("join.\(meeting.id)")
    }

    @ViewBuilder
    private var buttons: some View {
        let join = Button {
            Task {
                if let joined = await model.joinMeetings(chosen) { onJoined(joined) }
                dismiss()
            }
        } label: {
            HStack(spacing: 8) {
                if model.joiningMeetings {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Wird zusammengeführt …", comment: "joining meetings: while the audio is put together")
                } else {
                    Text("Zusammenführen", comment: "joining meetings: the button that does it")
                }
            }
            .frame(maxWidth: Platform.isMobile ? .infinity : nil)
        }
        .buttonStyle(PrimaryButtonStyle())
        .disabled(chosen.count < 2 || model.joiningMeetings)
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("join.confirm")
        let cancel = Button("Abbrechen") { dismiss() }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(model.joiningMeetings)
            .keyboardShortcut(.cancelAction)
        if Platform.isMobile {
            VStack(spacing: 10) {
                join
                cancel.frame(maxWidth: .infinity)
            }
        } else {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                cancel
                join
            }
        }
    }
}
