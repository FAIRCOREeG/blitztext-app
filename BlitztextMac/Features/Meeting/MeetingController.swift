import AVFoundation
import Foundation
import Observation

/// Records a meeting in the room through the Mac's microphone and turns it into a
/// transcript by person, optionally with a summary and to-dos. Transcription and speaker
/// detection run on this Mac; the summary too, unless the user connected an AI provider.
@Observable
@MainActor
final class MeetingController {
    enum Phase: Equatable {
        case idle
        case recording(startedAt: Date)
        case processing(String)
        case showing(UUID)
        case failed(String, meetingID: UUID?)
    }

    struct Settings {
        let language: String
        let postProcessor: TranscriptPostProcessor
        let summarizes: Bool
        let engine: TextRewriter.Engine
    }

    private(set) var phase: Phase = .idle {
        didSet { onPhaseChange?() }
    }
    private(set) var audioLevel: Float = 0
    /// Something the user should know about the current meeting, e.g. an interrupted recording.
    private(set) var notice: String?
    /// The meeting being recorded. It is stored as pending from the start, so a quit or crash
    /// keeps the audio for a later evaluation.
    private(set) var recordingID: UUID?
    let store: MeetingStore
    /// Lets the menu bar show that a meeting is being recorded.
    @ObservationIgnored var onPhaseChange: (() -> Void)?

    @ObservationIgnored private let settingsProvider: () -> Settings
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var recorderObserver: RecorderObserver?
    @ObservationIgnored private var levelTimer: Timer?
    @ObservationIgnored private var recordingActivity: NSObjectProtocol?
    @ObservationIgnored private var processingTask: Task<Void, Never>?
    /// Only the latest evaluation may change the phase; a cancelled one must not reset it.
    @ObservationIgnored private var evaluation = 0

    init(store: MeetingStore, settings: @escaping () -> Settings) {
        self.store = store
        settingsProvider = settings
    }

    #if DEBUG
    /// Shows a state without recording, for snapshots.
    func preview(_ phase: Phase) {
        self.phase = phase
    }
    #endif

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var isProcessing: Bool {
        if case .processing = phase { return true }
        return false
    }

    /// Meetings need Parakeet: its word timings place every word with a person.
    static var blocker: String? {
        guard ParakeetTranscriber.isSupported else {
            return "Meetings brauchen einen Mac mit Apple-Chip."
        }
        return ParakeetTranscriber.isInstalled
            ? nil
            : "F\u{00FC}r Meetings braucht Blitztext Parakeet. Bitte in den Einstellungen unter Sprachmodell laden."
    }

    // MARK: - Recording

