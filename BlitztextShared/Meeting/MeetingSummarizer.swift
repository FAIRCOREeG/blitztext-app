import Foundation
import NaturalLanguage

/// Summary, decisions and to-dos for a meeting transcript.
///
/// The on-device model reads about 4,000 tokens at once, so long meetings are
/// summarized in parts first ("map") and the notes are combined afterwards ("reduce").
@MainActor
enum MeetingSummarizer {
    static let finalInstruction = """
    Du erhältst das Transkript eines Meetings oder Notizen daraus. Wer spricht, ist mit Namen oder als „Person 1“, „Person 2“ markiert. Korrigiert sich jemand beim Sprechen, gilt nur die korrigierte Fassung.
    Schreibe auf Deutsch genau diese drei Abschnitte:

    Zusammenfassung
    Drei bis fünf klare Sätze: worum es ging und was herauskam.

    Entscheidungen
    Spiegelstriche mit „- “. Nur Festlegungen, auf die sich die Runde geeinigt hat, keine Aufgaben. Gab es keine, schreibe „- Keine“.

    To-dos
    Spiegelstriche im Format „- Wer: Was“. „Wer“ ist der Name oder „Person 1“, „Person 2“ wie im Transkript. Sagt jemand „mache ich“ oder „übernehme ich“, ist diese Person zuständig. Nur wenn wirklich niemand genannt ist, schreibe „Offen“. Nennt das Transkript für eine Aufgabe eine Frist, hänge sie in Klammern an, mit den Worten aus dem Transkript. Nennt es keine, lass die Klammer weg. Gab es keine Aufgaben, schreibe „- Keine“.

    Erfinde nichts dazu, vor allem keine Termine, Fristen, Namen oder Zahlen. Keine weiteren Abschnitte, keine Einleitung.
    """

    static let partInstruction = """
    Du erhältst einen Ausschnitt aus dem Transkript eines Meetings. Wer spricht, ist markiert. Korrigiert sich jemand beim Sprechen, gilt nur die korrigierte Fassung.
    Halte in knappen Stichpunkten fest: besprochene Themen, getroffene Entscheidungen und genannte Aufgaben mit der zuständigen Person.
    Behalte Namen, Zahlen, Termine und Fristen, die im Ausschnitt stehen. Erfinde nichts dazu. Nur die Stichpunkte, keine Einleitung.
    """

    static func summarize(_ transcript: String, engine: TextRewriter.Engine) async throws -> String {
        let local = TextRewriter.runsLocally(engine: engine)
        // Characters per request: conservative for the on-device model, generous for providers.
        let limit = local ? 5_000 : 60_000

        var material = transcript
        var round = 0
        while material.count > limit, round < 3 {
            var notes: [String] = []
            for part in chunks(of: material, limit: limit) {
                notes.append(try await rewrite(part, instruction: partInstruction, engine: engine))
            }
            material = notes.joined(separator: "\n\n")
            round += 1
        }
        let summary = try await rewrite(material, instruction: finalInstruction, engine: engine)
        let isGerman = NLLanguageRecognizer.dominantLanguage(for: transcript) == .german
        return InventedDeadlineFilter.filtered(cleaned(summary), transcript: transcript, transcriptIsGerman: isGerman)
    }

    /// A summary reads a conversation, not a dictation: no dictation rules (their examples name
    /// weekdays the model copied into to-dos; the self-correction rule is in the instructions
    /// above, without examples), and the same transcript gives the same summary.
    private static func rewrite(_ text: String, instruction: String, engine: TextRewriter.Engine) async throws -> String {
        try await TextRewriter.rewrite(text, instruction: instruction, engine: engine, dictationRules: false, deterministic: true)
    }

    /// Small models sometimes echo parts of the instruction or leave placeholder bullets.
    static func cleaned(_ summary: String) -> String {
        let echoes = ["Erfinde nichts dazu", "Keine weiteren Abschnitte", "Spiegelstriche im Format", "Drei bis fünf klare Sätze", "lass die Klammer weg"]
        return summary
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !echoes.contains { line.contains($0) } && line != "- Offen" && line != "- Offen:"
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Splits at paragraph boundaries (speaker turns) so no turn is cut in half.
    static func chunks(of text: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if !current.isEmpty, current.count + paragraph.count + 2 > limit {
                result.append(current)
                current = ""
            }
            if paragraph.count > limit {
                // A single very long turn: cut at sentence ends.
                var remaining = paragraph[...]
                while remaining.count > limit {
                    let cut = remaining.index(remaining.startIndex, offsetBy: limit)
                    let end = remaining[..<cut].lastIndex(where: { ".!?".contains($0) }).map { remaining.index(after: $0) } ?? cut
                    result.append(String(remaining[..<end]))
                    remaining = remaining[end...]
                }
                current = String(remaining)
            } else {
                current += current.isEmpty ? paragraph : "\n\n" + paragraph
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
