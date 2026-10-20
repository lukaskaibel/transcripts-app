#if os(iOS)
import SwiftUI
import UIKit

/// The app on iPhone and iPad. The app target only has to show this scene.
public struct TranscriptsScene: Scene {
    @State private var model: AppModel

    public init() {
        _model = State(initialValue: Self.launchModel)
    }

    /// The app's one model. SwiftUI creates the scene more than once at launch; each extra model would open the
    /// database again, start its own observers and, in the demo, wipe and seed its data once more.
    @MainActor private static let launchModel = AppModel.makeForLaunch()

    public var body: some Scene {
        WindowGroup {
            MobileRoot()
                .environment(model)
        }
        .commands {
            MobileCommands(model: model)
        }
    }
}

/// One window: the tabs (or the iPad's sidebar) once set up, the first-start screen before.
struct MobileRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = MobileNavigation()

    private var wide: Bool {
        sizeClass == .regular && UIDevice.current.userInterfaceIdiom == .pad
    }

    var body: some View {
        @Bindable var navigation = navigation
        ZStack {
            Theme.panel.ignoresSafeArea()
            if model.settings.onboardingDone {
                MainTabs()
                    .transition(.opacity)
            } else {
                MobileOnboarding()
                    .transition(.opacity)
            }
        }
        .animation(Theme.overlay, value: model.settings.onboardingDone)
        .environment(navigation)
        .environment(\.wideLayout, wide)
        .focusedSceneValue(\.mobileNavigation, navigation)
        .tint(Theme.accent)
        .background(WindowAppearance(setting: model.settings.appearance))
        .sheet(item: $navigation.sheet) { sheet in
            switch sheet {
            case .settings(let tab):
                SettingsScreen(start: tab)
            case .naming(let meetingId):
                NamingSheet(meetingId: meetingId)
            case .upcoming(let meeting):
                UpcomingSheet(meeting: meeting)
            case .joining(let meetingId):
                JoinMeetingsSheet(meetingId: meetingId) { joined in
                    // The later meetings are gone: where one of them was open, the meeting they are in now is.
                    let wasOpen = joined.dropFirst().contains(where: navigation.isOpen(meeting:))
                    for id in joined.dropFirst() { navigation.forget(meeting: id) }
                    if wasOpen, let first = joined.first { navigation.open(meeting: first) }
                }
            }
        }
        .fullScreenCover(isPresented: $navigation.showsLive) {
            LiveScreen()
                .environment(model)
                .environment(navigation)
                .environment(\.wideLayout, wide)
        }
        .overlay(alignment: .top) {
            MobileToasts(navigation: navigation)
        }
        .modifier(NamePromptHost())
        .task { model.launch() }
        .onChange(of: scenePhase) { _, phase in
            // Permissions may have changed in the Settings app.
            if phase == .active { model.refreshPermissions() }
        }
        .onChange(of: wide, initial: true) { _, wide in navigation.adapt(regular: wide) }
        .onChange(of: model.navigationRequestCount) { follow(model.navigationRequest) }
        .onChange(of: model.windowRequestCount) { follow(model.windowRequest) }
        .onChange(of: model.overlay) { _, overlay in follow(overlay) }
        .onChange(of: model.recording == nil) { _, stopped in
            if stopped { navigation.showsLive = false }
        }
        .onChange(of: processing) { _, processing in
            guard let processing else { return }
            BackgroundProcessing.shared.update(fraction: processing.meeting.progress, title: String(localized: "Meeting wird verarbeitet"),
                                               subtitle: [processing.meeting.title, processing.meeting.processingStep].compactMap { $0 }.joined(separator: " · "))
        }
        .onChange(of: model.openPersonId) { _, personId in
            guard let personId else { return }
            model.openPersonId = nil
            navigation.tab = .people
            navigation.open(person: personId)
        }
    }

    /// The meeting being processed, with its progress, for the system's view of the background processing.
    private var processing: MeetingRow? {
        model.processingMeetingId.flatMap { model.row(for: $0) }
    }

    private func follow(_ request: AppModel.NavigationRequest?) {
        switch request {
        case .meeting(let id)?:
            navigation.sheet = nil
            // From the recording screen or a toast: the meeting shows where the user is.
            navigation.showsLive = false
            navigation.open(meeting: id)
        case .section(let section)?:
            navigation.tab = switch section {
            case .inbox: .inbox
            case .meetings: .meetings
            case .tasks: .tasks
            case .people: .people
            }
        case nil:
            break
        }
    }

    private func follow(_ request: AppModel.WindowRequest?) {
        switch request {
        case .live?:
            if model.recording != nil { navigation.showsLive = true }
        case .settings(let tab)?:
            navigation.showsLive = false
            navigation.sheet = .settings(tab)
        case .main?, nil:
            break
        }
    }

    private func follow(_ overlay: AppModel.Overlay?) {
        switch overlay {
        case .naming(let meetingId)?:
            navigation.showsLive = false
            navigation.sheet = .naming(meetingId: meetingId)
        case .joining(let meetingId)?:
            navigation.sheet = .joining(meetingId: meetingId)
        case .palette?:
            model.overlay = nil
            navigation.tab = .search
            navigation.searchFocusRequest += 1
        case nil:
            switch navigation.sheet {
            case .naming?, .joining?: navigation.sheet = nil
            default: break
            }
        }
    }
}