    func start() {
        switch phase {
        case .idle, .showing, .failed: break
        case .recording, .processing: return
        }
        guard Self.blocker == nil else { return }
        notice = nil

        let startedAt = Date()
        let record = MeetingRecord(
            id: UUID(),
            createdAt: startedAt,
            title: MeetingRecord.title(startedAt: startedAt),
            duration: 0,
            status: .pending
        )
        // 16 kHz mono PCM: what the speech models read, and recoverable after a crash.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            try FileManager.default.createDirectory(at: MeetingStore.directoryURL, withIntermediateDirectories: true)
            let recorder = try AVAudioRecorder(url: record.audioURL, settings: settings)
            let observer = RecorderObserver { [weak self] in self?.recordingInterrupted() }
            recorder.delegate = observer
            recorder.isMeteringEnabled = true
            guard recorder.record() else {
                phase = .failed("Die Aufnahme lie\u{00DF} sich nicht starten. Darf Blitztext das Mikrofon nutzen?", meetingID: nil)
                return
            }
            self.recorder = recorder
            recorderObserver = observer
            recordingID = record.id
            store.upsert(record)
            // Keeps the Mac awake through a long meeting; closing the lid still sends it to sleep.
            recordingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Blitztext nimmt ein Meeting auf"
            )
            startMetering()
            phase = .recording(startedAt: startedAt)
            // The speaker models download on first use; fetch them while the network is likely there.
            Task.detached(priority: .utility) { try? await SpeakerDiarizer.shared.prepare() }
        } catch {
            phase = .failed("Die Aufnahme lie\u{00DF} sich nicht starten: \(error.localizedDescription)", meetingID: nil)
        }
    }

    /// Ends the recording and starts the evaluation.
    func stop() {
        guard case .recording = phase, let id = finishRecording() else { return }
        process(id)
    }

    /// Throws a running recording away, audio included.
    func discard() {
        guard case .recording = phase else { return }
        let id = recordingID
        recorder?.stop()
        endRecording()
        if let id { store.delete(id: id) }
        phase = .idle
    }

    /// Blitztext quits (menu, update, logout): close the file properly. The meeting stays
    /// pending and can be evaluated after the next launch.
    func finishBeforeQuit() {
        guard case .recording = phase else { return }
        _ = finishRecording()
    }

    /// The microphone went away or the encoder failed: evaluate what was recorded.
    private func recordingInterrupted() {
        guard case .recording = phase else { return }
        notice = "Die Aufnahme wurde unterbrochen, zum Beispiel weil das Mikrofon getrennt wurde. Ausgewertet wird, was bis dahin aufgenommen wurde."
        stop()
    }

    /// Stops the recorder and stores the duration. Returns the meeting's ID.
    private func finishRecording() -> UUID? {
        guard let recorder, let id = recordingID else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        endRecording()
        if var record = store.meeting(id: id) {
            record.duration = max(duration, Self.duration(of: record.audioURL) ?? 0)
            store.upsert(record)
        }
        return id
    }

    private func endRecording() {
        recorder = nil
        recorderObserver = nil
        recordingID = nil
        levelTimer?.invalidate()
        levelTimer = nil
        audioLevel = 0
        if let recordingActivity {
            ProcessInfo.processInfo.endActivity(recordingActivity)
            self.recordingActivity = nil
        }
    }

    private func startMetering() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let recorder = self.recorder else { return }
                // A recorder that stopped on its own would otherwise look like silence.
                guard recorder.isRecording else {
                    self.recordingInterrupted()
                    return
                }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                self.audioLevel = max(0, min(1, (power + 50) / 50))
            }
        }
    }

    private static func duration(of url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    // MARK: - Evaluation

    /// Runs (or retries) transcription, speaker detection and the summary for a stored meeting.
    func process(_ meetingID: UUID) {
        guard var record = store.meeting(id: meetingID), record.id != recordingID else { return }
        let settings = settingsProvider()
        processingTask?.cancel()
        evaluation += 1
        let current = evaluation
        phase = .processing("Wird transkribiert ...")

        processingTask = Task {
            // A long evaluation must not stall because the Mac went to sleep.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Blitztext wertet ein Meeting aus"
            )
            defer { ProcessInfo.processInfo.endActivity(activity) }
            @MainActor func update(_ newPhase: Phase) {
                if current == evaluation { phase = newPhase }
            }

            // A recording cut off by a crash still says zero bytes in its header.
            if WAVRecovery.repairIfNeeded(record.audioURL) || record.duration == 0 {
                record.duration = Self.duration(of: record.audioURL) ?? record.duration
            }

            do {
                let words = try await ParakeetTranscriber.shared.transcribeWords(
                    audioURL: record.audioURL,
                    language: settings.language
                )
                try Task.checkCancellation()

                update(.processing("Stimmen werden erkannt ..."))
                let turns: [SpeakerTurn]
                do {
                    turns = try await SpeakerDiarizer.shared.turns(in: record.audioURL)
                } catch {
                    try Task.checkCancellation()
                    // Keep the audio, so the people can still be told apart once this works.
                    store.upsert(record)
                    update(.failed(
                        "Die Stimmen lie\u{00DF}en sich nicht erkennen. Beim ersten Meeting l\u{00E4}dt Blitztext daf\u{00FC}r ein Modell und braucht Internet. (\(error.localizedDescription))",
                        meetingID: record.id
                    ))
                    return
                }
                try Task.checkCancellation()

                let transcribed = SpeakerAlignment.paragraphs(words: words, turns: turns).compactMap { paragraph -> MeetingTurn? in
                    let text = TranscriptionQualityService.cleanedTranscript(settings.postProcessor.process(paragraph.text))
                    return text.isEmpty ? nil : MeetingTurn(speaker: paragraph.speaker, start: paragraph.start, text: text)
                }
                guard !transcribed.isEmpty else {
                    store.upsert(record)
                    update(.failed("In der Aufnahme wurde keine Sprache erkannt.", meetingID: record.id))
                    return
                }
                record.turns = transcribed

                if settings.summarizes {
                    update(.processing("Wird zusammengefasst ..."))
                    await summarize(&record, engine: settings.engine)
                    try Task.checkCancellation()
                }

                record.status = .done
                // The audio goes only once the transcript is safely on disk.
                if store.upsert(record) {
                    try? FileManager.default.removeItem(at: record.audioURL)
                } else {
                    notice = "Das Meeting lie\u{00DF} sich nicht sichern, zum Beispiel weil der Speicher voll ist. Die Aufnahme bleibt erhalten."
                }
                update(.showing(record.id))
            } catch is CancellationError {
                update(.idle)
            } catch {
                store.upsert(record)
                update(.failed(error.localizedDescription, meetingID: record.id))
            }
        }
    }

    /// Creates the summary (again), e.g. after renaming people.
    func resummarize(_ meetingID: UUID) async {
        guard var record = store.meeting(id: meetingID) else { return }
        await summarize(&record, engine: settingsProvider().engine)
        store.setSummary(record.summary, note: record.summaryNote, for: meetingID)
    }

    private func summarize(_ record: inout MeetingRecord, engine: TextRewriter.Engine) async {
        guard TextRewriter.canRewrite(engine: engine) else {
            record.summary = nil
            record.summaryNote = "F\u{00FC}r die Zusammenfassung braucht Blitztext Apple Intelligence oder einen API-Key in den Einstellungen."
            return
        }
        do {
            record.summary = try await MeetingSummarizer.summarize(record.transcriptText, engine: engine)
            record.summaryNote = nil
        } catch {
            record.summaryNote = "Zusammenfassung fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    // MARK: - Results

    func show(_ meetingID: UUID) {
        guard !isRecording, !isProcessing else { return }
        notice = nil
        phase = .showing(meetingID)
    }

    func rename(speaker: Int, to name: String, in meetingID: UUID) {
        guard var record = store.meeting(id: meetingID) else { return }
        record.speakerNames[speaker] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.upsert(record)
    }

    /// Removes a meeting and its audio, finished or not.
    func delete(_ meetingID: UUID) {
        guard meetingID != recordingID else { return }
        store.delete(id: meetingID)
        switch phase {
        case .showing(let id) where id == meetingID, .failed(_, let id?) where id == meetingID:
            notice = nil
            phase = .idle
        default:
            break
        }
    }

    /// Back to the start screen. A running recording or evaluation keeps going.
    func close() {
        switch phase {
        case .showing, .failed:
            notice = nil
            phase = .idle
        default:
            break
        }
    }
}

/// AVAudioRecorder reports a stop it did not ask for through its delegate.
private final class RecorderObserver: NSObject, AVAudioRecorderDelegate {
    private let onInterruption: @MainActor () -> Void

    init(onInterruption: @escaping @MainActor () -> Void) {
        self.onInterruption = onInterruption
    }

    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        guard !flag else { return }
        Task { @MainActor in onInterruption() }
    }

    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in onInterruption() }
    }
}
