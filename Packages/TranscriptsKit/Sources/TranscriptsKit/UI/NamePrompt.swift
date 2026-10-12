import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Asks for a name: a small panel on the Mac, an alert with a text field on iPhone and iPad (shown by the
/// window's root, which watches `NamePrompt.center`). Calls `completion` only with a name that isn't empty.
@MainActor
enum NamePrompt {
    struct Request: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var initial: String
        var completion: (String) -> Void
    }

    /// The question waiting for an answer on iPhone and iPad.
    @MainActor
    @Observable
    final class Center {
        var request: Request?
    }

    static let center = Center()

    static func ask(title: String, message: String, initial: String = "", completion: @escaping (String) -> Void) {
        #if os(macOS)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Speichern"))
        alert.addButton(withTitle: String(localized: "Abbrechen"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = String(localized: "Name")
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { completion(name) }
        #else
        center.request = Request(title: title, message: message, initial: initial, completion: completion)
        #endif
    }

    /// Asks who a voice is and gives it to a new person of that name.
    static func newPerson(for speaker: MeetingSpeaker, model: AppModel) {
        ask(title: String(localized: "Wer ist \(speaker.displayLabel)?"),
            message: String(localized: "Die Stimme wird gemerkt und in künftigen Meetings wiedererkannt."),
            initial: speaker.suggestedName ?? "") { name in
            model.assign(speaker, toNewPersonNamed: name)
        }
    }
}

#if os(iOS)
/// Shows the name prompt on iPhone and iPad.
struct NamePromptHost: ViewModifier {
    @State private var draft = ""

    func body(content: Content) -> some View {
        let center = NamePrompt.center
        content
            .alert(
                center.request?.title ?? "",
                isPresented: Binding(get: { center.request != nil }, set: { if !$0 { center.request = nil } }),
                presenting: center.request
            ) { request in
                TextField(String(localized: "Name"), text: $draft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                Button(String(localized: "Abbrechen"), role: .cancel) { center.request = nil }
                Button(String(localized: "Speichern")) {
                    let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    center.request = nil
                    if !name.isEmpty { request.completion(name) }
                }
            } message: { request in
                Text(request.message)
            }
            .onChange(of: center.request?.id) { draft = center.request?.initial ?? "" }
    }
}
#endif
