#if os(iOS)
import SwiftUI

// MARK: - Rows

/// One meeting in a list: its state, the title over two lines, and a line of details underneath, with the voices
/// on the right. The same pieces as the Mac's row, folded for a narrow screen.
struct MobileMeetingRow: View {
    @Environment(AppModel.self) private var model
    var row: MeetingRow
    /// The day goes into the details where the list isn't grouped by day (search, a person's meetings).
    var showsDay = false
    @ScaledMetric(relativeTo: .callout) private var glyphSize: CGFloat = 16

    private var peopleById: [String: Person] {
        Dictionary(uniqueKeysWithValues: model.people.map { ($0.id, $0) })
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            MeetingGlyph(state: row.glyph, size: glyphSize)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(row.meeting.title)
                    .font(.uiMedium)
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                details
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !row.speakers.isEmpty {
                AvatarStack(kinds: row.avatarKinds(people: peopleById), size: 22, limit: 3, ring: Theme.panel)
                    .padding(.top, 1)
            }
        }
        .padding(.vertical, 11)
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("meeting-\(row.id)")
    }

    private var details: some View {
        HStack(spacing: 7) {
            Text(when).monospacedDigit()
            if row.meeting.status == .processing {
                Text(row.meeting.processingStep ?? String(localized: "Wird verarbeitet"))
                    .foregroundStyle(Theme.warning)
            } else if row.meeting.status == .failed {
                Text("Fehler bei der Verarbeitung").foregroundStyle(Theme.warning)
            } else if row.meeting.status == .recording {
                Text(String(localized: "läuft", comment: "in place of a meeting's duration: it is being recorded right now"))
                    .foregroundStyle(Theme.recording)
            } else {
                Text(TimeFormat.duration(row.meeting.duration)).monospacedDigit()
            }
            if let source = row.meeting.source {
                Text(source)
            }
            if row.pendingVoices > 0, row.meeting.status == .ready {
                DotChip(text: String(localized: "\(row.pendingVoices) Stimmen offen", comment: "plural: voices in a meeting still waiting for a name"), color: Theme.warning)
            }
        }
        .font(.small)
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.86), .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
    }

    private var when: String {
        showsDay ? "\(TimeFormat.compactDay(row.meeting.startedAt)), \(TimeFormat.time(row.meeting.startedAt))" : TimeFormat.time(row.meeting.startedAt)
    }

    private var accessibilityText: String {
        var parts = [row.meeting.title, when]
        switch row.meeting.status {
        case .ready: parts.append(TimeFormat.duration(row.meeting.duration))
        case .processing: parts.append(row.meeting.processingStep ?? String(localized: "Wird verarbeitet"))
        case .failed: parts.append(String(localized: "Fehler bei der Verarbeitung"))
        case .recording: parts.append(String(localized: "Aufnahme läuft"))
        }
        if let source = row.meeting.source { parts.append(source) }
        if row.pendingVoices > 0 {
            parts.append(String(localized: "\(row.pendingVoices) Stimmen offen", comment: "plural: voices in a meeting still waiting for a name"))
        }
        return parts.joined(separator: ", ")
    }
}

/// A list row that highlights while pressed, as a system row does, without tinting its text.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.selected : Color.clear)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
    }
}

/// The heading over a group of rows: a day, "Heute", "Zu bestätigen".
struct MobileSectionHeader<Trailing: View>: View {
    var title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.uiSemibold).foregroundStyle(Theme.text)
                if let count {
                    Text("\(count)").font(.ui).monospacedDigit().foregroundStyle(Theme.textTertiary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.groupHeader))
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .accessibilityElement(children: .contain)
    }
}

extension MobileSectionHeader where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// A thin line between rows, starting where their text does.
struct RowDivider: View {
    var leading: CGFloat = 48

    var body: some View {
        Rectangle().fill(Theme.rowSeparator).frame(height: 1).padding(.leading, leading)
    }
}

// MARK: - Empty and waiting

/// An empty or waiting screen: a line of explanation, sometimes with a button.
struct MobileEmptyState<Accessory: View>: View {
    var systemImage: String?
    var title: String
    var message: String
    var showsProgress = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 10) {
            if showsProgress {
                ProgressView().padding(.bottom, 4)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 4)
            }
            Text(title).font(.headline).foregroundStyle(Theme.text).multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            accessory.padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MobileEmptyState where Accessory == EmptyView {
    init(systemImage: String? = nil, title: String, message: String, showsProgress: Bool = false) {
        self.init(systemImage: systemImage, title: title, message: message, showsProgress: showsProgress) { EmptyView() }
    }
}

