import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The running recording: its title, a clock that runs by itself, and buttons to pause, mark a moment and stop.
struct RecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenRecording(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingBadge(paused: context.state.paused)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RecordingClockText(state: context.state)
                        .font(.title3.weight(.semibold))
                        .frame(maxWidth: 110, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(context.state.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        RecordingStatusText(state: context.state)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    RecordingButtons(state: context.state)
                        .padding(.top, 6)
                }
            } compactLeading: {
                RecordingSymbol(paused: context.state.paused)
            } compactTrailing: {
                RecordingClockText(state: context.state)
                    .font(.caption.weight(.semibold))
                    // Room for an hour and more ("1:02:39").
                    .frame(maxWidth: 58)
                    .foregroundStyle(context.state.paused ? WidgetTheme.paused : WidgetTheme.recording)
            } minimal: {
                RecordingSymbol(paused: context.state.paused)
            }
            .keylineTint(WidgetTheme.recording)
        }
    }
}

/// The Lock Screen's (and the banner's) view of the recording.
struct LockScreenRecording: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RecordingSymbol(paused: state.paused)
                    .font(.headline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .lineLimit(1)
                    RecordingStatusText(state: state)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
                Spacer(minLength: 8)
                RecordingClockText(state: state)
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: 120, alignment: .trailing)
            }
            RecordingButtons(state: state)
        }
        .foregroundStyle(.white)
        .padding(16)
    }
}

/// A clock that counts up by itself while recording and stands still while paused.
struct RecordingClockText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        Text(
            timerInterval: state.clockStart...state.clockStart.addingTimeInterval(24 * 3600),
            pauseTime: state.paused ? state.clockStart.addingTimeInterval(state.elapsed) : nil,
            countsDown: false,
            showsHours: true
        )
        .monospacedDigit()
        .multilineTextAlignment(.trailing)
    }
}

/// "Aufnahme · 2 Markierungen", "Pausiert".
struct RecordingStatusText: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        if state.paused {
            Text("Pausiert", comment: "the recording is paused")
        } else if state.markers > 0 {
            Text("Aufnahme · \(state.markers) Markierungen", comment: "plural: a recording is running, with the number of moments marked so far")
        } else {
            Text("Aufnahme läuft")
        }
    }
}

struct RecordingSymbol: View {
    let paused: Bool

    var body: some View {
        Image(systemName: paused ? "pause.fill" : "waveform")
            .foregroundStyle(paused ? WidgetTheme.paused : WidgetTheme.recording)
            .accessibilityLabel(paused ? Text("Pausiert", comment: "the recording is paused") : Text("Aufnahme läuft"))
    }
}

/// "REC" with a dot, in the expanded Dynamic Island.
struct RecordingBadge: View {
    let paused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(paused ? WidgetTheme.paused : WidgetTheme.recording)
                .frame(width: 8, height: 8)
            Image(systemName: paused ? "pause.fill" : "waveform")
                .font(.headline)
                .foregroundStyle(paused ? WidgetTheme.paused : WidgetTheme.recording)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paused ? Text("Pausiert", comment: "the recording is paused") : Text("Aufnahme läuft"))
    }
}

/// Pause or resume, mark the moment, stop.
struct RecordingButtons: View {
    let state: RecordingActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: PauseRecordingIntent()) {
                Label(state.paused ? String(localized: "Weiter", comment: "button: resume the recording") : String(localized: "Pause", comment: "button: pause the recording"),
                      systemImage: state.paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.white)
            Button(intent: MarkMomentIntent()) {
                Label(String(localized: "Markieren", comment: "button: mark this moment of the recording"), systemImage: "flag.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(.white)
            .disabled(state.paused)
            Button(intent: StopRecordingIntent()) {
                Label(String(localized: "Beenden", comment: "button: stop the recording"), systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .tint(WidgetTheme.recording)
        }
        .font(.subheadline.weight(.semibold))
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .labelStyle(.titleAndIcon)
    }
}

#Preview("Lock Screen", as: .content, using: RecordingActivityAttributes(meetingId: "m1")) {
    RecordingActivityWidget()
} contentStates: {
    RecordingActivityAttributes.ContentState(title: "Sprint Planning 43", clockStart: .now.addingTimeInterval(-754), paused: false, elapsed: 754, markers: 2)
    RecordingActivityAttributes.ContentState(title: "Sprint Planning 43", clockStart: .now.addingTimeInterval(-754), paused: true, elapsed: 754, markers: 2)
}
