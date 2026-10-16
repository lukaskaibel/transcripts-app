#if os(iOS)
import SwiftUI

/// The tabs of the app, in the order of the Mac's sidebar. On the iPhone they sit in the tab bar, on a wide iPad
/// they form a sidebar, as in Issues for GitHub.
enum MobileTab: String, Hashable {
    case inbox
    case meetings
    case tasks
    case people
    case search
}

/// A screen pushed onto a tab's navigation stack.
enum Route: Hashable {
    case meeting(String)
    case person(String)
}

/// Sheets the whole window can show, whichever tab asked for them.
enum MobileSheet: Identifiable, Equatable {
    case settings(AppModel.SettingsTab?)
    /// Naming voices, those of one meeting first or all of them.
    case naming(meetingId: String?)
    /// A calendar meeting that hasn't been recorded: who is invited, record or join.
    case upcoming(UpcomingMeeting)

    var id: String {
        switch self {
        case .settings: "settings"
        case .naming(let meetingId): "naming-\(meetingId ?? "-")"
        case .upcoming(let meeting): "upcoming-\(meeting.id)"
        }
    }
}

/// Navigation of one window: the selected tab and the stack of screens in each.
@MainActor
@Observable
final class MobileNavigation {
    var tab: MobileTab {
        didSet { if tab != oldValue { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) } }
    }
    private var paths: [MobileTab: [Route]] = [:]
    var sheet: MobileSheet?
    /// The recording screen, over everything else.
    var showsLive = false
    /// On a wide iPad a list and a meeting sit side by side; these are the meetings beside each list.
    var meetingInSplit: [MobileTab: String] = [:]
    /// The person beside the list of people on a wide iPad.
    var personInSplit: String?
    /// Whether the window is wide enough for the sidebar and the side-by-side lists.
    private(set) var regular = false
    /// Whether the iPad's sidebar is on screen, with its own record button; the bar above the tab bar steps back
    /// meanwhile.
    var sidebarVisible = false
    /// What is typed into the search tab's field.
    var searchQuery = ""
    /// Bumped to ask the search tab to put the cursor in its field (⌘K).
    var searchFocusRequest = 0

    private static let tabKey = "mobile.tab"

    init() {
        tab = UserDefaults.standard.string(forKey: Self.tabKey).flatMap(MobileTab.init(rawValue:)) ?? .meetings
    }

    func path(for tab: MobileTab) -> [Route] {
        paths[tab] ?? []
    }

    func setPath(_ path: [Route], for tab: MobileTab) {
        paths[tab] = path
    }

    func push(_ route: Route, on tab: MobileTab) {
        setPath(path(for: tab) + [route], for: tab)
    }

    /// Goes back one screen in the selected tab (⌘[ on an iPad keyboard).
    func pop() {
        var path = path(for: tab)
        guard !path.isEmpty else { return }
        path.removeLast()
        setPath(path, for: tab)
    }

    /// Opens a meeting where the user is: beside the list on a wide iPad, on top of the tab's stack otherwise.
    func open(meeting id: String) {
        if regular, [.meetings, .inbox].contains(tab) {
            setPath([], for: tab)
            meetingInSplit[tab] = id
        } else if case .meeting(id)? = path(for: tab).last {
            return
        } else {
            push(.meeting(id), on: tab)
        }
    }

    func open(person id: String) {
        if regular, tab == .people {
            setPath([], for: .people)
            personInSplit = id
        } else {
            push(.person(id), on: tab)
        }
    }

    /// The meeting on screen in the selected tab, for the keyboard commands.
    var currentMeetingId: String? {
        if case .meeting(let id)? = path(for: tab).last { return id }
        return regular ? meetingInSplit[tab] : nil
    }

    func adapt(regular: Bool) {
        guard regular != self.regular else { return }
        self.regular = regular
        if regular {
            // A meeting pushed on the iPhone layout moves beside the list.
            for listTab in [MobileTab.meetings, .inbox] {
                if case .meeting(let id)? = path(for: listTab).first {
                    meetingInSplit[listTab] = id
                    setPath(Array(path(for: listTab).dropFirst()), for: listTab)
                }
            }
            if case .person(let id)? = path(for: .people).first {
                personInSplit = id
                setPath(Array(path(for: .people).dropFirst()), for: .people)
            }
        } else {
            for listTab in [MobileTab.meetings, .inbox] {
                if let id = meetingInSplit[listTab] {
                    setPath([.meeting(id)] + path(for: listTab), for: listTab)
                    meetingInSplit[listTab] = nil
                }
            }
            if let id = personInSplit {
                setPath([.person(id)] + path(for: .people), for: .people)
                personInSplit = nil
            }
        }
    }

    /// Takes the screens of a meeting that was deleted off every stack.
    func forget(meeting id: String) {
        for (tab, path) in paths {
            paths[tab] = path.filter { $0 != .meeting(id) }
        }
        for (tab, meeting) in meetingInSplit where meeting == id {
            meetingInSplit[tab] = nil
        }
    }

    func forget(person id: String) {
        for (tab, path) in paths {
            paths[tab] = path.filter { $0 != .person(id) }
        }
        if personInSplit == id { personInSplit = nil }
    }
}

/// Pushes a screen onto the navigation stack the view sits in.
struct OpenRouteAction {
    var action: (Route) -> Void
    func callAsFunction(_ route: Route) { action(route) }
}

extension EnvironmentValues {
    @Entry var openRoute = OpenRouteAction { _ in }
    /// A wide iPad window: the sidebar, lists beside the meeting, and a meeting's facts and voices in a column.
    /// An iPhone keeps its own layout even where it is wide, as a large one is in landscape.
    @Entry var wideLayout = false
}
#endif
