import Foundation

/// Removes deadlines a language model added to the to-dos of a meeting summary although the
/// transcript never mentions them. Small on-device models like to fill "(bis Freitag)" behind
/// a to-do even when nobody named a day. In doubt a deadline stays: when one of its words was
/// said, when it is only a number, or when the transcript is not German.
enum InventedDeadlineFilter {
    /// Words that carry no date of their own ("bis spätestens Ende ...").
    private static let fillers: Set<String> = [
        "bis", "zum", "zur", "am", "an", "im", "in", "der", "die", "das", "des", "dem", "den",
        "spätestens", "ca", "etwa", "frist", "termin",
    ]

    /// A bullet ("- ", "* ", "• ", "– ", "1. ") ending in a parenthesis, maybe followed by
    /// punctuation. Group 1 is the bullet without the parenthesis, group 2 its content.
    private static let bulletWithParenthesis = try! NSRegularExpression(
        pattern: #"^(\s*(?:[-*•–]|\d+[.)])\s+.*?)\s*\(([^()]*)\)[\s.,;!]*$"#
    )

    /// - Parameter transcriptIsGerman: The summary is always German. Only a German transcript
    ///   can be compared word by word; "by Friday" would otherwise lose its "(bis Freitag)".
    static func filtered(_ summary: String, transcript: String, transcriptIsGerman: Bool) -> String {
        guard transcriptIsGerman else { return summary }
        let spoken = Set(words(in: transcript))
        var inToDos = false
        return summary
            .components(separatedBy: "\n")
            .map { line in
                if let heading = heading(of: line) {
                    inToDos = heading == "to-dos" || heading == "todos" || heading == "to-do"
                    return line
                }
                return inToDos ? keepingNamedDeadline(line, spoken: spoken) : line
            }
            .joined(separator: "\n")
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// "To-dos", "**To-dos:**" or "## Entscheidungen" become their bare lowercased name.
    private static func heading(of line: String) -> String? {
        let bare = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "#*: ").union(.whitespaces))
            .lowercased()
        let headings = ["zusammenfassung", "entscheidungen", "to-dos", "todos", "to-do"]
        return headings.contains(bare) ? bare : nil
    }

    private static func keepingNamedDeadline(_ line: String, spoken: Set<String>) -> String {
        guard let match = bulletWithParenthesis.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let bullet = Range(match.range(at: 1), in: line),
              let inside = Range(match.range(at: 2), in: line) else { return line }

        // Numbers are not checked: a spoken "dreiundzwanzigsten" can come back as "23.".
        let deadlineWords = words(in: String(line[inside]))
            .filter { $0.count >= 2 && !fillers.contains($0) && !$0.allSatisfy(\.isNumber) }
        guard !deadlineWords.isEmpty else { return line }

        // Whole spoken words, so "ende" is not found in "Kalender". A prefix is enough to
        // keep "Freitag" when someone said "freitags" or "Freitagabend".
        let wasSaid = deadlineWords.contains { word in spoken.contains { $0.hasPrefix(word) } }
        return wasSaid ? line : String(line[bullet])
    }
}
