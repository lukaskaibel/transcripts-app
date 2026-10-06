import Foundation
import Observation

/// A call app that is using the microphone.
public struct DetectedCall: Equatable, Sendable {
    public var bundleID: String
    public var appName: String
}

/// Notices when a call app starts and stops using the microphone.
///
/// Core Audio reports which processes run audio input. A known call app (or a browser, for Meet and
/// Teams on the web) that keeps the microphone open for a few seconds counts as a call; when it lets
/// go for a while, the call is over.
@MainActor
@Observable
public final class CallDetector {
    public private(set) var activeCall: DetectedCall?

    public var onCallStarted: ((DetectedCall) -> Void)?
    public var onCallEnded: ((DetectedCall) -> Void)?

    private var timer: Task<Void, Never>?
    private var candidateSince: Date?
    private var candidate: DetectedCall?
    private var quietSince: Date?

    static let startDelay: TimeInterval = 4
    static let endDelay: TimeInterval = 20

    /// Bundle identifier prefixes of apps people take calls in.
    nonisolated static let knownApps: [(prefix: String, name: String)] = [
        ("us.zoom.", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.cisco.webex", "Webex"),
        ("com.webex.", "Webex"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("com.skype.", "Skype"),
        ("com.google.Chrome", "Google Chrome"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave"),
        ("com.apple.WebKit", "Safari"),
        ("com.apple.Safari", "Safari"),
    ]

    public init() {}

    public func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.scan()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    nonisolated static func callApp(for bundleID: String) -> String? {
        knownApps.first { bundleID.hasPrefix($0.prefix) }?.name
    }

    private func scan() {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        let current = AudioSystem.processes()
            .filter { $0.isRunningInput && $0.pid != ownPid }
            .compactMap { process in Self.callApp(for: process.bundleID).map { DetectedCall(bundleID: process.bundleID, appName: $0) } }
            .first
        update(with: current, now: Date())
    }

    /// The state machine, separate from Core Audio so it can be tested.
    func update(with current: DetectedCall?, now: Date) {
        if let current {
            quietSince = nil
            if activeCall != nil { return }
            if candidate?.appName != current.appName {
                candidate = current
                candidateSince = now
            } else if let since = candidateSince, now.timeIntervalSince(since) >= Self.startDelay {
                activeCall = current
                candidate = nil
                onCallStarted?(current)
            }
        } else {
            candidate = nil
            candidateSince = nil
            guard let active = activeCall else { return }
            if let quietSince {
                if now.timeIntervalSince(quietSince) >= Self.endDelay {
                    activeCall = nil
                    self.quietSince = nil
                    onCallEnded?(active)
                }
            } else {
                quietSince = now
            }
        }
    }
}
