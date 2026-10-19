import SwiftUI
import UniformTypeIdentifiers

@main
struct BlitztextMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let menuBarStatusController = MenuBarStatusController()
    let appState = AppState()
    private lazy var recordingIndicator = RecordingIndicatorController(appState: appState)
    /// Files opened before launch finished (e.g. "Open With" on a closed app).
    private var pendingAudioFile: URL?
    private var didFinishLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let folder = MacSnapshots.folder {
            NSApp.setActivationPolicy(.prohibited)
            MacSnapshots.render(appState: appState, to: folder)
            NSApp.terminate(nil)
            return
        }
        if let file = MacMeetingCheck.file {
            NSApp.setActivationPolicy(.prohibited)
            Task {
                await MacMeetingCheck.run(file)
                NSApp.terminate(nil)
            }
            return
        }
        #endif
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            menuBarStatusController.attach(to: button)
            button.action = #selector(togglePopover)
            button.target = self
        }

        popover = NSPopover()
        popover.contentSize = NSSize(width: MenuBarView.width, height: 480)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = GlassPopoverHostingController(
            rootView: MenuBarView(appState: appState),
            width: MenuBarView.width
        )

        NSApp.setActivationPolicy(.accessory)

        // Hotkey events
        appState.hotkeyService.onHotkeyEvent = { [weak self] event in
            self?.handleHotkeyEvent(event)
        }
        appState.hotkeyService.isWorkflowRunning = { [weak self] in
            guard let active = self?.appState.activeWorkflow, case .running = active.phase else { return false }
            return true
        }
        appState.onMenuBarStatusChange = { [weak self] status in
            self?.menuBarStatusController.update(to: status)
            self?.recordingIndicator.update(to: status)
        }
        appState.onRecordingIndicatorSettingChange = { [weak self] in
            self?.recordingIndicator.settingChanged()
        }
        appState.onWhatsNewChange = { [weak self] unseen in
            self?.menuBarStatusController.showsNewBadge = unseen
        }
        menuBarStatusController.showsNewBadge = appState.hasUnseenWhatsNew
        appState.hotkeyService.start()
        appState.appUpdateService.startIfConfigured()

        // Listen for popover dismiss requests (from auto-paste)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissPopover),
            name: .dismissPopover,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showWhatsNew),
            name: .showWhatsNew,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showWhatsNew),
            name: .showPopover,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(chooseAudioFile),
            name: .chooseAudioFile,
            object: nil
        )

        didFinishLaunching = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let url = self.pendingAudioFile {
                self.pendingAudioFile = nil
                self.transcribeAudioFile(url)
            } else {
                self.showOnboardingIfNeeded()
            }
        }
    }

    // MARK: - Audio files

    /// Finder "Open With", dragging onto the app icon, or `open -a Blitztext file.ogg`.
    func applicationWillTerminate(_ notification: Notification) {
        // A meeting being recorded stays readable and can be evaluated after the next launch.
        appState.meeting.finishBeforeQuit()
        appState.restoreAudioOutput()
        // Quitting right after a dictation still gives the previous clipboard back.
        ClipboardPasteService.shared.settleNow()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: Self.isAudioFile) else { return }
        guard didFinishLaunching else {
            pendingAudioFile = url
            return
        }
        transcribeAudioFile(url)
    }

    @objc private func chooseAudioFile() {
        // A transient popover would close under the panel anyway; reopen it with the result.
        popover.performClose(nil)
        appState.isPopoverShown = false
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.title = "Audiodatei transkribieren"
        panel.message = "Sprachmemo, WhatsApp-Sprachnachricht oder andere Audiodatei w\u{00E4}hlen"
        panel.prompt = "Transkribieren"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribeAudioFile(url)
    }

    private func transcribeAudioFile(_ url: URL) {
        appState.audioFile.transcribe(url, appState: appState)
        appState.page = .audioFile
        showPopover()
    }

    private static func isAudioFile(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return ["ogg", "opus", "oga", "m4a", "mp3", "wav", "aiff", "caf", "aac"].contains(url.pathExtension.lowercased())
        }
        return type.conforms(to: .audio)
    }

    @objc private func showWhatsNew() {
        guard !popover.isShown else { return }
        appState.prepareForPopoverPresentation()
        showPopover()
    }

    @objc private func handleDismissPopover() {
        appState.isPopoverShown = false
        popover.performClose(nil)
    }

    /// Mode chosen at key down per shortcut, so key up (hold mode) stops the same workflow.
    private var shortcutModes: [WorkflowType: WorkflowType] = [:]

    private func handleHotkeyEvent(_ event: HotkeyEvent) {
        switch event {
        case .down(let shortcut):
            let mode: WorkflowType
            if let previous = shortcutModes[shortcut],
               let active = appState.activeWorkflow,
               active.type == previous,
               active.phase.isActive {
                // Second press in "Drücken" mode stops what the first press started,
                // even though Blitztext itself is frontmost by now.
                mode = previous
            } else {
                mode = appState.modeForShortcut(
                    shortcut,
                    frontmostApp: NSWorkspace.shared.frontmostApplication
                )
            }
            shortcutModes[shortcut] = mode
            handleHotkeyDown(mode)
        case .up(let shortcut):
            handleHotkeyUp(shortcutModes[shortcut] ?? shortcut)
        case .escape:
            // In both modes: a recording stops and is transcribed, a transcription or
            // rewrite still running is cancelled before it pastes.
            if let active = appState.activeWorkflow, case .running = active.phase {
                active.stop()
            }
        }
    }

    private func handleHotkeyDown(_ type: WorkflowType) {
        // In toggle mode, any workflow shortcut finishes the current recording.
        // Do this before checking the requested mode: it may not be configured.
        if appState.appSettings.hotkeyMode == .toggle,
           let active = appState.activeWorkflow,
           case .running = active.phase {
            if active.isRecording {
                active.stop()
            }
            // A second stop during transcription would cancel its result.
            return
        }

        guard appState.isWorkflowAvailable(type) else {
            // Missing model or AI setup: say so instead of silently ignoring the shortcut.
            guard !popover.isShown else { return }
            appState.prepareForPopoverPresentation()
            if appState.page != .whatsNew {
                appState.page = .main
            }
            showPopover()
            return
        }

        let mode = appState.appSettings.hotkeyMode

        switch mode {
        case .hold:
            // Hold mode: start recording on key down
            appState.startWorkflow(type, source: .hotkeyBackground)

        case .toggle:
            if appState.appSettings.showsRecordingIndicator {
                // The pill shows the recording, so the menu stays closed and the text goes
                // back to the app in use. Pressing again, Escape or a click on the pill stops.
                appState.startWorkflow(type, source: .hotkeyBackground)
            } else {
                appState.prepareForPopoverPresentation()
                appState.startWorkflow(type, source: .manual)
                showPopover()
            }
        }
    }

    private func handleHotkeyUp(_ type: WorkflowType) {
        let mode = appState.appSettings.hotkeyMode

        guard mode == .hold else { return }

        // Hold mode: stop recording on key release
        if let active = appState.activeWorkflow,
           active.type == type {
            // Only stop if currently recording (running phase)
            if case .running = active.phase {
                active.stop()
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            appState.isPopoverShown = false
        } else {
            appState.prepareForPopoverPresentation()
            showPopover()
        }
    }

    private func showOnboardingIfNeeded() {
        guard appState.shouldShowOnboarding else { return }
        appState.prepareForPopoverPresentation()
        showPopover()
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        appState.isPopoverShown = true
        NSApp.activate(ignoringOtherApps: true)

        // Transparent window so the HUD material shows through, as in _Space.
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.popover.contentViewController?.view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }

    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            appState.isPopoverShown = false
            switch appState.currentPhase {
            case .done, .error:
                appState.resetCurrentWorkflow()
            default:
                // Keep a running file transcription visible for the next opening.
                if appState.page == .audioFile, appState.audioFile.isWorking { break }
                appState.page = .main
            }
        }
    }
}

