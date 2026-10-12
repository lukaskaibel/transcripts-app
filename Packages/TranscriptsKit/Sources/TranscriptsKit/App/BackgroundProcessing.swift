#if os(iOS)
import BackgroundTasks
import Foundation

/// Keeps a meeting's processing going after the user leaves the app, as iOS 26 allows for work a person started:
/// the system shows its progress, and the app may run until it is done. Without it the app would stop with the screen
/// locked and carry on only when it is opened again.
@MainActor
final class BackgroundProcessing {
    static let shared = BackgroundProcessing()

    private var task: BGContinuedProcessingTask?
    private var identifier: String?
    private var finished = false

    /// Asks iOS to let processing continue in the background. Nothing happens if the system says no; the processing
    /// then runs while the app is open, as before.
    func begin(title: String, subtitle: String) {
        guard identifier == nil else { return }
        let identifier = "\(Bundle.main.bundleIdentifier ?? "com.lukaskbl.Transcripts").processing.\(UUID().uuidString)"
        self.identifier = identifier
        finished = false
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success: false)
                    return
                }
                if self.finished || self.identifier != identifier {
                    task.setTaskCompleted(success: true)
                    return
                }
                self.task = task
                task.progress.totalUnitCount = 100
                task.expirationHandler = { [weak self] in
                    // The user stopped it, or the system needs the room: the meeting stays in line and goes on the
                    // next time the app runs.
                    Task { @MainActor in self?.task = nil }
                }
            }
        }
        guard registered else {
            Log.app.error("Background processing isn't permitted (BGTaskSchedulerPermittedIdentifiers)")
            self.identifier = nil
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Log.app.info("No background processing for now: \(error.localizedDescription)")
            self.identifier = nil
        }
    }

    /// How far it is, for the system's progress view.
    func update(fraction: Double, title: String, subtitle: String) {
        guard let task else { return }
        task.progress.completedUnitCount = Int64(min(max(fraction, 0), 1) * 100)
        task.updateTitle(title, subtitle: subtitle)
    }

    func end(success: Bool) {
        finished = true
        task?.progress.completedUnitCount = 100
        task?.setTaskCompleted(success: success)
        task = nil
        identifier = nil
    }
}
#endif
