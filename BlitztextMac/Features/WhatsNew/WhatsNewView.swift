import SwiftUI

/// What changed in this release. Shown once per `version`: on the next popover opening,
/// or right after the first dictation for people who only use the shortcuts.
enum WhatsNew {
    /// Bump together with the items when a release deserves a note.
    static let version = "1.14"

    struct Item: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    static let items: [Item] = [
        Item(
            icon: "person.2.wave.2.fill",
            title: "Meetings aufnehmen",
            detail: "Oben im Men\u{00FC} auf \u{201E}Meeting\u{201C}: Blitztext nimmt ein Gespr\u{00E4}ch im Raum auf, erkennt, wer spricht, und schreibt auf Wunsch eine Zusammenfassung mit To-dos. Alles l\u{00E4}uft auf diesem Mac, die Aufnahme wird danach gel\u{00F6}scht."
        ),
        Item(
            icon: "keyboard",
            title: "K\u{00FC}rzel zuverl\u{00E4}ssiger",
            detail: "Die fn-K\u{00FC}rzel gehen jetzt auch mit Feststelltaste. Im Modus \u{201E}Dr\u{00FC}cken\u{201C} bleibt das Men\u{00FC} zu, die lila Anzeige zeigt die Aufnahme, und Escape oder ein anderes K\u{00FC}rzel beendet sie, ohne dass etwas verloren geht."
        ),
        Item(
            icon: "checklist",
            title: "Einrichtung Schritt f\u{00FC}r Schritt",
            detail: "Neue Macs f\u{00FC}hrt ein Assistent durch Mikrofon, Einf\u{00FC}gen und Sprachmodell, mit Parakeet Ultra als Standard. Fehlt die Mikrofon-Freigabe, sagt Blitztext das jetzt klar."
        ),
    ]
}

struct WhatsNewView: View {
    @Bindable var appState: AppState

    private var needsSetup: Bool {
        !appState.isConfigured || !appState.canRewrite
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Neu in Blitztext \(WhatsNew.version)")
                    .font(BlackboatType.publicSans(20, .bold, relativeTo: .title3))
                Text("Einmal kurz, dann geht es weiter wie gewohnt.")
                    .font(.ui(12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().opacity(0.16)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(WhatsNew.items) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.icon)
                            .font(.ui(14, .semibold))
                            .foregroundStyle(BlitztextTheme.accent)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.ui(13, .semibold))
                            Text(item.detail)
                                .font(.ui(11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !appState.isConfigured {
                    NoticeRow(
                        icon: "arrow.down.circle",
                        title: "Noch ein Schritt",
                        detail: "Lade einmal ein lokales Sprachmodell, sonst kann Blitztext nicht transkribieren."
                    )
                } else if !appState.canRewrite {
                    NoticeRow(
                        icon: "key",
                        title: "KI-Modi einrichten",
                        detail: "Ohne Apple Intelligence brauchen Blitztext+, $%&! und :) einen eigenen API-Key."
                    )
                }
            }
            .padding(16)

            Divider().opacity(0.16)

            HStack(spacing: 8) {
                Spacer()
                if needsSetup {
                    Button {
                        appState.markWhatsNewSeen()
                        appState.page = .settings
                    } label: {
                        Text("Einrichten")
                            .font(.ui(12, .medium))
                    }
                    .buttonStyle(.glassAction)
                }
                Button {
                    appState.markWhatsNewSeen()
                    appState.page = .main
                } label: {
                    Text("Verstanden")
                        .font(.ui(12, .semibold))
                }
                .buttonStyle(.glassAction)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}