#if DEBUG
/// Design reviews: `-BlitztextSnapshotDir /path` renders the popover pages, the settings
/// panes and the recording pill to PNG files, light and dark, and quits. No status item,
/// no hotkeys, nothing is recorded. Not compiled into Release builds.
/// Runs the meeting evaluation on an audio file and prints the result, without microphone,
/// keychain or stored meetings: `-BlitztextMeetingCheck /path/to/file.m4a`. Uses the installed
/// Parakeet model and downloads the speaker models if they are missing.
@MainActor
enum MacMeetingCheck {
    static var file: URL? {
        UserDefaults.standard.string(forKey: "BlitztextMeetingCheck").map { URL(fileURLWithPath: $0) }
    }

    static func run(_ file: URL) async {
        let store = MeetingStore(persistent: false)
        // Only the on-device model, so no API key is read from the keychain.
        let summarizes = TextRewriter.isLocalAvailable
        let controller = MeetingController(store: store) {
            MeetingController.Settings(
                language: "de",
                postProcessor: TranscriptPostProcessor(
                    customTerms: [], replacements: [], correctCustomTerms: false, removeFillerWords: true,
                    language: "de", isDictionaryWord: DictionaryWordChecker.isKnownWord
                ),
                summarizes: summarizes,
                engine: .automatic
            )
        }
        var audioURL: URL?
        defer { if let audioURL { try? FileManager.default.removeItem(at: audioURL) } }
        do {
            let wav = try AudioFileConverter.convertToWAV(file)
            let record = MeetingRecord(
                id: UUID(), createdAt: Date(), title: MeetingRecord.title(startedAt: Date()),
                duration: wav.duration, status: .pending
            )
            try FileManager.default.createDirectory(at: MeetingStore.directoryURL, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: wav.url, to: record.audioURL)
            audioURL = record.audioURL
            store.upsert(record)
            print("Audio: \(Int(wav.duration)) s, summary on device: \(summarizes)")

            let started = Date()
            var lastStep = ""
            controller.process(record.id)
            while true {
                try await Task.sleep(for: .milliseconds(200))
                let elapsed = String(format: "%.1f s", Date().timeIntervalSince(started))
                switch controller.phase {
                case .processing(let step) where step != lastStep:
                    print("[\(elapsed)] \(step)")
                    lastStep = step
                case .showing(let id):
                    print("[\(elapsed)] fertig")
                    guard let result = store.meeting(id: id) else { return }
                    print("\nPersonen: \(result.speakers.count)\n\n" + result.transcriptText)
                    print("\n--- Zusammenfassung ---\n" + (result.summary ?? result.summaryNote ?? "keine"))
                    return
                case .failed(let message, _):
                    print("[\(elapsed)] FEHLER: \(message)")
                    return
                default:
                    continue
                }
            }
        } catch {
            print("FEHLER: \(error.localizedDescription)")
        }
    }
}