/// Puts the appearance chosen in the app on the window, so sheets and popovers follow it too.
private struct WindowAppearance: UIViewRepresentable {
    var setting: Appearance

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let style: UIUserInterfaceStyle = switch setting {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        DispatchQueue.main.async {
            view.window?.overrideUserInterfaceStyle = style
        }
    }
}

// MARK: - Tabs

struct MainTabs: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    @Environment(\.wideLayout) private var wide

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.tab) {
            Tab(AppModel.Section.inbox.title, systemImage: "tray", value: MobileTab.inbox) {
                if wide {
                    MeetingSplit(tab: .inbox) { InboxScreen() }
                } else {
                    TabStack(tab: .inbox) { InboxScreen() }
                }
            }
            .badge(model.inbox.count)
            Tab(AppModel.Section.meetings.title, systemImage: "list.bullet.rectangle", value: MobileTab.meetings) {
                if wide {
                    MeetingSplit(tab: .meetings) { MeetingsScreen() }
                } else {
                    TabStack(tab: .meetings) { MeetingsScreen() }
                }
            }
            Tab(AppModel.Section.tasks.title, systemImage: "checkmark.circle", value: MobileTab.tasks) {
                TabStack(tab: .tasks) { TasksScreen() }
            }
            Tab(AppModel.Section.people.title, systemImage: "person.2", value: MobileTab.people) {
                if wide {
                    PeopleSplit()
                } else {
                    TabStack(tab: .people) { PeopleScreen() }
                }
            }
            Tab(value: MobileTab.search, role: .search) {
                TabStack(tab: .search) { SearchScreen() }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .recordAccessory(enabled: !navigation.sidebarVisible) {
            RecordAccessory()
                .environment(model)
                .environment(navigation)
        }
        // The sidebar's header is hosted on its own when the sidebar first appears (an iPad turning to landscape);
        // it gets the model and navigation handed on explicitly, or it would find none.
        .tabViewSidebarHeader {
            SidebarHeader()
                .environment(model)
                .environment(navigation)
                // The header is only there while the sidebar is.
                .onAppear { navigation.sidebarVisible = true }
                .onDisappear { navigation.sidebarVisible = false }
        }
        .tabViewSidebarBottomBar {
            SidebarStatus()
                .environment(model)
                .environment(navigation)
        }
    }
}

extension View {
    /// The record bar above the tab bar, left out where the iPad's sidebar shows the record button (from iOS 26.1;
    /// before, it stays).
    @ViewBuilder
    func recordAccessory<Content: View>(enabled: Bool, @ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.1, *) {
            tabViewBottomAccessory(isEnabled: enabled, content: content)
        } else {
            tabViewBottomAccessory(content: content)
        }
    }
}

/// A tab's navigation stack, with every screen of the app reachable from it.
struct TabStack<Root: View>: View {
    @Environment(MobileNavigation.self) private var navigation
    var tab: MobileTab
    @ViewBuilder var root: Root

    var body: some View {
        NavigationStack(path: Binding(
            get: { navigation.path(for: tab) },
            set: { navigation.setPath($0, for: tab) }
        )) {
            root
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route)
                }
        }
        .environment(\.openRoute, OpenRouteAction { [navigation] route in navigation.push(route, on: tab) })
    }
}

/// The screen a route leads to, in any tab's stack.
struct RouteDestination: View {
    var route: Route

    var body: some View {
        switch route {
        case .meeting(let id): MeetingScreen(meetingId: id)
        case .person(let id): PersonScreen(personId: id)
        }
    }
}

