#if os(macOS)
import AppKit
import SwiftUI

/// The main window, built like the system's own and like Notebook: a sidebar, the page, and beside a meeting an
/// inspector.
public struct RootView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        Group {
            if model.settings.onboardingDone {
                MainLayout()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .foregroundStyle(Theme.text)
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 940, minHeight: 600)
        .font(.ui)
        .tint(Theme.accent)
        .animation(Theme.overlay, value: model.settings.onboardingDone)
        .overlay(alignment: .bottomTrailing) {
            ToastStack().padding(20)
        }
    }
}

struct MainLayout: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            DetailColumn()
        }
        .overlay { OverlayHost() }
        .sheet(item: naming) { request in
            NameVoicesPanel(meetingId: request.meetingId)
        }
    }

    /// Naming voices, as a sheet on the window, while the overlay asks for it.
    private var naming: Binding<NamingRequest?> {
        Binding {
            if case .naming(let meetingId) = model.overlay { return NamingRequest(meetingId: meetingId) }
            return nil
        } set: { request in
            if request == nil, case .naming = model.overlay { model.overlay = nil }
        }
    }
}

struct NamingRequest: Identifiable {
    var meetingId: String?
    var id: String { meetingId ?? "" }
}

/// The page for what the sidebar selected.
struct DetailColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.section {
            case .meetings:
                if let detail = model.detail, model.selectedMeetingId == detail.meeting.id {
                    MeetingDetailView(detail: detail)
                        .id(detail.meeting.id)
                } else if model.selectedMeetingId == nil {
                    MeetingListView()
                } else {
                    Color.clear
                }
            case .inbox:
                InboxView()
            case .tasks:
                TasksView()
            case .people:
                PeopleView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.panel.ignoresSafeArea())
        .foregroundStyle(Theme.text)
    }
}

/// Search, where Notebook has its search field. It opens the palette, which finds meetings, people and lines.
struct SearchToolbarItem: ToolbarContent {
    let model: AppModel

    var body: some ToolbarContent {
        ToolbarItem {
            // A plain view: the toolbar draws a button with a label of its own as an icon only.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                Text("Suchen").foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(verbatim: "⌘K").font(.small).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(width: 180, height: 34)
            .contentShape(Capsule())
            .onTapGesture(perform: toggle)
            .help("Suchen (⌘K)")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Suchen")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
        }
    }

    private func toggle() {
        model.overlay = model.overlay == .palette ? nil : .palette
    }
}

/// The dimmed backdrop and the command palette.
struct OverlayHost: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .top) {
            if model.overlay == .palette {
                Theme.scrim
                    .ignoresSafeArea()
                    .onTapGesture { model.overlay = nil }
                    .transition(.opacity)
                CommandPalette()
                    .padding(.top, 80)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -6)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.overlay, value: model.overlay)
    }
}

struct ToastStack: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(model.toasts) { toast in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: toast.isError ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(toast.isError ? Theme.warning : Theme.accent)
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(toast.title).font(.uiSemibold)
                        if !toast.message.isEmpty {
                            Text(toast.message)
                                .font(.small)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                    if let action = toast.action {
                        Button(action.title) {
                            model.dismissToast(toast.id)
                            model.perform(action)
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                    }
                    IconButton(systemName: "xmark", label: String(localized: "Schließen"), size: 20) { model.dismissToast(toast.id) }
                }
                .foregroundStyle(Theme.text)
                .padding(.vertical, 12)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(width: 360, alignment: .leading)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
        }
        .animation(Theme.overlay, value: model.toasts)
    }
}
#endif