@MainActor
enum MacSnapshots {
    static var folder: URL? {
        UserDefaults.standard.string(forKey: "BlitztextSnapshotDir").map { URL(fileURLWithPath: $0) }
    }

    static func render(appState: AppState, to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // As on a set-up Mac: the unsigned snapshot binary has no Accessibility grant.
        appState.accessibilityPermissionGranted = true
        for (mode, name) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = NSAppearance(named: name)
            NSApp.appearance = appearance

            for (page, label) in [(PopoverPage.main, "main"), (.onboarding, "onboarding"), (.history, "history")] {
                appState.page = page
                capture(MenuBarView(appState: appState), appearance: appearance, to: folder.appendingPathComponent("\(mode)-\(label).png"))
            }
            // The setup assistant as on a Mac that has nothing set up yet.
            SetupAssistantView.debugShowsFreshMac = true
            appState.page = .onboarding
            capture(MenuBarView(appState: appState), appearance: appearance, to: folder.appendingPathComponent("\(mode)-onboarding-fresh.png"))
            SetupAssistantView.debugShowsFreshMac = false
            renderMeetingPages(appState: appState, appearance: appearance, mode: mode, to: folder)
            for pane in SettingsPane.allCases {
                SettingsContentView.debugInitialPane = pane
                appState.page = .settings
                capture(MenuBarView(appState: appState), appearance: appearance, to: folder.appendingPathComponent("\(mode)-popover-settings-\(pane.rawValue).png"))
                let view = SettingsContentView(appState: appState)
                    .frame(width: MenuBarView.width, height: 1400, alignment: .top)
                    .background(BlitztextTheme.page)
                capture(view, appearance: appearance, to: folder.appendingPathComponent("\(mode)-settings-\(pane.rawValue).png"))
            }
            for (status, label) in [(MenuBarStatus.recording(.tapTalk), "recording"), (.processing(.tapTalk), "processing"), (.success(.tapTalk), "success")] {
                let model = RecordingIndicatorModel()
                model.status = status
                let pill = RecordingPill(model: model, appState: appState) {}
                    .frame(width: RecordingPill.panelSize.width, height: RecordingPill.panelSize.height)
                    .padding(20)
                    .background(BlitztextTheme.page)
                capture(pill, appearance: appearance, to: folder.appendingPathComponent("\(mode)-pill-\(label).png"))
            }
        }
        appState.page = .main
    }

    private static func renderMeetingPages(appState: AppState, appearance: NSAppearance?, mode: String, to folder: URL) {
        let meeting = appState.meeting
        if meeting.store.meetings.isEmpty {
            meeting.store.upsert(sampleMeeting)
        }
        let phases: [(MeetingController.Phase, String)] = [
            (.idle, "start"),
            (.recording(startedAt: Date().addingTimeInterval(-754)), "recording"),
            (.processing("Stimmen werden erkannt ..."), "processing"),
            (.showing(sampleMeeting.id), "result"),
        ]
        appState.page = .meeting
        for (phase, label) in phases {
            meeting.preview(phase)
            capture(MenuBarView(appState: appState), appearance: appearance, to: folder.appendingPathComponent("\(mode)-meeting-\(label).png"))
            // The whole result, beyond the popover height.
            if case .showing = phase {
                let full = MeetingView(appState: appState, height: 1100)
                    .frame(width: MenuBarView.width)
                    .background(BlitztextTheme.page)
                capture(full, appearance: appearance, to: folder.appendingPathComponent("\(mode)-meeting-result-full.png"))
            }
        }
        meeting.preview(.idle)
    }

    private static let sampleMeeting = MeetingRecord(
        id: UUID(uuidString: "5A3B1E00-0000-4000-8000-0000000000AC")!,
        createdAt: Date(),
        title: MeetingRecord.title(startedAt: Date()),
        duration: 62,
        status: .done,
        turns: [
            MeetingTurn(speaker: 1, start: 0, text: "Kurzer Stand zum Workshop: Die Agenda steht, mir fehlt nur noch der Raum."),
            MeetingTurn(speaker: 2, start: 14, text: "Den Raum buche ich. Sollen wir online oder im B\u{00FC}ro machen?"),
            MeetingTurn(speaker: 3, start: 31, text: "Lieber online, dann kann das Team aus Hamburg dabei sein."),
            MeetingTurn(speaker: 1, start: 45, text: "Gut, dann online. Ich schicke die Einladung bis Freitag."),
        ],
        speakerNames: [3: "Anna"],
        summary: """
        Zusammenfassung
        Der Workshop findet online statt, damit auch das Team aus Hamburg teilnehmen kann. Die Agenda steht.

        Entscheidungen
        - Der Workshop findet online statt

        To-dos
        - Person 1: Einladung schicken (bis Freitag)
        - Person 2: Raum buchen
        """
    )

    private static func capture<V: View>(_ view: V, appearance: NSAppearance?, to url: URL) {
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = appearance
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.isReleasedWhenClosed = false
        window.contentView = nil
        window.close()
    }
}
#endif
