import Foundation

/// Whether two task texts name the same task, so a new summary can take over what the user did with the old one.
public enum TaskMatching {
    private static let stopwords: Set<String> = [
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen", "einem", "einer", "und", "oder", "für", "fur",
        "mit", "von", "vom", "zum", "zur", "im", "in", "am", "an", "auf", "aus", "bei", "bis", "nach", "noch", "mal",
        "the", "a", "an", "and", "or", "for", "with", "of", "to", "in", "on", "at", "by",
    ]

    static func words(_ text: String) -> Set<String> {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        let parts = folded.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return Set(parts.filter { $0.count >= 2 && !stopwords.contains($0) }.map(stem))
    }

    /// Cuts common German and English endings, so "Formulars" and "Formular" count as one word.
    static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        for ending in ["ungen", "ung", "en", "er", "es", "e", "s", "n"] where word.hasSuffix(ending) && word.count - ending.count >= 4 {
            return String(word.dropLast(ending.count))
        }
        return word
    }

    /// 0…1: how much two texts share, weighted towards the shorter one.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let left = words(a), right = words(b)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        let shared = Double(left.intersection(right).count)
        let jaccard = shared / Double(left.union(right).count)
        let containment = shared / Double(min(left.count, right.count))
        return 0.5 * jaccard + 0.5 * containment
    }
}
