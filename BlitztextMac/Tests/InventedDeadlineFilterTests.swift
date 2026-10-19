import XCTest

final class InventedDeadlineFilterTests: XCTestCase {
    private let summary = """
    Zusammenfassung
    Das Team plant den Workshop.

    Entscheidungen
    - Der Workshop findet online statt (statt im Büro)

    To-dos
    - Person 1: Agenda schreiben (bis Freitag)
    - Person 2: Raum buchen (bis Montag)
    - Offen: Teilnehmerliste klären
    """

    private let transcript = "Person 1: Ich schreibe die Agenda bis Freitag.\n\nPerson 2: Ich buche den Raum."

    private func filtered(_ summary: String, _ transcript: String, german: Bool = true) -> String {
        InventedDeadlineFilter.filtered(summary, transcript: transcript, transcriptIsGerman: german)
    }

    func testKeepsDeadlineNamedInTranscript() {
        XCTAssertTrue(filtered(summary, transcript).contains("- Person 1: Agenda schreiben (bis Freitag)"))
    }

    func testRemovesDeadlineNobodyNamed() {
        let result = filtered(summary, transcript)
        XCTAssertTrue(result.contains("- Person 2: Raum buchen\n"))
        XCTAssertFalse(result.contains("Montag"))
    }

    func testLeavesOtherSectionsAlone() {
        let result = filtered(summary, "Wir machen den Workshop online.")
        XCTAssertTrue(result.contains("- Der Workshop findet online statt (statt im Büro)"))
        XCTAssertTrue(result.contains("- Offen: Teilnehmerliste klären"))
    }

    func testLeavesSummaryOfOtherLanguagesAlone() {
        // The German summary says "Freitag" for a spoken "Friday".
        let english = "Person 1: I'll send the agenda by Friday."
        XCTAssertEqual(filtered(summary, english, german: false), summary)
    }

    func testKeepsPhrasedDeadlineWhenItsWordsWereSaid() {
        let todo = "To-dos\n- Anna: Angebot senden (bis Ende der Woche)"
        XCTAssertEqual(filtered(todo, "Anna schickt das Angebot bis Ende der Woche."), todo)
        XCTAssertEqual(filtered(todo, "Anna schickt das Angebot."), "To-dos\n- Anna: Angebot senden")
    }

    func testComparesWholeWordsNotParts() {
        let todo = "To-dos\n- Anna: Angebot senden (bis Ende Oktober)"
        // "ende" hides in "Kalender" and "senden", but nobody said "Ende" or "Oktober".
        XCTAssertEqual(filtered(todo, "Bitte den Kalender senden."), "To-dos\n- Anna: Angebot senden")
        // A longer spoken form still counts.
        let day = "To-dos\n- Anna: Bericht (bis Freitag)"
        XCTAssertEqual(filtered(day, "Das mache ich Freitagabend."), day)
    }

    func testKeepsDeadlinesThatAreOnlyNumbers() {
        // "bis zum dreiundzwanzigsten" can come back as "23.", so numbers are not checked.
        let todo = "**To-dos:**\n- Person 1: Bericht (bis 23.)"
        XCTAssertEqual(filtered(todo, "Den Bericht schreibe ich bis zum dreiundzwanzigsten."), todo)
        let month = "To-dos\n- Person 1: Bericht (bis 15. November)"
        XCTAssertEqual(filtered(month, "Den Bericht schreibe ich."), "To-dos\n- Person 1: Bericht")
    }

    func testHandlesOtherBulletsAndTrailingPunctuation() {
        let todos = "To-dos\n• Person 1: Raum buchen (bis Montag).\n* Person 2: Agenda (bis Montag)\n1. Anna: Einladung (bis Montag);"
        XCTAssertEqual(
            filtered(todos, "Wir buchen den Raum und schicken die Einladung."),
            "To-dos\n• Person 1: Raum buchen\n* Person 2: Agenda\n1. Anna: Einladung"
        )
    }
}
