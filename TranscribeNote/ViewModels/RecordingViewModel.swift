import Foundation
import SwiftData
import Speech
import os

enum RecordingState {
    case idle
    case recording
    case paused
    case stopping
    case completed
}

@Observable
final class ElapsedTimeClock {
    private(set) var elapsedTime: TimeInterval = 0
    var formatted: String { elapsedTime.hhmmss }
    func update(_ time: TimeInterval) { elapsedTime = time }
    func reset() { elapsedTime = 0 }
}

@Observable
final class AudioLevelMeter {
    private(set) var level: Float = 0
    func update(_ newLevel: Float) { level = newLevel }
    func reset() { level = 0 }
}

/// Lightweight struct decoupling RecordingViewModel from SwiftData's ScheduledRecording model.
struct ScheduledRecordingInfo: Sendable {
    let id: UUID
    let title: String
    let durationMinutes: Int?
}

@Observable
final class RecordingViewModel {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TranscribeNote", category: "RecordingViewModel")

    private(set) var state: RecordingState = .idle
    private(set) var segments: [TranscriptSegment] = []
    private(set) var partialText: String = ""
    let clock = ElapsedTimeClock()
    let audioMeter = AudioLevelMeter()
    private(set) var errorMessage: String?
    var criticalError: String?
    private(set) var currentSession: RecordingSession?
    private(set) var summaries: [SummaryBlock] = []
    private(set) var isSummarizing: Bool = false
    private(set) var latestSummary: String?
    private(set) var latestKeyPoints: [String] = []
    private(set) var summaryError: String?
    private(set) var stoppingStatus: String = "Saving..."

    // Duration-end prompt (2c)
    var showDurationEndPrompt = false
    private(set) var scheduledInfo: ScheduledRecordingInfo?

    var isRecording: Bool { state == .recording }
    var isActive: Bool { state == .recording || state == .paused }

    private let audioCaptureService: AudioCaptureService
    private let asrEngine: any ASREngine
    private var timer: Timer?
    private var recordingStartTime: Date?
    private var drainTask: Task<Void, Never>?
    private var sessionPersisted = false
    private var summaryTimer: Timer?
    private var lastSummarizedSegmentCount: Int = 0
    private var summaryTask: Task<Void, Never>?
    private var summarizerService: SummarizerService
    private var summarizerConfig: SummarizerConfig
    private var llmConfig: LLMConfig
    private var nextPeriodicCoveringFrom: TimeInterval = 0
    private var periodicWindowCount: Int = 0
    private var llmConfigObserver: NSObjectProtocol?
    private var summarizerConfigObserver: NSObjectProtocol?
    private let vadConfig: VADConfig

    // Duration-end timer state (2c)
    private var durationEndTimer: Timer?
    private var remainingDurationSeconds: TimeInterval?
    private var durationTimerStarted: Date?

    // Multi-clip pause/resume state
    private var clipTimeOffset: TimeInterval = 0
    private var pausedElapsedTime: TimeInterval = 0
    private var recordedAudioFilePaths: [String] = []

    init(
        audioCaptureService: AudioCaptureService = AudioCaptureService(),
        asrEngine: any ASREngine,
        summarizerService: SummarizerService = SummarizerService(engine: NoopLLMEngine()),
        summarizerConfig: SummarizerConfig = .default,
        llmConfig: LLMConfig = .default,
        vadConfig: VADConfig = .default
    ) {
        self.audioCaptureService = audioCaptureService
        self.asrEngine = asrEngine
        self.summarizerService = summarizerService
        self.summarizerConfig = summarizerConfig
        self.llmConfig = llmConfig
        self.vadConfig = vadConfig
        setupASRCallbacks()
        llmConfigObserver = NotificationCenter.default.addObserver(
            forName: .llmConfigDidSave, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadLLMConfig()
        }
        summarizerConfigObserver = NotificationCenter.default.addObserver(
            forName: .summarizerConfigDidSave, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadSummarizerConfig()
        }
    }

