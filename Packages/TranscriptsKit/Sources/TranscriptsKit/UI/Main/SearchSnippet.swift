import SwiftUI

/// Search snippets from the database mark the match with «»; shown, the match is in the accent colour instead.
/// The Mac's command palette and the search on iPhone and iPad show them the same way.
enum SearchSnippet {
    static func attributed(_ text: String) -> AttributedString {
        guard text.contains("«") else { return AttributedString(text) }
        var result = AttributedString()
        var inMatch = false
        var current = ""
        for character in text {
            if character == "«" || character == "»" {
                var piece = AttributedString(current)
                if inMatch {
                    piece.foregroundColor = Theme.accent
                    piece.font = .uiSemibold
                }
                result += piece
                current = ""
                inMatch = character == "«"
            } else {
                current.append(character)
            }
        }
        result += AttributedString(current)
        return result
    }
}