/// On a wide iPad: a list of meetings (or the inbox) with the meeting picked from it beside, as on the Mac.
struct MeetingSplit<List: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation
    var tab: MobileTab
    @ViewBuilder var list: List

    var body: some View {
        NavigationSplitView {
            // Handed on explicitly: the split's columns are hosted anew when the window turns and the tab bar
            // becomes a sidebar, and must not lose them on the way.
            list
                .environment(model)
                .environment(navigation)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 440)
        } detail: {
            NavigationStack(path: Binding(get: { navigation.path(for: tab) }, set: { navigation.setPath($0, for: tab) })) {
                Group {
                    if let id = navigation.meetingInSplit[tab], model.row(for: id) != nil {
                        MeetingScreen(meetingId: id)
                            .id(id)
                    } else {
                        MobileEmptyState(
                            systemImage: tab == .inbox ? "tray" : "waveform",
                            title: String(localized: "Kein Meeting ausgewählt"),
                            message: tab == .inbox
                                ? String(localized: "Wähle links etwas aus dem Eingang.")
                                : String(localized: "Wähle links ein Meeting oder nimm ein neues auf.")
                        )
                        .background(Theme.panel)
                    }
                }
                .navigationDestination(for: Route.self) { route in
                    RouteDestination(route: route)
                }
            }
            .environment(\.openRoute, OpenRouteAction { [navigation] route in navigation.push(route, on: tab) })
            .environment(model)
            .environment(navigation)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

// MARK: - iPad sidebar

/// At the top of the iPad's sidebar, as at the top of the Mac's: the record button, and the settings.
struct SidebarHeader: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation

    var body: some View {
        HStack(spacing: 8) {
            MobileRecordButton()
            Button {
                navigation.sheet = .settings(nil)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .contentShape(.hoverEffect, Circle().inset(by: 3))
                    .hoverEffect(.highlight)
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityLabel(Text("Einstellungen"))
            .accessibilityIdentifier("settings")
        }
        .padding(.trailing, -10)
    }
}

/// The record button in the iPad's sidebar: start, or the running recording with its time and a stop button.
struct MobileRecordButton: View {
    @Environment(AppModel.self) private var model
    @Environment(MobileNavigation.self) private var navigation

    var body: some View {
        if let session = model.recording {
            HStack(spacing: 8) {
                Button {
                    navigation.showsLive = true
                } label: {
                    HStack(spacing: 10) {
                        RecordingDot(size: 9)
                        Text(TimeFormat.clock(session.elapsed)).font(.uiMedium).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainPressStyle())
                .accessibilityLabel(Text("Aufnahme läuft"))
                .accessibilityValue(TimeFormat.clock(session.elapsed))
                .accessibilityHint(Text("Zeigt das Live-Transkript"))
                .accessibilityIdentifier("live.open")
                Button {
                    Task { await model.stopRecording() }
                } label: {
                    RoundedRectangle(cornerRadius: 2.5).fill(.white).frame(width: 11, height: 11)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Theme.recordingFill))
                }
                .buttonStyle(PlainPressStyle())
                .accessibilityLabel(Text("Aufnahme beenden"))
                .accessibilityIdentifier("record.stop")
                .padding(.trailing, 6)
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.recording.opacity(0.45), lineWidth: 1))
        } else {
            Button {
                Task { await model.startRecording() }
            } label: {
                HStack(spacing: 11) {
                    Circle().fill(Theme.recording).frame(width: 10, height: 10).padding(.horizontal, 2)
                    Text("Aufnehmen").font(.uiMedium)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cardBorder, lineWidth: 1))
                .contentShape(Rectangle())
                .contentShape(.hoverEffect, .rect(cornerRadius: 12))
                .hoverEffect(.highlight)
            }
            .buttonStyle(PlainPressStyle())
            .accessibilityIdentifier("record")
        }
    }
}

/// What the app is doing, at the bottom of the iPad's sidebar, as at the bottom of the Mac's.
struct SidebarStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        EngineStatusLine()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Keyboard and menu bar

extension FocusedValues {
    @Entry var mobileNavigation: MobileNavigation?
}

/// The iPad's menu bar and keyboard shortcuts: the same commands as the Mac's menus.
struct MobileCommands: Commands {
    var model: AppModel
    @FocusedValue(\.mobileNavigation) private var navigation

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(model.isRecording ? "Aufnahme beenden" : "Aufnahme starten") { model.toggleRecording() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!model.settings.onboardingDone)
            Button("Pause / Fortsetzen") { model.togglePause() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(!model.isRecording)
            Button("Markierung setzen") { model.recording?.addMarker("") }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!model.isRecording)
        }
        CommandMenu("Gehe zu") {
            let unavailable = navigation == nil || !model.settings.onboardingDone
            Button("Suchen …") {
                navigation?.tab = .search
                navigation?.searchFocusRequest += 1
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(unavailable)
            Divider()
            Button(AppModel.Section.inbox.title) { navigation?.tab = .inbox }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(unavailable)
            Button("Alle Meetings") { navigation?.tab = .meetings }
                .keyboardShortcut("2", modifiers: .command)
                .disabled(unavailable)
            Button(AppModel.Section.tasks.title) { navigation?.tab = .tasks }
                .keyboardShortcut("3", modifiers: .command)
                .disabled(unavailable)
            Button(AppModel.Section.people.title) { navigation?.tab = .people }
                .keyboardShortcut("4", modifiers: .command)
                .disabled(unavailable)
            Button("Live-Fenster") { navigation?.showsLive = model.isRecording }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!model.isRecording)
            Divider()
            Button("Zurück") { navigation?.pop() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(unavailable)
        }
    }
}
#endif