    convenience init(
        audioCaptureService: AudioCaptureService = AudioCaptureService(),
        llmConfig: LLMConfig = .default,
        summarizerConfig: SummarizerConfig = .default,
        vadConfig: VADConfig = .default
    ) {
        let engine: any ASREngine
        do {
            engine = try SpeechAnalyzerEngine(locale: TranscribeNoteApp.systemLocale)
        } catch {
            Self.logger.warning("SpeechAnalyzerEngine unavailable (\(error.localizedDescription)), falling back to NoopASREngine")
            engine = NoopASREngine()
        }
        let llmEngine = LLMEngineFactory.create(from: llmConfig)
        let summarizer = SummarizerService(engine: llmEngine)
        self.init(
            audioCaptureService: audioCaptureService,
            asrEngine: engine,
            summarizerService: summarizer,
            summarizerConfig: summarizerConfig,
            llmConfig: llmConfig,
            vadConfig: vadConfig
        )
        if engine is NoopASREngine {
            self.errorMessage = "Speech recognition is unavailable. Transcription is disabled."
        }
    }

    deinit {
        timer?.invalidate()
        summaryTimer?.invalidate()
        durationEndTimer?.invalidate()
        if let observer = llmConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = summarizerConfigObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func reloadSummarizerConfig() {
        let newConfig = SummarizerConfig.fromUserDefaults()
        let intervalChanged = newConfig.intervalMinutes != summarizerConfig.intervalMinutes
        let enabledChanged = newConfig.liveSummarizationEnabled != summarizerConfig.liveSummarizationEnabled
        summarizerConfig = newConfig

        // Restart summary timer if interval or enabled state changed during recording
        if (intervalChanged || enabledChanged) && state == .recording {
            summaryTimer?.invalidate()
            summaryTimer = nil
            if newConfig.liveSummarizationEnabled {
                startSummaryTimer()
            }
        }
        Self.logger.info("Reloaded summarizer config: interval=\(newConfig.intervalMinutes)min, live=\(newConfig.liveSummarizationEnabled)")
    }

    private func reloadLLMConfig() {
        let newConfig = LLMProfileStore.resolveConfig(for: .live)
        if newConfig.provider != llmConfig.provider {
            summarizerService = SummarizerService(engine: LLMEngineFactory.create(from: newConfig))
        }
        llmConfig = newConfig
        Self.logger.info("Reloaded LLM config: provider=\(newConfig.provider.rawValue), model=\(newConfig.model)")
    }

    private func setupASRCallbacks() {
        asrEngine.onResult = { [weak self] result in
            await MainActor.run { [weak self] in
                self?.handleTranscriptResult(result)
            }
        }

        asrEngine.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func startRecording(modelContext: ModelContext? = nil, scheduledInfo: ScheduledRecordingInfo? = nil) async {
        guard state == .idle || state == .completed else { return }
        if state == .completed {
            dismissCompletedRecording(modelContext: modelContext)
        }
        errorMessage = nil

        guard await checkPermissions() else { return }

        do {
            let fileURL = try startAudioPipeline()
            createSession(fileURL: fileURL, scheduledInfo: scheduledInfo)
            startElapsedTimer()
            startSummaryTimer()

            // 2c: Start duration-end timer if scheduled with duration
            self.scheduledInfo = scheduledInfo
            if let minutes = scheduledInfo?.durationMinutes {
                remainingDurationSeconds = TimeInterval(minutes * 60)
                startDurationEndTimer()
            }
        } catch let error as AudioCaptureService.AudioCaptureError where error == .noInputDevice {
            Self.logger.error("Critical: no audio input device")
            criticalError = error.localizedDescription
        } catch {
            Self.logger.error("Failed to start recording: \(error.localizedDescription)")
            criticalError = "Failed to start recording: \(error.localizedDescription)"
        }
    }

    private func checkPermissions() async -> Bool {
        let micGranted = await audioCaptureService.requestPermission()
        guard micGranted else {
            errorMessage = "Microphone permission denied"
            return false
        }

        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { _ in
                    continuation.resume()
                }
            }
        }

        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            errorMessage = "Speech recognition permission denied"
            return false
        }
        return true
    }

    private func startAudioPipeline() throws -> URL {
        // 0. Configure VAD before audio starts
        if vadConfig.vadEnabled {
            let inputFormat = audioCaptureService.audioEngine.inputNode.outputFormat(forBus: 0)
            // Buffer size matches the tap's hardcoded 1024 in AudioCaptureService.startCapture()
            let bufferDuration = 1024.0 / inputFormat.sampleRate
            let suppressBuffers = max(1, Int(2.0 / bufferDuration))
            let timeoutBuffers = vadConfig.silenceTimeoutSeconds.map { max(1, Int(Double($0) / bufferDuration)) }
            let vad = SimpleVAD(
                silenceThreshold: vadConfig.silenceThreshold,
                silenceBuffersForSuppress: suppressBuffers,
                silenceBuffersForTimeout: timeoutBuffers
            )
            audioCaptureService.configureVAD(vad)

            audioCaptureService.onSilenceTimeout = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.state == .recording else { return }
                    Self.logger.info("Silence timeout — auto-stopping recording")
                    self.stopRecording()
                }
            }
            Self.logger.info("VAD enabled: threshold=\(self.vadConfig.silenceThreshold), suppressBuffers=\(suppressBuffers), timeoutBuffers=\(String(describing: timeoutBuffers))")
        }

        // 1. Wire up buffer forwarding BEFORE audio starts
        let engine = asrEngine
        audioCaptureService.onAudioBuffer = { buffer in
            engine.appendAudioBuffer(buffer)
        }

        // 2. Wire audio level metering (throttle on audio thread to avoid Task spam)
        let meter = audioMeter
        let lastLevel = OSAllocatedUnfairLock(initialState: Float(0))
        audioCaptureService.onAudioLevel = { level in
            let shouldUpdate = lastLevel.withLock { last -> Bool in
                guard abs(last - level) > 0.02 else { return false }
                last = level
                return true
            }
            if shouldUpdate {
                Task { @MainActor in
                    meter.update(level)
                }
            }
        }

        // 3. Start ASR (creates recognition request ready to receive buffers)
        try asrEngine.startRecognition(audioEngine: audioCaptureService.audioEngine)

        // 4. Start audio capture LAST (tap installed, engine starts, audio flows to ASR)
        return try audioCaptureService.startCapture()
    }

    private func createSession(fileURL: URL, scheduledInfo: ScheduledRecordingInfo? = nil) {
        let title = scheduledInfo?.title ?? "Recording \(Date().formatted(date: .abbreviated, time: .shortened))"
        let session = RecordingSession(
            title: title,
            scheduledRecordingID: scheduledInfo?.id
        )
        recordedAudioFilePaths = [fileURL.lastPathComponent]
        currentSession = session

        recordingStartTime = Date()
        state = .recording
        SoundEffectService.play(.recordingStart)
        segments = []
        partialText = ""
        clock.reset()
        clipTimeOffset = 0
        pausedElapsedTime = 0
    }

    // MARK: - Pause / Resume

    func pauseRecording() async {
        guard state == .recording else { return }
        Self.logger.info("Pausing recording...")

        // 1. Stop timers
        timer?.invalidate()
        timer = nil
        summaryTimer?.invalidate()
        summaryTimer = nil
        pauseDurationEndTimer()

        // 2. Disconnect audio callbacks
        audioCaptureService.onAudioBuffer = nil
        audioCaptureService.onAudioLevel = nil
        audioCaptureService.onSilenceTimeout = nil
        audioMeter.reset()

        // 3. Stop audio capture (saves current clip file, clears VAD)
        if let savedURL = audioCaptureService.stopCapture() {
            Self.logger.info("Clip saved to \(savedURL.path)")
        }

        // 4. Drain ASR results for current clip
        await asrEngine.stopRecognition()

        // 5. Promote orphaned partialText
        if !partialText.isEmpty {
            Self.logger.info("Promoting orphaned partialText on pause (\(self.partialText.count) chars)")
            let segment = TranscriptSegment(
                startTime: segments.last?.endTime ?? clipTimeOffset,
                endTime: clock.elapsedTime,
                text: partialText,
                confidence: 0.0,
                language: nil
            )
            segments.append(segment)
            partialText = ""
        }

        // 6. Save elapsed time and transition to paused
        pausedElapsedTime = clock.elapsedTime
        state = .paused
        SoundEffectService.play(.pause)
        Self.logger.info("Recording paused at \(self.pausedElapsedTime.hhmmss)")
    }

    func resumeRecording() async {
        guard state == .paused else { return }
        Self.logger.info("Resuming recording...")

        // 1. Update clip offset — all new ASR timestamps will be shifted by this amount
        clipTimeOffset = pausedElapsedTime

        // 2. Start new audio pipeline (new file + new ASR session)
        do {
            let fileURL = try startAudioPipeline()
            recordedAudioFilePaths.append(fileURL.lastPathComponent)
            Self.logger.info("New clip started: \(fileURL.lastPathComponent)")
        } catch {
            errorMessage = "Failed to resume recording: \(error.localizedDescription)"
            Self.logger.error("Resume failed: \(error.localizedDescription)")
            return
        }

        // 3. Restore elapsed timer from paused time
        let resumeDate = Date()
        recordingStartTime = resumeDate.addingTimeInterval(-pausedElapsedTime)
        startElapsedTimer()

        // 4. Restart summary timer
        startSummaryTimer()

        // 5. Resume duration-end timer if active
        resumeDurationEndTimer()

        state = .recording
        SoundEffectService.play(.resume)
        Self.logger.info("Recording resumed from \(self.pausedElapsedTime.hhmmss)")
    }

    private func startElapsedTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.clock.update(Date().timeIntervalSince(start))
        }
        t.tolerance = 0.2
        timer = t
    }

    private func startSummaryTimer() {
        guard summarizerConfig.liveSummarizationEnabled else {
            Self.logger.info("Live summarization disabled — skipping summary timer")
            return
        }
        let interval = TimeInterval(summarizerConfig.intervalMinutes * 60)
        guard interval > 0 else { return }
        summaryTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.triggerPeriodicSummary()
        }
        summaryTimer?.tolerance = 5.0
    }

    // MARK: - Duration End Timer (2c)

    private func startDurationEndTimer() {
        guard let remaining = remainingDurationSeconds, remaining > 0 else { return }
        durationTimerStarted = Date()
        durationEndTimer = Timer.scheduledTimer(withTimeInterval: remaining, repeats: false) { [weak self] _ in
            Self.logger.info("Duration timer fired — showing end prompt")
            self?.showDurationEndPrompt = true
        }
        durationEndTimer?.tolerance = 1.0
        Self.logger.info("Duration-end timer started: \(Int(remaining))s remaining")
    }

    private func pauseDurationEndTimer() {
        guard let started = durationTimerStarted, let remaining = remainingDurationSeconds else { return }
        durationEndTimer?.invalidate()
        durationEndTimer = nil
        let elapsed = Date().timeIntervalSince(started)
        remainingDurationSeconds = max(0, remaining - elapsed)
        durationTimerStarted = nil
        Self.logger.info("Duration-end timer paused: \(Int(self.remainingDurationSeconds ?? 0))s remaining")
    }

    private func resumeDurationEndTimer() {
        guard remainingDurationSeconds != nil else { return }
        startDurationEndTimer()
    }

    private func invalidateDurationEndTimer() {
        durationEndTimer?.invalidate()
        durationEndTimer = nil
        remainingDurationSeconds = nil
        durationTimerStarted = nil
    }

    func triggerPeriodicSummary() {
        guard state == .recording else { return }
        guard segments.count > lastSummarizedSegmentCount else { return }

        let unsummarized = Array(segments[lastSummarizedSegmentCount...])
        let previousSummary = self.latestSummary
        let config = self.summarizerConfig
        let llmCfg = self.llmConfig

        // Window-aligned boundaries: each timer fire = one window
        let intervalSeconds = TimeInterval(config.intervalMinutes * 60)
        let currentWindow = self.periodicWindowCount
        self.periodicWindowCount += 1
        let coveringFrom = self.nextPeriodicCoveringFrom
        let coveringTo = TimeInterval(currentWindow + 1) * intervalSeconds

        isSummarizing = true

        summaryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.summarizerService.summarizeWithFallback(
                    segments: unsummarized,
                    previousSummary: previousSummary,
                    config: config,
                    llmConfig: llmCfg
                )
                guard !Task.isCancelled else { return }
                // Clear previous error only on success
                self.summaryError = nil
                if !result.content.isEmpty {
                    let block = SummaryBlock(
                        coveringFrom: coveringFrom,
                        coveringTo: coveringTo,
                        content: result.content,
                        style: config.summaryStyle,
                        model: llmCfg.model,
                        structuredContent: result.structured?.toJSON()
                    )
                    self.summaries.append(block)
                    self.latestSummary = result.content
                    self.latestKeyPoints = result.structured?.keyPoints ?? []
                    self.lastSummarizedSegmentCount = self.segments.count
                    self.nextPeriodicCoveringFrom = coveringTo
                }
            } catch {
                guard !Task.isCancelled else { return }
                Self.logger.error("Periodic summary failed: \(error.localizedDescription)")
                self.summaryError = error.localizedDescription
            }
            self.isSummarizing = false
        }
    }

    func stopRecording(modelContext: ModelContext? = nil) {
        guard state == .recording || state == .paused else { return }

        let wasPaused = state == .paused

        timer?.invalidate()
        timer = nil
        summaryTimer?.invalidate()
        summaryTimer = nil
        invalidateDurationEndTimer()
        // Don't cancel summaryTask — let in-flight LLM call finish; drainTask awaits it

        if !wasPaused {
            audioCaptureService.onAudioBuffer = nil
            audioCaptureService.onAudioLevel = nil
            audioCaptureService.onSilenceTimeout = nil
            audioMeter.reset()

            if let savedURL = audioCaptureService.stopCapture() {
                Self.logger.info("Audio saved to \(savedURL.path)")
            } else {
                Self.logger.warning("stopCapture returned nil — no audio file was saved")
            }
        }

        if let session = currentSession {
            session.endedAt = Date()
        }

        // Show stopping UI while draining ASR results
        state = .stopping
        SoundEffectService.play(.stop)
        stoppingStatus = "Finishing transcription..."

        // Background: drain ASR results → persist to SwiftData → signal completed
        drainTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // If we were recording (not paused), drain ASR
            if !wasPaused {
                await self.asrEngine.stopRecognition()
                guard !Task.isCancelled else { return }
            }

            // Promote orphaned partialText to a final segment
            if !self.partialText.isEmpty {
                Self.logger.info("Promoting orphaned partialText (\(self.partialText.count) chars)")
                let segment = TranscriptSegment(
                    startTime: self.segments.last?.endTime ?? 0,
                    endTime: self.clock.elapsedTime,
                    text: self.partialText,
                    confidence: 0.0,
                    language: nil
                )
                self.segments.append(segment)
                self.partialText = ""
            }

            // Persist transcript immediately (session + segments)
            self.stoppingStatus = "Saving..."
            self.persistSession(modelContext: modelContext, includeSummaries: false)

            // Wait for any in-flight periodic summary to finish
            if let summaryTask = self.summaryTask {
                self.stoppingStatus = "Generating summaries..."
                Self.logger.info("Awaiting in-flight periodic summary before persist...")
                await summaryTask.value
                self.summaryTask = nil
            }

            // Save summaries
            self.persistSummaries(modelContext: modelContext)

            // Dispatch background overall summary (independent of view lifecycle)
            if let session = self.currentSession, let modelContext {
                BackgroundSummaryService.shared.dispatchOverallSummary(
                    sessionID: session.id, container: modelContext.container
                )
                // Only auto-extract action items if enabled in settings
                if self.summarizerConfig.actionItemExtractionEnabled {
                    BackgroundSummaryService.shared.dispatchActionItemExtraction(
                        sessionID: session.id, container: modelContext.container
                    )
                }
            }

            self.state = .completed
        }
    }

    /// Persist current session + segments (and optionally summaries) to SwiftData. Idempotent — skips if already persisted.
    func persistSession(modelContext: ModelContext?, includeSummaries: Bool = true) {
        guard !sessionPersisted, let modelContext, let session = currentSession else { return }
        sessionPersisted = true
        session.audioFilePaths = recordedAudioFilePaths
        // Legacy compat: also set audioFilePath to first clip
        session.audioFilePath = recordedAudioFilePaths.first
        modelContext.insert(session)
        for segment in segments {
            segment.session = session
            modelContext.insert(segment)
        }
        if includeSummaries {
            for summary in summaries {
                summary.session = session
                modelContext.insert(summary)
            }
        }
        do {
            try modelContext.save()
            Self.logger.info("Session saved with \(self.segments.count) segments\(includeSummaries ? ", \(self.summaries.count) summaries" : "")")
        } catch {
            errorMessage = "Failed to save session: \(error.localizedDescription)"
        }
    }

    /// Persist summaries to an already-saved session.
    private func persistSummaries(modelContext: ModelContext?) {
        guard let modelContext, let session = currentSession else { return }
        for summary in summaries where summary.session == nil {
            summary.session = session
            modelContext.insert(summary)
        }
        do {
            try modelContext.save()
            Self.logger.info("Summaries saved: \(self.summaries.count)")
        } catch {
            errorMessage = "Failed to save summaries: \(error.localizedDescription)"
        }
    }

    func dismissCompletedRecording(modelContext: ModelContext? = nil) {
        guard state == .completed else { return }
        // Persist whatever we have before dismissing
        if drainTask != nil, let modelContext {
            drainTask?.cancel()
            persistSession(modelContext: modelContext)
        }
        drainTask = nil
        state = .idle
        segments = []
        partialText = ""
        clock.reset()
        audioMeter.reset()
        currentSession = nil
        errorMessage = nil
        sessionPersisted = false
        summaries = []
        isSummarizing = false
        latestSummary = nil
        latestKeyPoints = []
        summaryError = nil
        stoppingStatus = "Saving..."
        lastSummarizedSegmentCount = 0
        nextPeriodicCoveringFrom = 0
        periodicWindowCount = 0
        summaryTask?.cancel()
        summaryTask = nil
        clipTimeOffset = 0
        pausedElapsedTime = 0
        recordedAudioFilePaths = []
        invalidateDurationEndTimer()
        showDurationEndPrompt = false
        scheduledInfo = nil
    }

    func clearSummaryError() {
        summaryError = nil
    }

    /// Immediately persist session data and cancel all in-flight tasks.
    /// Used for fast app quit — no ASR drain, no LLM wait.
    func forceQuitPersist(modelContext: ModelContext?) {
        Self.logger.info("Force-quit persist: saving session data immediately")

        timer?.invalidate()
        timer = nil
        summaryTimer?.invalidate()
        summaryTimer = nil
        invalidateDurationEndTimer()
        summaryTask?.cancel()
        summaryTask = nil
        drainTask?.cancel()
        drainTask = nil

        // Stop audio capture if still running
        if state == .recording {
            audioCaptureService.onAudioBuffer = nil
            audioCaptureService.onAudioLevel = nil
            audioCaptureService.onSilenceTimeout = nil
            _ = audioCaptureService.stopCapture()
        }

        if let session = currentSession {
            session.endedAt = Date()
            session.isPartial = true
        }

        // Promote orphaned partialText
        if !partialText.isEmpty {
            let segment = TranscriptSegment(
                startTime: segments.last?.endTime ?? 0,
                endTime: clock.elapsedTime,
                text: partialText,
                confidence: 0.0,
                language: nil
            )
            segments.append(segment)
            partialText = ""
        }

        if sessionPersisted {
            // Session already saved by drainTask — just save isPartial + any pending summaries
            persistSummaries(modelContext: modelContext)
            if let modelContext {
                do {
                    try modelContext.save()
                    Self.logger.info("Force-quit: updated existing session (isPartial, summaries)")
                } catch {
                    Self.logger.error("Force-quit save failed: \(error.localizedDescription)")
                }
            }
        } else {
            persistSession(modelContext: modelContext)
        }
    }

    func awaitDrainCompletion() async {
        await drainTask?.value
    }

    private func handleTranscriptResult(_ result: TranscriptResult) {
        if result.isFinal {
            // Dedup: skip if last committed segment has the exact same text
            if let last = segments.last, last.text == result.text {
                partialText = ""
                return
            }
            // Apply clip offset for cumulative timestamps across pause/resume clips
            let segment = TranscriptSegment(
                startTime: result.startTime + clipTimeOffset,
                endTime: result.endTime + clipTimeOffset,
                text: result.text,
                confidence: result.confidence,
                language: result.language
            )
            segments.append(segment)
            partialText = ""
        } else {
            partialText = result.text
        }
    }
}