// MARK: - Status

/// The dot and the words of what the app is doing: "Bereit · alles lokal", "Wird verarbeitet · 40 %".
struct EngineStatusLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator()
                .frame(minWidth: 12)
            Text(model.statusText)
                .font(.small)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.statusText)
        .accessibilityHint(model.statusHelp)
    }
}

// MARK: - Toolbar

/// The settings button at the top of each tab's first screen (the iPad's sidebar has its own).
struct SettingsToolbarItem: ToolbarContent {
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.wideLayout) private var wide

    var body: some ToolbarContent {
        if !wide {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    navigation.sheet = .settings(nil)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel(Text("Einstellungen"))
                .accessibilityIdentifier("settings")
            }
        }
    }
}

// MARK: - Recording

/// Above the tab bar on the iPhone, like the song that plays in Music: the way to start a recording from any tab,
/// and while one runs, its time, level, pause and stop. Tapping it opens the live transcript.
struct RecordAccessory: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let session = model.recording {
            recording(session)
        } else {
            idle
        }
    }

    private var inline: Bool { placement == .inline }

    private var idle: some View {
        Button {
            Task { await model.startRecording() }
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Theme.recording)
                    .frame(width: 14, height: 14)
                    .padding(5)
                    .overlay(Circle().stroke(Theme.recording.opacity(0.35), lineWidth: 2))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Aufnehmen").font(.uiSemibold).foregroundStyle(Theme.text)
                    if !inline, let next = model.imminentMeeting {
                        Text(next.title).font(.small).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainPressStyle())
        .accessibilityLabel(Text("Aufnahme starten"))
        .accessibilityValue(model.imminentMeeting?.title ?? "")
        .accessibilityIdentifier("record")
    }

    private func recording(_ session: RecordingSession) -> some View {
        HStack(spacing: 10) {
            Button {
                navigation.showsLive = true
            } label: {
                HStack(spacing: 10) {
                    if session.state == .paused {
                        Image(systemName: "pause.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textSecondary)
                            .frame(width: 14)
                    } else {
                        RecordingDot(size: 9).frame(width: 14)
                    }
                    Text(TimeFormat.clock(session.elapsed))
                        .font(.uiSemibold)
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                    if !inline {
                        Text(session.title)
                            .font(.small)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        LevelBars(level: session.microphoneLevel, color: Theme.textSecondary, height: 14)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(Text("Aufnahme läuft"))
            .accessibilityValue("\(TimeFormat.clock(session.elapsed)), \(session.title)")
            .accessibilityHint(Text("Zeigt das Live-Transkript"))
            .accessibilityIdentifier("live.open")
            if !inline {
                Button {
                    model.togglePause()
                } label: {
                    Image(systemName: session.state == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(PlainPressStyle())
                .accessibilityLabel(session.state == .paused ? Text("Fortsetzen") : Text("Pause"))
            }
            Button {
                Task { await model.stopRecording() }
            } label: {
                RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 11, height: 11)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Theme.recordingFill))
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(Text("Aufnahme beenden"))
            .accessibilityIdentifier("record.stop")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
    }
}

// MARK: - Toasts

/// The model's toasts at the top of the window: what just happened, sometimes with a button.
struct MobileToasts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(toast.isError ? Theme.warning : Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(toast.title).font(.uiSemibold).foregroundStyle(Theme.text)
                        if !toast.message.isEmpty {
                            Text(toast.message)
                                .font(.small)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let action = toast.action {
                            Button(action.title) {
                                model.dismissToast(toast.id)
                                model.perform(action)
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .padding(.top, 6)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        model.dismissToast(toast.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainPressStyle())
                    .accessibilityLabel(Text("Schließen"))
                }
                .padding(.leading, 16)
                .padding(.trailing, 6)
                .padding(.vertical, 12)
                .frame(maxWidth: 520)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.popover))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 1))
                .shadow(color: Theme.shadow, radius: 18, y: 8)
                .padding(.horizontal, 12)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .contain)
                .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                    if value.translation.height < -10 { model.dismissToast(toast.id) }
                })
            }
        }
        .padding(.top, 4)
        .animation(Theme.overlay, value: model.toasts)
    }
}
#endif
