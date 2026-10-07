import AppKit
import SwiftUI

/// The main window.
public struct RootView: View {
    @Environment(AppModel.self) private var model

    public init() {}

    public var body: some View {
        ZStack {
            Theme.window.ignoresSafeArea()
            if model.settings.onboardingDone {
                MainLayout()
                    .transition(.opacity)
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .frame(minWidth: 940, minHeight: 600)
        .font(.ui)
        .foregroundStyle(Theme.text)
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
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: Theme.sidebarWidth)
            ContentPanel()
        }
        .ignoresSafeArea()
        .overlay { OverlayHost() }
    }
}

struct ContentPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            switch model.section {
            case .meetings:
                if let detail = model.detail, model.selectedMeetingId == detail.meeting.id {
                    MeetingDetailView(detail: detail)
                        .id(detail.meeting.id)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(x: 14)),
                            removal: .opacity.combined(with: .offset(x: 14))
                        ))
                } else {
                    MeetingListView()
                        .transition(.opacity)
                }
            case .people:
                PeopleView()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .panelStyle()
        .padding(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 8))
        .animation(Theme.overlay, value: model.selectedMeetingId)
        .animation(Theme.overlay, value: model.section)
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
                    .padding(.top, 110)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -6)))
            }
            if case .naming(let meetingId) = model.overlay {
                Theme.scrim
                    .ignoresSafeArea()
                    .onTapGesture { model.overlay = nil }
                    .transition(.opacity)
                NameVoicesPanel(meetingId: meetingId)
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
                        .buttonStyle(PrimaryButtonStyle())
                        .fixedSize()
                    }
                    IconButton(systemName: "xmark", label: String(localized: "Schließen"), size: 20) { model.dismissToast(toast.id) }
                }
                .padding(.vertical, 12)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(width: 360, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.popover))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.popoverBorder, lineWidth: 1))
                .shadow(color: Theme.shadow, radius: 18, y: 10)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 12)), removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
        }
        .animation(Theme.overlay, value: model.toasts)
    }
}
