//
//  SpeechToTextManager.swift
//  Offline, on-device speech-to-text with automatic language detection.
//
import Foundation
import AVFoundation
import CoreML
import Speech

final class SpeechToTextManager: NSObject {

    // MARK: - Singleton

    static let shared = SpeechToTextManager()
    private override init() {
        super.init()
        bootstrapAppleAdvancedPathSafetyState()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Types

    enum STTError: LocalizedError {
        case notReady
        case micPermissionDenied
        case audioSessionFailure
        case emptyRecording

        var errorDescription: String? {
            switch self {
            case .notReady: return "Speech model is not downloaded/ready yet."
            case .micPermissionDenied: return "Microphone permission was denied."
            case .audioSessionFailure: return "Could not configure the audio session."
            case .emptyRecording: return "No audio was captured."
            }
        }
    }

    enum SupportedLanguage: String, CaseIterable {
        case english = "en"
        case spanish = "es"
        case french  = "fr"

        var displayName: String {
            switch self {
            case .english: return "English"
            case .spanish: return "Spanish"
            case .french:  return "French"
            }
        }
    }

    enum OperationMode: String, CaseIterable {
        case liveStreaming
        case postRecording
    }
    
    enum TranscriptionEngine: String {
        case speechAnalyzer
        case dictationTranscriber
        case speechRecognizer
    }

    enum ModelProvider: String, CaseIterable {
        case appleModels

        var displayName: String {
            "Apple Models"
        }
    }

    var backendStatusLabel: String {
        if #available(iOS 26.0, *) {
            return useAdvancedAppleLiveTranscribers
                ? "Apple SpeechAnalyzer"
                : "Apple SpeechRecognizer"
        }
        return "Apple SpeechRecognizer"
    }

    var isSpeechRecognizerLiveBackend: Bool {
        preferredLivePartialEngine() == .speechRecognizer
    }

    struct DownloadStatus: Equatable {
        let progress: Double
        let downloadedBytes: Int64
        let totalBytes: Int64
    }

    struct LivePartialResult: Sendable {
        let text: String
        let language: SupportedLanguage
        let windowStartTime: TimeInterval
        let windowEndTime: TimeInterval
        let segments: [LiveTranscriptSegment]
        let committedText: String?
        let volatileText: String?

        init(
            text: String,
            language: SupportedLanguage,
            windowStartTime: TimeInterval,
            windowEndTime: TimeInterval,
            segments: [LiveTranscriptSegment],
            committedText: String? = nil,
            volatileText: String? = nil
        ) {
            self.text = text
            self.language = language
            self.windowStartTime = windowStartTime
            self.windowEndTime = windowEndTime
            self.segments = segments
            self.committedText = committedText
            self.volatileText = volatileText
        }
    }

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(DownloadStatus)
        case loadingModel(loaded: Int, total: Int)
        case ready
        case failed(String)
    }

    // MARK: - Public state

    private(set) var modelState: ModelState = .notDownloaded {
        didSet { onModelStateChange?(modelState) }
    }
    private(set) var isListening = false

    /// Hook this up to a progress bar / label in your opt-in UI.
    var onModelStateChange: ((ModelState) -> Void)?
    var onBackendStatusChange: ((String) -> Void)?

    // MARK: - Private

    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private let targetSampleRate: Double = 16_000
    private let bufferLock = NSLock()
    private let postRecordingFileLock = NSLock()
    private var postRecordingAudioFile: AVAudioFile?
    private var postRecordingAudioFileURL: URL?
    private var postRecordingAudioFileFinalized = false
    private var hasInputTapInstalled = false

    private var autoStopOnSilence = false
    private var requiredSilenceDuration: TimeInterval = 1.0
    private var silenceThreshold: Float = 0.003
    private var accumulatedSilenceDuration: TimeInterval = 0
    private var accumulatedRecordingDuration: TimeInterval = 0
    private var hasTriggeredAutoStop = false
    private let maxRecordingDuration: TimeInterval = 10 * 60
    private var liveLockedLanguage: SupportedLanguage?
    private var sessionPreferredLanguageHint: SupportedLanguage?
    private var pendingLiveLockLanguage: SupportedLanguage?
    private var pendingLiveLockConfirmations: Int = 0
    private var lastLiveResolvedLanguage: SupportedLanguage?
    private let liveLanguageLockMinimumSeconds: Double = 2.0
    private let liveLanguageLockConfirmationsRequired: Int = 2
    private let advancedLiveStreamStartupGraceSeconds: TimeInterval = 1.6
    private var didPrewarmRecordingPath = false
    private var hasLoggedRuntimeConfig = false
    private var hasDisabledSpeechAnalyzerForSession = false
    private var hasDisabledAdvancedLiveStreamForSession = false
    private var hasValidatedSpeechAnalyzerForSession = false
    private var loggedAppleGateFailures: Set<String> = []
    private var advancedLiveStreamNoResultStreak: Int = 0
    private let advancedLiveStreamNoResultDisableThreshold: Int = 8
    private let advancedLiveStreamNoResultMinimumLiveSeconds: TimeInterval = 3.5
    private var liveCaptureStartedAt: Date?
    private var activeCaptureSessionID: UUID?
    private struct SessionTranscribeCache {
        let sessionID: UUID
        let result: (text: String, language: SupportedLanguage)
        let timestamp: Date
    }
    private var lastSessionTranscribeCache: SessionTranscribeCache?
    private var lastPublishedLivePartialText: String = ""
    private var lastPublishedLivePartialWindowStartTime: TimeInterval = 0
    private var lastPublishedLivePartialWindowEndTime: TimeInterval = 0
    private var lastPublishedLivePartialAt: Date = .distantPast
    private let livePartialEmitMinimumInterval: TimeInterval = 0.30
    private let livePartialEmitMinimumCharAdvance: Int = 10
    private let livePartialEmitMinimumWindowAdvance: TimeInterval = 0.90
    private let firstLivePartialMinimumWindowEnd: TimeInterval = 1.80
    private let firstLivePartialMinimumChars: Int = 10
    private let appleCapabilityLock = NSLock()
    private var advancedAppleTranscriberCapable = false
    private var didCheckAdvancedAppleTranscriberCapability = false
    private let speechAnalyzerValidationTaskLock = NSLock()
    private var speechAnalyzerValidationTaskID: UUID?
    private var speechAnalyzerValidationTask: Task<Bool, Never>?
    private actor LiveDecodeCoordinator {
        private var isInFlight = false
        private var lastStart: Date?
        private var hasEmittedText = false

        func reset() {
            isInFlight = false
            lastStart = nil
            hasEmittedText = false
        }

        func markTextEmitted() {
            hasEmittedText = true
        }

        func tryBegin(now: Date) -> Bool {
            guard !isInFlight else { return false }
            let minInterval = hasEmittedText ? 0.45 : 0.20
            if let lastStart, now.timeIntervalSince(lastStart) < minInterval {
                return false
            }
            isInFlight = true
            self.lastStart = now
            return true
        }

        func end() {
            isInFlight = false
        }
    }
    private let liveDecodeCoordinator = LiveDecodeCoordinator()
    private let appleLiveStateLock = NSLock()
    private var appleLiveCoordinatorBox: AnyObject?
    private var appleLiveFinalText: String?
    private var lastNonEmptyLiveTranscriptText: String?
    private var isAppleLiveSessionStarting = false
    private let transcriptionLifecycleLock = NSLock()
    private var isFinalizingTranscript = false
    // SpeechRecognizer fallback needs a stable committed/volatile split to avoid
    // rolling-window rewrites and repeated text on long live sessions.
    private var speechRecognizerCommittedWords: [String] = []
    private var speechRecognizerLastHypothesisWords: [String] = []
    private var speechRecognizerLastVolatileWords: [String] = []
    private var speechRecognizerLastWindowStartTime: TimeInterval = 0
    private let speechRecognizerMutableTailWordCount = 8

    private func setAppleLiveFinalText(_ text: String?) {
        appleLiveStateLock.lock()
        appleLiveFinalText = text
        appleLiveStateLock.unlock()
    }

    private func setFinalizingTranscript(_ finalizing: Bool) {
        transcriptionLifecycleLock.lock()
        isFinalizingTranscript = finalizing
        transcriptionLifecycleLock.unlock()
    }

    private func getFinalizingTranscript() -> Bool {
        transcriptionLifecycleLock.lock()
        let value = isFinalizingTranscript
        transcriptionLifecycleLock.unlock()
        return value
    }

    private func getAppleLiveFinalText() -> String? {
        appleLiveStateLock.lock()
        let value = appleLiveFinalText
        appleLiveStateLock.unlock()
        return value
    }

    private func rememberLiveTranscriptTextIfNonEmpty(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        appleLiveStateLock.lock()
        lastNonEmptyLiveTranscriptText = normalized
        appleLiveStateLock.unlock()
    }

    private func getLastNonEmptyLiveTranscriptText() -> String? {
        appleLiveStateLock.lock()
        let value = lastNonEmptyLiveTranscriptText
        appleLiveStateLock.unlock()
        return value
    }

    @available(iOS 26.0, *)
    private func takeAppleLiveCoordinator() -> AppleLiveTranscriptionCoordinator? {
        appleLiveStateLock.lock()
        let coordinator = appleLiveCoordinatorBox as? AppleLiveTranscriptionCoordinator
        appleLiveCoordinatorBox = nil
        appleLiveStateLock.unlock()
        return coordinator
    }

    private func beginAppleLiveSessionStartIfNeeded() -> Bool {
        appleLiveStateLock.lock()
        defer { appleLiveStateLock.unlock() }
        if appleLiveCoordinatorBox != nil || isAppleLiveSessionStarting {
            return false
        }
        isAppleLiveSessionStarting = true
        return true
    }

    private func endAppleLiveSessionStartIfNeeded() {
        appleLiveStateLock.lock()
        isAppleLiveSessionStarting = false
        appleLiveStateLock.unlock()
    }

    private var useAdvancedAppleLiveTranscribers: Bool {
        guard #available(iOS 26.0, *) else {
            logAppleGateFailure("ios_version")
            return false
        }
        guard selectedModelProvider == .appleModels else {
            logAppleGateFailure("model_provider")
            return false
        }
        guard operationMode == .liveStreaming else {
            logAppleGateFailure("operation_mode")
            return false
        }
        guard isAdvancedApplePathExplicitlyEnabled else {
            logAppleGateFailure("explicit_opt_in")
            return false
        }
        guard !hasDisabledSpeechAnalyzerForSession else {
            logAppleGateFailure("disabled_for_session")
            return false
        }
        guard !hasDisabledAdvancedLiveStreamForSession else {
            logAppleGateFailure("live_stream_disabled_for_session")
            return false
        }
        guard !isAppleAdvancedPathQuarantined() else {
            logAppleGateFailure("quarantined")
            return false
        }
        appleCapabilityLock.lock()
        let enabled = advancedAppleTranscriberCapable
        appleCapabilityLock.unlock()
        if !enabled {
            logAppleGateFailure("runtime_capability_check")
        }
        return enabled
    }

    private func logAppleGateFailure(_ reason: String) {
        let key = "\(operationMode.rawValue):\(reason)"
        guard !loggedAppleGateFailures.contains(key) else { return }
        loggedAppleGateFailures.insert(key)
        debugTrace("apple_gate fail=\(reason)")
    }

    private func setAdvancedAppleTranscriberCapability(_ enabled: Bool, checked: Bool) {
        appleCapabilityLock.lock()
        advancedAppleTranscriberCapable = enabled
        didCheckAdvancedAppleTranscriberCapability = checked
        appleCapabilityLock.unlock()
    }

    private func shouldSkipAdvancedAppleCapabilityRefresh() -> Bool {
        appleCapabilityLock.lock()
        let shouldSkip = didCheckAdvancedAppleTranscriberCapability
        appleCapabilityLock.unlock()
        return shouldSkip
    }

    private func bootstrapAppleAdvancedPathSafetyState() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.appleAdvancedArmedKey) {
            defaults.set(true, forKey: Self.appleAdvancedQuarantinedKey)
            defaults.set(false, forKey: Self.appleAdvancedArmedKey)
        }
#if DEBUG
        // Enable advanced Apple path testing by default on debug builds only.
        if defaults.object(forKey: Self.appleAdvancedExplicitOptInKey) == nil {
            defaults.set(true, forKey: Self.appleAdvancedExplicitOptInKey)
        }

        // Developer convenience: automatically clear quarantine on launch in debug
        // so each run can attempt advanced Apple path without manual reset calls.
        if defaults.bool(forKey: Self.appleAdvancedQuarantinedKey) {
            defaults.set(false, forKey: Self.appleAdvancedQuarantinedKey)
            defaults.set(false, forKey: Self.appleAdvancedArmedKey)
        }
#endif
    }

    private func isAppleAdvancedPathQuarantined() -> Bool {
        UserDefaults.standard.bool(forKey: Self.appleAdvancedQuarantinedKey)
    }

    // Safe default: advanced Apple live transcriber path must be explicit opt-in.
    private var isAdvancedApplePathExplicitlyEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.appleAdvancedExplicitOptInKey)
    }

    private func armAppleAdvancedPath() {
        UserDefaults.standard.set(true, forKey: Self.appleAdvancedArmedKey)
    }

    private func disarmAppleAdvancedPath() {
        UserDefaults.standard.set(false, forKey: Self.appleAdvancedArmedKey)
    }

    /// Controlled recovery hook: keeps quarantine mechanism, but allows an explicit retry.
    func clearAppleAdvancedPathQuarantineForRetry() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: Self.appleAdvancedQuarantinedKey)
        defaults.set(false, forKey: Self.appleAdvancedArmedKey)
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        advancedLiveStreamNoResultStreak = 0
        resetLivePartialOutputState()
        sessionPreferredLanguageHint = nil
        setAdvancedAppleTranscriberCapability(false, checked: false)
        Task(priority: .utility) { [weak self] in
            await self?.refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: true)
        }
    }

    private func refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: Bool) async {
        guard selectedModelProvider == .appleModels else {
            setAdvancedAppleTranscriberCapability(false, checked: false)
            disarmAppleAdvancedPath()
            return
        }
        guard !isAppleAdvancedPathQuarantined() else {
            setAdvancedAppleTranscriberCapability(false, checked: true)
            publishBackendStatus()
            return
        }
        guard #available(iOS 26.0, *) else {
            setAdvancedAppleTranscriberCapability(false, checked: true)
            return
        }
        if !force, shouldSkipAdvancedAppleCapabilityRefresh() { return }

        let preferredLanguage = effectiveSessionLanguage(preferredLanguage: nil)
        let preferredLocale = speechAnalyzerLocaleHint(for: preferredLanguage) ?? Locale.current

        let dictationSupportedLocale = await DictationTranscriber.supportedLocale(equivalentTo: preferredLocale)
        let speechSupportedLocale: Locale?
        if SpeechTranscriber.isAvailable {
            speechSupportedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: preferredLocale)
        } else {
            speechSupportedLocale = nil
        }

        let runtimeCapable = (dictationSupportedLocale != nil) || (speechSupportedLocale != nil)
        let enabled = runtimeCapable && isAdvancedApplePathExplicitlyEnabled
        debugTrace(
            "apple_runtime_capability preferred=\(preferredLocale.identifier) dictation=\(dictationSupportedLocale != nil) speech=\(speechSupportedLocale != nil) enabled=\(enabled)"
        )
        setAdvancedAppleTranscriberCapability(enabled, checked: true)
        publishBackendStatus()
    }

    var onSilenceAutoStopTriggered: (() -> Void)?
    var onAudioLevelChange: ((Float) -> Void)?
    
    /// Compatibility bridge used by existing logic; now driven by model provider selection.
    var useSpeechAnalyzerWhenAvailable: Bool {
        get { selectedModelProvider == .appleModels }
        set { setModelProvider(.appleModels) }
    }

    private static let modelReadyKey = "SpeechToTextManager.modelReadyV2"
    private static let optedInKey = "SpeechToTextManager.optedIn"
    private static let liveTranscriptionEnabledKey = "SpeechToTextManager.liveTranscriptionEnabled"
    private static let modelProviderKey = "SpeechToTextManager.modelProvider"
    private static let appleAdvancedArmedKey = "SpeechToTextManager.appleAdvancedArmed"
    private static let appleAdvancedQuarantinedKey = "SpeechToTextManager.appleAdvancedQuarantined"
    private static let appleAdvancedExplicitOptInKey = "SpeechToTextManager.appleAdvancedExplicitOptIn"
    
    /// True once the model is downloaded AND loaded into memory — the only
    /// state in which recording/transcription is actually usable.
    var isReady: Bool {
        if case .ready = modelState(for: operationMode) { return true }
        return false
    }

    /// True if the user has opted in, regardless of whether the download
    /// finished. Use this at launch/entry points to decide whether to
    /// silently resume the download screen instead of showing the opt-in CTA.
    var hasOptedIn: Bool {
        UserDefaults.standard.bool(forKey: Self.optedInKey)
    }

    var isLiveTranscriptionEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.liveTranscriptionEnabledKey) == nil {
                return false
            }
            return UserDefaults.standard.bool(forKey: Self.liveTranscriptionEnabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.liveTranscriptionEnabledKey)
        }
    }

    private var operationMode: OperationMode = .liveStreaming

    var selectedModelProvider: ModelProvider {
        get {
            if let raw = UserDefaults.standard.string(forKey: Self.modelProviderKey),
               let provider = ModelProvider(rawValue: raw) {
                return provider
            }
            return .appleModels
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.modelProviderKey)
        }
    }

    func setModelProvider(_ provider: ModelProvider) {
        let provider: ModelProvider = .appleModels
        let previous = selectedModelProvider
        guard previous != provider else { return }
        cancelSpeechAnalyzerValidationTaskIfNeeded()
        selectedModelProvider = provider
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        loggedAppleGateFailures.removeAll()
        advancedLiveStreamNoResultStreak = 0
        resetLivePartialOutputState()
        liveCaptureStartedAt = nil
        activeCaptureSessionID = nil
        lastSessionTranscribeCache = nil
        setAdvancedAppleTranscriberCapability(false, checked: false)
        hasLoggedRuntimeConfig = false
        setAppleLiveFinalText(nil)
        modelState = modelState(for: operationMode)
        publishBackendStatus()

        Task(priority: .utility) { [weak self] in
            await self?.refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: true)
        }
    }

    func modelState(for _: OperationMode) -> ModelState {
        return .ready
    }

    func setOperationMode(_ mode: OperationMode) {
        guard operationMode != mode else { return }
        operationMode = mode
        // Mode switch should start with a fresh analyzer session gate.
        // Otherwise a live-mode disable can incorrectly force recognizer in post mode.
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        loggedAppleGateFailures.removeAll()
        advancedLiveStreamNoResultStreak = 0
        resetLivePartialOutputState()
        liveCaptureStartedAt = nil
        activeCaptureSessionID = nil
        lastSessionTranscribeCache = nil
        sessionPreferredLanguageHint = nil
        modelState = modelState(for: mode)
        publishBackendStatus()
        debugLogRuntimeConfiguration(reason: "operation_mode_changed")
    }
    
    // Safe to call again on relaunch if a previous download was interrupted —
    // the underlying downloader resumes partial files rather than restarting.
    func prepareOnOptIn() async {
        UserDefaults.standard.set(true, forKey: Self.optedInKey)
        UserDefaults.standard.set(true, forKey: Self.modelReadyKey)
        modelState = .ready
    }

    /// Call at app launch. Three outcomes:
    /// - never opted in -> stays `.notDownloaded`, show the opt-in CTA
    /// - opted in and model already downloaded -> silently loads, becomes `.ready`
    /// - opted in but download was interrupted (app killed mid-download) ->
    ///   resumes the download automatically, UI should show the progress screen
    func restoreIfAlreadyDownloaded() async {
        guard hasOptedIn else { return }
        await prepareOnOptIn()
    }

    /// Call this at any entry point where the user tries to use the feature
    /// (tap mic, open a voice-note screen, etc). Returns true if usable now;
    /// if false, the caller should navigate to / show the download-progress UI
    /// instead of proceeding, and resume the download if it isn't already running.
    func gateFeatureUsage() async -> Bool {
        await refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: true)
        return true
    }

    // MARK: - Step 2: Mic capture

    func requestMicPermission() async -> Bool {
        if #available(iOS 17.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                break
            @unknown default:
                break
            }
        } else {
            let permission = AVAudioSession.sharedInstance().recordPermission
            if permission == .granted { return true }
            if permission == .denied { return false }
        }

        return await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    /// Prepares the audio route/session once so the first user tap doesn't pay
    /// the full activation cost on the main interaction path.
    func prewarmRecordingPathIfNeeded() {
        guard !didPrewarmRecordingPath else { return }
        guard case .ready = modelState else { return }
        if #available(iOS 17.0, *) {
            guard AVAudioApplication.shared.recordPermission == .granted else { return }
        } else {
            guard AVAudioSession.sharedInstance().recordPermission == .granted else { return }
        }
        didPrewarmRecordingPath = true

        DispatchQueue.global(qos: .userInitiated).async {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.record, mode: .measurement, options: .duckOthers)
                try session.setActive(true)
                // Touching these upfront avoids some first-use graph costs.
                _ = self.audioEngine.inputNode
                self.audioEngine.prepare()
                try session.setActive(false)
            } catch {
                // Allow retry if warm-up failed.
                DispatchQueue.main.async {
                    self.didPrewarmRecordingPath = false
                }
            }
        }
    }

    func startListening(
        preferredLanguage: SupportedLanguage? = nil,
        autoStopOnSilence: Bool = false,
        silenceDuration: TimeInterval = 1.0,
        silenceThreshold: Float = 0.003
    ) throws {
        let currentModelState = modelState(for: operationMode)
        modelState = currentModelState
        guard case .ready = currentModelState else { throw STTError.notReady }

        self.autoStopOnSilence = autoStopOnSilence
        requiredSilenceDuration = silenceDuration
        self.silenceThreshold = silenceThreshold
        accumulatedSilenceDuration = 0
        accumulatedRecordingDuration = 0
        hasTriggeredAutoStop = false
        liveCaptureStartedAt = Date()
        activeCaptureSessionID = UUID()
        lastSessionTranscribeCache = nil
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        loggedAppleGateFailures.removeAll()
        advancedLiveStreamNoResultStreak = 0
        sessionPreferredLanguageHint = preferredLanguage
        liveLockedLanguage = preferredLanguage
        pendingLiveLockLanguage = nil
        pendingLiveLockConfirmations = 0
        lastLiveResolvedLanguage = nil
        setFinalizingTranscript(false)
        setAppleLiveFinalText(nil)
        advancedLiveStreamNoResultStreak = 0
        resetLivePartialOutputState()
        appleLiveStateLock.lock()
        lastNonEmptyLiveTranscriptText = nil
        appleLiveStateLock.unlock()
        speechRecognizerCommittedWords = []
        speechRecognizerLastHypothesisWords = []
        speechRecognizerLastVolatileWords = []
        speechRecognizerLastWindowStartTime = 0
        Task(priority: .utility) { [liveDecodeCoordinator] in
            await liveDecodeCoordinator.reset()
        }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true)
        } catch {
            throw STTError.audioSessionFailure
        }

        bufferLock.lock()
        sampleBuffer.removeAll()
        bufferLock.unlock()
        if operationMode != .postRecording {
            cleanupPostRecordingAudioFileIfNeeded()
        }

        let input = audioEngine.inputNode
        if hasInputTapInstalled {
            input.removeTap(onBus: 0)
            hasInputTapInstalled = false
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw STTError.audioSessionFailure
        }
        if operationMode == .postRecording {
            try preparePostRecordingAudioFileIfNeeded(format: targetFormat)
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let ratio = self.targetSampleRate / inputFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

            var convError: NSError?
            converter.convert(to: outBuffer, error: &convError) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard convError == nil, let channelData = outBuffer.floatChannelData else { return }
            let frames = Array(UnsafeBufferPointer(start: channelData[0], count: Int(outBuffer.frameLength)))

            self.bufferLock.lock()
            self.sampleBuffer.append(contentsOf: frames)
            self.bufferLock.unlock()
            self.appendPostRecordingBufferIfNeeded(outBuffer)

            if self.selectedModelProvider == .appleModels,
               self.useAdvancedAppleLiveTranscribers {
                self.pushAudioBufferToAppleLiveSessionIfNeeded(outBuffer)
            }

            let frameDuration = Double(outBuffer.frameLength) / self.targetSampleRate
            self.accumulatedRecordingDuration += frameDuration
            let energy = frames.reduce(0) { partialResult, sample in
                partialResult + (sample * sample)
            }
            let rms = sqrt(energy / Float(max(frames.count, 1)))
            let normalizedLevel = min(max(rms / 0.08, 0), 1)

            DispatchQueue.main.async {
                self.onAudioLevelChange?(normalizedLevel)
            }

            if !self.hasTriggeredAutoStop, self.accumulatedRecordingDuration >= self.maxRecordingDuration {
                self.hasTriggeredAutoStop = true
                DispatchQueue.main.async {
                    guard self.isListening else { return }
                    self.stopListening()
                    self.onSilenceAutoStopTriggered?()
                }
                return
            }

            if self.autoStopOnSilence {
                if rms < self.silenceThreshold {
                    self.accumulatedSilenceDuration += frameDuration
                } else {
                    self.accumulatedSilenceDuration = 0
                }

                if !self.hasTriggeredAutoStop, self.accumulatedSilenceDuration >= self.requiredSilenceDuration {
                    self.hasTriggeredAutoStop = true
                    DispatchQueue.main.async {
                        guard self.isListening else { return }
                        self.stopListening()
                        self.onSilenceAutoStopTriggered?()
                    }
                }
            }
        }
        hasInputTapInstalled = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            hasInputTapInstalled = false
            cleanupPostRecordingAudioFileIfNeeded()
            try? AVAudioSession.sharedInstance().setActive(false)
            throw STTError.audioSessionFailure
        }
        isListening = true
        if selectedModelProvider == .appleModels,
           useAdvancedAppleLiveTranscribers {
            Task(priority: .userInitiated) { [weak self] in
                await self?.startAppleLiveSessionIfNeeded()
            }
        }
    }

    func stopListening() {
        if hasInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTapInstalled = false
        }
        audioEngine.stop()
        finalizePostRecordingAudioFileIfNeeded()
        try? AVAudioSession.sharedInstance().setActive(false)
        isListening = false

        onAudioLevelChange?(0)
        accumulatedSilenceDuration = 0
        accumulatedRecordingDuration = 0
        hasTriggeredAutoStop = false
        liveCaptureStartedAt = nil
        speechRecognizerCommittedWords = []
        speechRecognizerLastHypothesisWords = []
        speechRecognizerLastVolatileWords = []
        speechRecognizerLastWindowStartTime = 0
        resetLivePartialOutputState()
        Task(priority: .utility) { [liveDecodeCoordinator] in
            await liveDecodeCoordinator.reset()
        }
        if #available(iOS 26.0, *),
           selectedModelProvider == .appleModels,
           appleLiveCoordinator != nil {
            Task(priority: .userInitiated) { [weak self] in
                await self?.finalizeAppleLiveSessionIfNeeded()
            }
        }
    }

    @available(iOS 26.0, *)
    private var appleLiveCoordinator: AppleLiveTranscriptionCoordinator? {
        get {
            appleLiveStateLock.lock()
            defer { appleLiveStateLock.unlock() }
            return appleLiveCoordinatorBox as? AppleLiveTranscriptionCoordinator
        }
        set {
            appleLiveStateLock.lock()
            appleLiveCoordinatorBox = newValue
            appleLiveStateLock.unlock()
        }
    }

    private func pushAudioBufferToAppleLiveSessionIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard #available(iOS 26.0, *), selectedModelProvider == .appleModels, useAdvancedAppleLiveTranscribers else { return }
        guard let appleLiveCoordinator else { return }
        guard let copiedBuffer = copyPCMBuffer(buffer) else { return }
        appleLiveCoordinator.pushBuffer(copiedBuffer)
    }

    private func copyPCMBuffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameCapacity) else {
            return nil
        }
        copy.frameLength = source.frameLength
        guard let sourceChannelData = source.floatChannelData,
              let copiedChannelData = copy.floatChannelData else {
            return nil
        }
        let channelCount = Int(source.format.channelCount)
        let frameCount = Int(source.frameLength)
        for channel in 0..<channelCount {
            copiedChannelData[channel].update(from: sourceChannelData[channel], count: frameCount)
        }
        return copy
    }

    private func startAppleLiveSessionIfNeeded() async {
        // Start exactly one live analyzer session per recording start.
        // This removes the old per-tick session churn that caused UI stalls.
        guard #available(iOS 26.0, *), selectedModelProvider == .appleModels else { return }

        guard beginAppleLiveSessionStartIfNeeded() else { return }

        defer {
            endAppleLiveSessionStartIfNeeded()
        }

        do {
            armAppleAdvancedPath()
            let coordinator = AppleLiveTranscriptionCoordinator()
            let language = liveLockedLanguage
                ?? sessionPreferredLanguageHint
                ?? pendingLiveLockLanguage
                ?? preferredDeviceSupportedLanguage()
                ?? .english
            let localeHint = speechAnalyzerLocaleHint(for: language)
            _ = try await coordinator.start(localeHint: localeHint)
            appleLiveCoordinator = coordinator
        } catch {
            disarmAppleAdvancedPath()
            hasDisabledAdvancedLiveStreamForSession = true
            debugTrace("live_stream session_start_failed fallback=windowed_partial error=\(error.localizedDescription)")
        }
    }

    private func finalizeAppleLiveSessionIfNeeded() async {
        // Finalize once on stop so volatile tail is committed before UI close.
        guard #available(iOS 26.0, *) else { return }

        guard let coordinator = takeAppleLiveCoordinator() else { return }

        do {
            try await coordinator.stop(finalize: true)
            disarmAppleAdvancedPath()
            let language = liveLockedLanguage ?? lastLiveResolvedLanguage ?? preferredDeviceSupportedLanguage() ?? .english
            if let finalPartial = coordinator.latestLivePartial(language: language) {
                setAppleLiveFinalText(finalPartial.text)
            }
        } catch {
        }
    }

    private func latestAppleLivePartialResult(preferredLanguage: SupportedLanguage?) -> LivePartialResult? {
        guard #available(iOS 26.0, *) else { return nil }
        let language = preferredLanguage ?? liveLockedLanguage ?? lastLiveResolvedLanguage ?? preferredDeviceSupportedLanguage() ?? .english

        appleLiveStateLock.lock()
        let coordinator = appleLiveCoordinatorBox as? AppleLiveTranscriptionCoordinator
        appleLiveStateLock.unlock()
        let partial = coordinator?.latestLivePartial(language: language)
        if let text = partial?.text {
            rememberLiveTranscriptTextIfNonEmpty(text)
        }
        return partial
    }

    // MARK: - Step 3: Transcription

    /// Stops listening (if active) and returns transcript text plus language used.
    /// In live-streaming mode, this final decode is performed with the Small model
    /// for higher post-recording accuracy.
    func transcribe(preferredLanguage: SupportedLanguage? = nil) async throws -> (text: String, language: SupportedLanguage) {
        let transcribeModeSnapshot = operationMode
        if let activeCaptureSessionID,
           let cache = lastSessionTranscribeCache,
           cache.sessionID == activeCaptureSessionID,
           Date().timeIntervalSince(cache.timestamp) < 3.0 {
            debugTrace("transcribe dedupe reuse session=\(activeCaptureSessionID.uuidString)")
            return cache.result
        }
        if let preferredLanguage {
            sessionPreferredLanguageHint = preferredLanguage
            liveLockedLanguage = preferredLanguage
        }
        setFinalizingTranscript(true)
        defer { setFinalizingTranscript(false) }
        debugTrace("transcribe begin mode=\(transcribeModeSnapshot.rawValue) preferred=\(preferredLanguage?.rawValue ?? "auto")")
        defer {
            if operationMode == .postRecording {
                cleanupPostRecordingAudioFileIfNeeded()
            }
        }
        if #available(iOS 26.0, *),
           appleLiveCoordinator != nil {
            await finalizeAppleLiveSessionIfNeeded()
        }
        debugLogRuntimeConfiguration(reason: "final_transcribe", modeOverride: transcribeModeSnapshot)
        let preferredEngine = preferredFinalTranscriptionEngine()
        debugLogEngineSelection(
            phase: "final_transcribe",
            engine: preferredEngine,
            detail: "mode=\(transcribeModeSnapshot.rawValue) preferredLanguage=\(preferredLanguage?.rawValue ?? "auto") analyzer_gate=\(speechAnalyzerGateReason)"
        )
        let finalResult: (text: String, language: SupportedLanguage)
        switch preferredEngine {
        case .speechAnalyzer:
            do {
                let analyzerResult = try await transcribeWithSpeechAnalyzer(preferredLanguage: preferredLanguage)
                if analyzerResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalResult = try await transcribeWithSpeechRecognizer(preferredLanguage: preferredLanguage)
                    break
                }
                finalResult = analyzerResult
            } catch {
                if operationMode == .postRecording {
                    finalResult = try await transcribeWithSpeechRecognizer(preferredLanguage: preferredLanguage)
                    break
                }
                if shouldDisableSpeechAnalyzer(for: error) {
                    hasDisabledSpeechAnalyzerForSession = true
                    publishBackendStatus()
                    debugTrace("speech_analyzer_final disable_for_session reason=\(error.localizedDescription)")
                    finalResult = try await transcribeWithDictationTranscriber(preferredLanguage: preferredLanguage)
                    break
                }
                debugTrace("speech_analyzer_final transient_error fallback=speech_recognizer reason=\(error.localizedDescription)")
                finalResult = try await transcribeWithSpeechRecognizer(preferredLanguage: preferredLanguage)
                break
            }
        case .dictationTranscriber:
            finalResult = try await transcribeWithDictationTranscriber(preferredLanguage: preferredLanguage)
        case .speechRecognizer:
            finalResult = try await transcribeWithSpeechRecognizer(preferredLanguage: preferredLanguage)
        }
        debugTrace("transcribe end mode=\(transcribeModeSnapshot.rawValue) lang=\(finalResult.language.rawValue) chars=\(finalResult.text.count) text=\"\(logPreview(finalResult.text))\"")
        if let activeCaptureSessionID {
            lastSessionTranscribeCache = SessionTranscribeCache(
                sessionID: activeCaptureSessionID,
                result: finalResult,
                timestamp: Date()
            )
        }
        return finalResult
    }

    /// Lightweight partial transcription for live preview while recording.
    /// Uses a short rolling audio window to keep decoding fast.
    func transcribePartialCurrentBuffer(
        preferredLanguage: SupportedLanguage? = nil,
        maxAudioSeconds: Double = 8.0,
        minimumAudioSeconds: Double = 0.8
    ) async throws -> LivePartialResult? {
        if getFinalizingTranscript() { return nil }
        if let preferredLanguage {
            sessionPreferredLanguageHint = preferredLanguage
            liveLockedLanguage = preferredLanguage
        }
        debugLogRuntimeConfiguration(reason: "live_partial")
        let preferredEngine = preferredLivePartialEngine()
        debugLogEngineSelection(
            phase: "live_partial",
            engine: preferredEngine,
            detail: "mode=\(operationMode.rawValue) preferredLanguage=\(preferredLanguage?.rawValue ?? "auto") analyzer_gate=\(speechAnalyzerGateReason)"
        )

        if #available(iOS 26.0, *) {
            let useAdvancedStream = useAdvancedAppleLiveTranscribers
            if useAdvancedStream {
                // Apple path: use one continuous analyzer session and read snapshots,
                // instead of re-transcribing rolling windows every tick.
                if appleLiveCoordinator == nil {
                    await startAppleLiveSessionIfNeeded()
                }
                let result = latestAppleLivePartialResult(preferredLanguage: preferredLanguage)
                if let result {
                    advancedLiveStreamNoResultStreak = 0
                    return publishLivePartialResultIfMeaningful(result, phase: "live_partial_stream")
                } else {
                    advancedLiveStreamNoResultStreak += 1
                    let liveElapsed = liveCaptureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if liveElapsed < advancedLiveStreamStartupGraceSeconds {
                        // Dictation stream frequently needs a short warm-up; avoid noisy
                        // early fallback churn before first stream hypotheses arrive.
                        return nil
                    }
                    debugTrace("live_partial stream_unavailable fallback=windowed_partial reason=no_stream_result")
                    if advancedLiveStreamNoResultStreak >= advancedLiveStreamNoResultDisableThreshold,
                       liveElapsed >= advancedLiveStreamNoResultMinimumLiveSeconds,
                       !hasDisabledAdvancedLiveStreamForSession {
                        hasDisabledAdvancedLiveStreamForSession = true
                        debugTrace(
                            "live_stream disabled_for_session reason=no_stream_result_streak count=\(advancedLiveStreamNoResultStreak) live_s=\(String(format: "%.2f", liveElapsed))"
                        )
                    }
                }
            }
            if canUseSpeechAnalyzer {
                debugTrace("live_partial stream_unavailable fallback=windowed_speech_analyzer")
            }
        }

        switch preferredEngine {
        case .speechAnalyzer:
            do {
                let result = try await transcribePartialCurrentBufferWithSpeechAnalyzer(
                    preferredLanguage: preferredLanguage,
                    maxAudioSeconds: maxAudioSeconds,
                    minimumAudioSeconds: minimumAudioSeconds
                )
                return publishLivePartialResultIfMeaningful(result, phase: "speech_analyzer_partial")
            } catch {
                if shouldDisableSpeechAnalyzer(for: error) {
                    hasDisabledSpeechAnalyzerForSession = true
                    publishBackendStatus()
                    debugTrace("speech_analyzer_partial disable_for_session reason=\(error.localizedDescription)")
                    let result = try await transcribePartialCurrentBufferWithSpeechRecognizer(
                        preferredLanguage: preferredLanguage,
                        maxAudioSeconds: maxAudioSeconds,
                        minimumAudioSeconds: minimumAudioSeconds
                    )
                    return publishLivePartialResultIfMeaningful(result, phase: "speech_recognizer_partial_fallback")
                }
                debugTrace("speech_analyzer_partial transient_error fallback=speech_recognizer reason=\(error.localizedDescription)")
                let result = try await transcribePartialCurrentBufferWithSpeechRecognizer(
                    preferredLanguage: preferredLanguage,
                    maxAudioSeconds: maxAudioSeconds,
                    minimumAudioSeconds: minimumAudioSeconds
                )
                return publishLivePartialResultIfMeaningful(result, phase: "speech_recognizer_partial_fallback")
            }
        case .dictationTranscriber:
            let result = latestAppleLivePartialResult(preferredLanguage: preferredLanguage)
            return publishLivePartialResultIfMeaningful(result, phase: "dictation_partial")
        case .speechRecognizer:
            let result = try await transcribePartialCurrentBufferWithSpeechRecognizer(
                preferredLanguage: preferredLanguage,
                maxAudioSeconds: maxAudioSeconds,
                minimumAudioSeconds: minimumAudioSeconds
            )
            return publishLivePartialResultIfMeaningful(result, phase: "speech_recognizer_partial")
        }
    }

    private func beginLivePartialDecodeIfPossible() async -> Bool {
        await liveDecodeCoordinator.tryBegin(now: Date())
    }

    private func snapshotAudioBuffer() -> [Float] {
        bufferLock.withLock {
            sampleBuffer
        }
    }

    private func preparePostRecordingAudioFileIfNeeded(format: AVAudioFormat) throws {
        guard operationMode == .postRecording else { return }
        cleanupPostRecordingAudioFileIfNeeded()
        let fileName = "stt-post-\(UUID().uuidString).wav"
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        let audioFile = try AVAudioFile(forWriting: fileURL, settings: format.settings)
        postRecordingFileLock.lock()
        postRecordingAudioFile = audioFile
        postRecordingAudioFileURL = fileURL
        postRecordingAudioFileFinalized = false
        postRecordingFileLock.unlock()
        debugTrace("post_recording file_opened path=\(fileURL.lastPathComponent) sample_rate=\(Int(format.sampleRate)) channels=\(format.channelCount)")
    }

    private func appendPostRecordingBufferIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard operationMode == .postRecording else { return }
        postRecordingFileLock.lock()
        let file = postRecordingAudioFile
        postRecordingFileLock.unlock()
        guard let file else { return }
        do {
            try file.write(from: buffer)
        } catch {
        }
    }

    private func finalizePostRecordingAudioFileIfNeeded() {
        guard operationMode == .postRecording else { return }
        postRecordingFileLock.lock()
        let alreadyFinalized = postRecordingAudioFileFinalized
        postRecordingAudioFile = nil
        let fileURL = postRecordingAudioFileURL
        if !alreadyFinalized {
            postRecordingAudioFileFinalized = true
        }
        postRecordingFileLock.unlock()
        guard !alreadyFinalized else { return }
        guard let fileURL else { return }
        debugTrace("post_recording file_finalize path=\(fileURL.lastPathComponent)")
        _ = try? AVAudioFile(forReading: fileURL)
    }

    private func loadPostRecordingAudioSamplesIfAvailable() throws -> [Float]? {
        guard operationMode == .postRecording else { return nil }
        postRecordingFileLock.lock()
        let fileURL = postRecordingAudioFileURL
        postRecordingFileLock.unlock()
        guard let fileURL else { return nil }

        let file = try AVAudioFile(forReading: fileURL)
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return [] }
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw STTError.audioSessionFailure
        }
        try file.read(into: sourceBuffer)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw STTError.audioSessionFailure
        }

        let outCapacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * (targetSampleRate / sourceFormat.sampleRate)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw STTError.audioSessionFailure
        }

        var conversionError: NSError?
        var didProvideSourceBuffer = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didProvideSourceBuffer {
                status.pointee = .endOfStream
                return nil
            }
            didProvideSourceBuffer = true
            status.pointee = .haveData
            return sourceBuffer
        }
        if let conversionError {
            throw conversionError
        }
        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    private func finalAudioForTranscription() throws -> [Float] {
        if operationMode == .postRecording {
            finalizePostRecordingAudioFileIfNeeded()
            if let postAudio = try loadPostRecordingAudioSamplesIfAvailable(),
               !postAudio.isEmpty {
                debugTrace("final_audio source=post_recording_file samples=\(postAudio.count) audio_s=\(String(format: "%.2f", Double(postAudio.count) / targetSampleRate))")
                return postAudio
            }
        }
        let audio = snapshotAudioBuffer()
        guard !audio.isEmpty else { throw STTError.emptyRecording }
        debugTrace("final_audio source=live_buffer samples=\(audio.count) audio_s=\(String(format: "%.2f", Double(audio.count) / targetSampleRate))")
        return audio
    }

    private func finalAudioForTranscriptionAsync() async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: STTError.audioSessionFailure)
                    return
                }
                do {
                    continuation.resume(returning: try self.finalAudioForTranscription())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func cleanupPostRecordingAudioFileIfNeeded() {
        postRecordingFileLock.lock()
        postRecordingAudioFile = nil
        let fileURL = postRecordingAudioFileURL
        postRecordingAudioFileURL = nil
        postRecordingAudioFileFinalized = false
        postRecordingFileLock.unlock()
        guard let fileURL else { return }
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
                debugTrace("post_recording file_cleanup path=\(fileURL.lastPathComponent)")
            }
        } catch {
        }
    }

    /// Current captured audio duration while recording.
    /// Used by live UI scheduler to avoid ultra-early partial decode churn.
    func currentBufferedAudioSeconds() -> Double {
        let samples = bufferLock.withLock { sampleBuffer.count }
        return Double(samples) / targetSampleRate
    }

    private func recentAudioWindow(_ audio: [Float], maxSeconds: Double) -> [Float] {
        let maxSamples = Int(targetSampleRate * max(1.0, maxSeconds))
        guard audio.count > maxSamples else { return audio }
        return Array(audio.suffix(maxSamples))
    }

    private func preferredDeviceSupportedLanguage() -> SupportedLanguage? {
        guard let preferredLocale = Locale.preferredLanguages.first?.lowercased() else {
            return nil
        }

        if preferredLocale.hasPrefix("en") { return .english }
        if preferredLocale.hasPrefix("es") { return .spanish }
        if preferredLocale.hasPrefix("fr") { return .french }
        return nil
    }

    private func preferredFinalTranscriptionEngine() -> TranscriptionEngine {
        if #available(iOS 26.0, *), canUseSpeechAnalyzer {
            return .speechAnalyzer
        }
        return .speechRecognizer
    }
    
    private func preferredLivePartialEngine() -> TranscriptionEngine {
        if #available(iOS 26.0, *) {
            return canUseSpeechAnalyzer ? .speechAnalyzer : .speechRecognizer
        }
        return .speechRecognizer
    }
    
    private var canAttemptSpeechAnalyzer: Bool {
        guard selectedModelProvider == .appleModels else { return false }
        guard !hasDisabledSpeechAnalyzerForSession else { return false }
        guard #available(iOS 26.0, *) else { return false }
        guard !isAppleAdvancedPathQuarantined() else { return false }
        // SpeechAnalyzer availability must not be coupled to advanced live-stream
        // opt-in/capability (SpeechTranscriber-specific gate).
        return true
    }

    private var canUseSpeechAnalyzer: Bool {
        canAttemptSpeechAnalyzer
    }

    private var speechAnalyzerGateReason: String {
        if selectedModelProvider != .appleModels { return "provider_not_apple_models" }
        if hasDisabledSpeechAnalyzerForSession { return "disabled_for_session" }
        if #unavailable(iOS 26.0) { return "ios_below_26" }
        if isAppleAdvancedPathQuarantined() { return "advanced_path_quarantined" }
        return "available"
    }
    
    private func transcribeWithSpeechAnalyzer(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        guard #available(iOS 26.0, *), canUseSpeechAnalyzer else { throw STTError.notReady }
        if let finalText = getAppleLiveFinalText()?.trimmingCharacters(in: .whitespacesAndNewlines), !finalText.isEmpty {
            let language = preferredLanguage ?? liveLockedLanguage ?? lastLiveResolvedLanguage ?? preferredDeviceSupportedLanguage() ?? .english
            return (finalText, language)
        }
        if let partial = latestAppleLivePartialResult(preferredLanguage: preferredLanguage) {
            return (partial.text, partial.language)
        }

        if isListening { stopListening() }
        let audio = try await finalAudioForTranscriptionAsync()
        let localeHint = speechAnalyzerLocaleHint(for: effectiveSessionLanguage(preferredLanguage: preferredLanguage))
        let engine = SpeechAnalyzerTranscriptionEngine()
        let audioSeconds = Double(audio.count) / targetSampleRate
        debugLogEngineSelection(
            phase: "speech_analyzer_final",
            engine: .speechAnalyzer,
            detail: "preset=transcription localeHint=\(localeHint?.identifier ?? "auto") audio_s=\(String(format: "%.2f", audioSeconds))"
        )
        let output = try await engine.transcribe(
            audio: audio,
            sampleRate: targetSampleRate,
            localeHint: localeHint,
            preset: .transcription
        )
        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: preferredLanguage)
        lastLiveResolvedLanguage = resolvedLanguage
        let normalizedOutput = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedOutput.isEmpty,
           operationMode == .liveStreaming,
           let fallback = getLastNonEmptyLiveTranscriptText(),
           !fallback.isEmpty {
            return (fallback, resolvedLanguage)
        }
        return (output.text, resolvedLanguage)
    }

    private func transcribeWithDictationTranscriber(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        if #available(iOS 26.0, *) {
            if let finalText = getAppleLiveFinalText()?.trimmingCharacters(in: .whitespacesAndNewlines), !finalText.isEmpty {
                let language = preferredLanguage ?? liveLockedLanguage ?? lastLiveResolvedLanguage ?? preferredDeviceSupportedLanguage() ?? .english
                return (finalText, language)
            }
            if let partial = latestAppleLivePartialResult(preferredLanguage: preferredLanguage) {
                return (partial.text, partial.language)
            }
        }
        return try await transcribeWithSpeechRecognizer(preferredLanguage: preferredLanguage)
    }

    private func transcribeWithSpeechRecognizer(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        if isListening { stopListening() }
        let audio = try await finalAudioForTranscriptionAsync()
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        let engine = SpeechRecognizerTranscriptionEngine()
        debugLogEngineSelection(
            phase: "speech_recognizer_final",
            engine: .speechRecognizer,
            detail: "localeHint=\(localeHint?.identifier ?? "auto") audio_s=\(String(format: "%.2f", Double(audio.count) / targetSampleRate))"
        )
        let output = try await engine.transcribe(
            audio: audio,
            sampleRate: targetSampleRate,
            localeHint: localeHint,
            timeoutInterval: nil
        )
        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: languageHint)
        lastLiveResolvedLanguage = resolvedLanguage
        return (output.text, resolvedLanguage)
    }
    
    private func transcribePartialCurrentBufferWithSpeechAnalyzer(
        preferredLanguage: SupportedLanguage?,
        maxAudioSeconds: Double,
        minimumAudioSeconds: Double
    ) async throws -> LivePartialResult? {
        guard #available(iOS 26.0, *), canUseSpeechAnalyzer else { throw STTError.notReady }
        guard await beginLivePartialDecodeIfPossible() else { return nil }
        defer {
            Task(priority: .utility) { [liveDecodeCoordinator] in
                await liveDecodeCoordinator.end()
            }
        }

        let fullAudio = snapshotAudioBuffer()
        let minimumSamples = Int(targetSampleRate * max(0.2, minimumAudioSeconds))
        guard fullAudio.count >= minimumSamples else { return nil }

        let audioWindow = recentAudioWindow(fullAudio, maxSeconds: maxAudioSeconds)
        let windowStartSample = max(0, fullAudio.count - audioWindow.count)
        let windowStartTime = TimeInterval(windowStartSample) / targetSampleRate
        let windowEndTime = TimeInterval(fullAudio.count) / targetSampleRate
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        let engine = SpeechAnalyzerTranscriptionEngine()
        let audioSeconds = Double(audioWindow.count) / targetSampleRate
        debugLogEngineSelection(
            phase: "speech_analyzer_partial",
            engine: .speechAnalyzer,
            detail: "preset=progressiveTranscription localeHint=\(localeHint?.identifier ?? "auto") window_s=\(String(format: "%.2f", audioSeconds))"
        )
        let output = try await engine.transcribe(
            audio: audioWindow,
            sampleRate: targetSampleRate,
            localeHint: localeHint,
            preset: .progressiveTranscription
        )

        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: languageHint)
        if sessionPreferredLanguageHint == nil {
            if pendingLiveLockLanguage == resolvedLanguage {
                pendingLiveLockConfirmations += 1
            } else {
                pendingLiveLockLanguage = resolvedLanguage
                pendingLiveLockConfirmations = 1
            }
            if pendingLiveLockConfirmations >= liveLanguageLockConfirmationsRequired {
                liveLockedLanguage = resolvedLanguage
            }
        }
        lastLiveResolvedLanguage = resolvedLanguage
        await liveDecodeCoordinator.markTextEmitted()

        let segments = [
            LiveTranscriptSegment(
                startTime: windowStartTime,
                endTime: windowEndTime,
                text: text
            )
        ]
        return LivePartialResult(
            text: text,
            language: resolvedLanguage,
            windowStartTime: windowStartTime,
            windowEndTime: windowEndTime,
            segments: segments
        )
    }

    private func transcribePartialCurrentBufferWithSpeechRecognizer(
        preferredLanguage: SupportedLanguage?,
        maxAudioSeconds: Double,
        minimumAudioSeconds: Double
    ) async throws -> LivePartialResult? {
        guard await beginLivePartialDecodeIfPossible() else { return nil }
        defer {
            Task(priority: .utility) { [liveDecodeCoordinator] in
                await liveDecodeCoordinator.end()
            }
        }

        let fullAudio = snapshotAudioBuffer()
        let minimumSamples = Int(targetSampleRate * max(0.2, minimumAudioSeconds))
        guard fullAudio.count >= minimumSamples else { return nil }

        // Keep extended context for Apple recognizer live mode, but cap window to
        // limit heavy re-decodes that can stall responsiveness on long sessions.
        let audioWindow = recentAudioWindow(fullAudio, maxSeconds: max(maxAudioSeconds, 24.0))
        let windowStartSample = max(0, fullAudio.count - audioWindow.count)
        let windowStartTime = TimeInterval(windowStartSample) / targetSampleRate
        let windowEndTime = TimeInterval(fullAudio.count) / targetSampleRate
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        let engine = SpeechRecognizerTranscriptionEngine()
        debugLogEngineSelection(
            phase: "speech_recognizer_partial",
            engine: .speechRecognizer,
            detail: "localeHint=\(localeHint?.identifier ?? "auto") window_s=\(String(format: "%.2f", Double(audioWindow.count) / targetSampleRate))"
        )
        let output = try await engine.transcribe(
            audio: audioWindow,
            sampleRate: targetSampleRate,
            localeHint: localeHint,
            timeoutInterval: 8.0
        )
        let rawText = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return nil }

        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: languageHint)
        if sessionPreferredLanguageHint == nil {
            if pendingLiveLockLanguage == resolvedLanguage {
                pendingLiveLockConfirmations += 1
            } else {
                pendingLiveLockLanguage = resolvedLanguage
                pendingLiveLockConfirmations = 1
            }
            if pendingLiveLockConfirmations >= liveLanguageLockConfirmationsRequired {
                liveLockedLanguage = resolvedLanguage
            }
        }
        lastLiveResolvedLanguage = resolvedLanguage
        await liveDecodeCoordinator.markTextEmitted()

        let currentWords = transcriptWords(from: rawText)
        guard !currentWords.isEmpty else { return nil }
        let split = stabilizedSpeechRecognizerSplit(
            for: currentWords,
            windowStartTime: windowStartTime
        )
        let renderedText = joinCommittedVolatileText(committed: split.committed, volatile: split.volatile)

        let segments = [
            LiveTranscriptSegment(
                startTime: windowStartTime,
                endTime: windowEndTime,
                text: renderedText
            )
        ]
        return LivePartialResult(
            text: renderedText,
            language: resolvedLanguage,
            windowStartTime: windowStartTime,
            windowEndTime: windowEndTime,
            segments: segments,
            committedText: split.committed,
            volatileText: split.volatile
        )
    }

    private func stabilizedSpeechRecognizerSplit(
        for currentWords: [String],
        windowStartTime: TimeInterval
    ) -> (committed: String, volatile: String) {
        if speechRecognizerLastHypothesisWords.isEmpty {
            speechRecognizerLastHypothesisWords = currentWords
            speechRecognizerLastVolatileWords = currentWords
            speechRecognizerLastWindowStartTime = windowStartTime
            return ("", currentWords.joined(separator: " "))
        }

        let previousVolatileWords = speechRecognizerLastVolatileWords
        let didWindowAdvance = windowStartTime > speechRecognizerLastWindowStartTime + 0.05
        if didWindowAdvance, !previousVolatileWords.isEmpty {
            // Rolling-window mode: when the recognizer drops old audio context, it
            // often returns a shifted hypothesis. Commit the dropped prefix from
            // the previous volatile tail only, so already-committed content is
            // never appended again.
            let overlap = maxWordOverlapSuffixPrefix(previous: previousVolatileWords, current: currentWords)
            if overlap >= 3, previousVolatileWords.count > overlap {
                let droppedPrefix = Array(previousVolatileWords.prefix(previousVolatileWords.count - overlap))
                appendCommittedWords(droppedPrefix)
            }
        }

        let sharedWithPrevious = sharedWordPrefixCount(lhs: speechRecognizerLastHypothesisWords, rhs: currentWords)
        let candidateCommitCount = max(0, sharedWithPrevious - speechRecognizerMutableTailWordCount)
        if candidateCommitCount > 0 {
            appendCommittedWords(Array(currentWords.prefix(candidateCommitCount)))
        }

        let boundaryOverlap = maxWordOverlapSuffixPrefix(previous: speechRecognizerCommittedWords, current: currentWords)
        let volatileWords = boundaryOverlap < currentWords.count
            ? Array(currentWords.dropFirst(boundaryOverlap))
            : []

        speechRecognizerLastHypothesisWords = currentWords
        speechRecognizerLastVolatileWords = volatileWords
        speechRecognizerLastWindowStartTime = windowStartTime
        let committed = speechRecognizerCommittedWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let volatile = volatileWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return (committed, volatile)
    }

    private func transcriptWords(from text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private func sharedWordPrefixCount(lhs: [String], rhs: [String]) -> Int {
        let maxCount = min(lhs.count, rhs.count)
        var index = 0
        while index < maxCount {
            if normalizedSpeechWord(lhs[index]) != normalizedSpeechWord(rhs[index]) {
                break
            }
            index += 1
        }
        return index
    }

    private func maxWordOverlapSuffixPrefix(previous: [String], current: [String]) -> Int {
        guard !previous.isEmpty, !current.isEmpty else { return 0 }
        let limit = min(previous.count, current.count)
        for size in stride(from: limit, through: 1, by: -1) {
            var matches = true
            for index in 0..<size {
                if normalizedSpeechWord(previous[previous.count - size + index]) != normalizedSpeechWord(current[index]) {
                    matches = false
                    break
                }
            }
            if matches { return size }
        }
        return 0
    }

    private func appendCommittedWords(_ candidateWords: [String]) {
        guard !candidateWords.isEmpty else { return }
        let overlap = maxWordOverlapSuffixPrefix(previous: speechRecognizerCommittedWords, current: candidateWords)
        if overlap < candidateWords.count {
            speechRecognizerCommittedWords.append(contentsOf: candidateWords.dropFirst(overlap))
        }
    }

    private func normalizedSpeechWord(_ word: String) -> String {
        word
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
            .lowercased()
    }

    private func joinCommittedVolatileText(committed: String, volatile: String) -> String {
        let prefix = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return tail }
        guard !tail.isEmpty else { return prefix }
        return prefix + " " + tail
    }

    private func shouldDisableSpeechAnalyzer(for error: Error) -> Bool {
        if error is CancellationError { return false }
        let message = error.localizedDescription.lowercased()
        if message.contains("not subscribed to transcription")
            || message.contains("cannot check the download status")
            || message.contains("asset")
            || message.contains("speech recognition")
            || message.contains("authorization")
            || message.contains("unsupported locale") {
            return true
        }
        // Keep analyzer enabled for transient runtime failures
        // (for example temporary locale/session allocation pressure).
        return false
    }

    private func ensureSpeechAnalyzerReadyForUse() async -> Bool {
        guard canAttemptSpeechAnalyzer else { return false }
        guard !hasValidatedSpeechAnalyzerForSession else { return true }
        guard #available(iOS 26.0, *) else { return false }

        if let existing = currentSpeechAnalyzerValidationTask() {
            return await existing.task.value
        }

        let taskID = UUID()
        let task = Task<Bool, Never> { [weak self] in
            guard let self else { return false }
            return await self.performSpeechAnalyzerReadinessProbe()
        }
        setSpeechAnalyzerValidationTask(task, id: taskID)
        let result = await task.value
        clearSpeechAnalyzerValidationTask(ifID: taskID)
        return result
    }

    @available(iOS 26.0, *)
    private func performSpeechAnalyzerReadinessProbe() async -> Bool {
        do {
            let engine = SpeechAnalyzerTranscriptionEngine()
            let preferred = liveLockedLanguage ?? preferredDeviceSupportedLanguage() ?? .english
            let localeHint = speechAnalyzerLocaleHint(for: preferred)
            try await engine.prepare(
                localeHint: speechAnalyzerLocaleHint(for: preferred),
                preset: .progressiveTranscription
            )
            // Readiness must prove decode viability, not only asset preparation.
            // This avoids showing "Speak now" when subscription/asset status will fail on first decode.
            _ = try await engine.transcribe(
                audio: speechAnalyzerPreflightProbeAudio(),
                sampleRate: targetSampleRate,
                localeHint: localeHint,
                preset: .progressiveTranscription
            )
            hasValidatedSpeechAnalyzerForSession = true
            publishBackendStatus()
            return true
        } catch {
            hasDisabledSpeechAnalyzerForSession = true
            hasValidatedSpeechAnalyzerForSession = false
            publishBackendStatus()
            return false
        }
    }

    private func currentSpeechAnalyzerValidationTask() -> (id: UUID, task: Task<Bool, Never>)? {
        speechAnalyzerValidationTaskLock.lock()
        defer { speechAnalyzerValidationTaskLock.unlock() }
        guard let id = speechAnalyzerValidationTaskID, let task = speechAnalyzerValidationTask else {
            return nil
        }
        return (id: id, task: task)
    }

    private func setSpeechAnalyzerValidationTask(_ task: Task<Bool, Never>, id: UUID) {
        speechAnalyzerValidationTaskLock.lock()
        defer { speechAnalyzerValidationTaskLock.unlock() }
        speechAnalyzerValidationTaskID = id
        speechAnalyzerValidationTask = task
    }

    private func clearSpeechAnalyzerValidationTask(ifID id: UUID) {
        speechAnalyzerValidationTaskLock.lock()
        defer { speechAnalyzerValidationTaskLock.unlock() }
        if speechAnalyzerValidationTaskID == id {
            speechAnalyzerValidationTaskID = nil
            speechAnalyzerValidationTask = nil
        }
    }

    private func cancelSpeechAnalyzerValidationTaskIfNeeded() {
        speechAnalyzerValidationTaskLock.lock()
        speechAnalyzerValidationTaskID = nil
        let task = speechAnalyzerValidationTask
        speechAnalyzerValidationTask = nil
        speechAnalyzerValidationTaskLock.unlock()
        task?.cancel()
    }

    private func publishBackendStatus() {
        let label = backendStatusLabel
        DispatchQueue.main.async { [weak self] in
            self?.onBackendStatusChange?(label)
        }
    }

    private func speechAnalyzerPreflightProbeAudio() -> [Float] {
        let sampleCount = max(1, Int(targetSampleRate * 0.35))
        return Array(repeating: 0, count: sampleCount)
    }

    private func speechAnalyzerLocaleHint(for language: SupportedLanguage?) -> Locale? {
        guard let language else { return nil }
        // Use a canonical language-only locale to avoid region churn (fr-FR/fr-CA/etc.)
        // that can trigger Speech locale allocation limits.
        return Locale(identifier: language.rawValue)
    }

    private func supportedLanguage(from locale: Locale, fallback: SupportedLanguage?) -> SupportedLanguage {
        let identifier = locale.identifier.lowercased()
        if identifier.hasPrefix("en") { return .english }
        if identifier.hasPrefix("es") { return .spanish }
        if identifier.hasPrefix("fr") { return .french }
        return fallback ?? preferredDeviceSupportedLanguage() ?? .english
    }

    private func effectiveSessionLanguage(preferredLanguage: SupportedLanguage?) -> SupportedLanguage {
        preferredLanguage
            ?? sessionPreferredLanguageHint
            ?? liveLockedLanguage
            ?? lastLiveResolvedLanguage
            ?? preferredDeviceSupportedLanguage()
            ?? .english
    }

    private func debugLogRuntimeConfiguration(reason: String, modeOverride: OperationMode? = nil) {
        let mode = modeOverride ?? operationMode
        debugTrace("runtime reason=\(reason) mode=\(mode.rawValue) provider=\(selectedModelProvider.rawValue)")
    }

    private func debugLogEngineSelection(phase: String, engine: TranscriptionEngine, detail: String) {
        debugTrace("engine phase=\(phase) selected=\(engine.rawValue) detail=\(detail)")
    }

    private func logDetectedLanguage(stage: String, language: SupportedLanguage) {
        debugTrace("language stage=\(stage) value=\(language.rawValue)")
    }

    private func logLivePartialResultIfPresent(_ result: LivePartialResult?, phase: String) {
        guard let result else { return }
        debugTrace(
            "live_output phase=\(phase) lang=\(result.language.rawValue) window=\(String(format: "%.2f", result.windowStartTime))-\(String(format: "%.2f", result.windowEndTime)) chars=\(result.text.count) text=\"\(logPreview(result.text))\""
        )
    }

    private func publishLivePartialResultIfMeaningful(_ result: LivePartialResult?, phase: String) -> LivePartialResult? {
        guard let result else { return nil }
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        if lastPublishedLivePartialText.isEmpty,
           result.windowEndTime < firstLivePartialMinimumWindowEnd,
           trimmed.count < firstLivePartialMinimumChars {
            debugTrace(
                "live_output suppress reason=early_warmup phase=\(phase) window_end=\(String(format: "%.2f", result.windowEndTime)) chars=\(trimmed.count)"
            )
            return nil
        }
        if !lastPublishedLivePartialText.isEmpty {
            let sinceLastEmission = now.timeIntervalSince(lastPublishedLivePartialAt)
            let windowAdvance = result.windowEndTime - lastPublishedLivePartialWindowEndTime
            let charGrowth = max(0, trimmed.count - lastPublishedLivePartialText.count)
            let punctuationAdvance = hasTerminalPunctuation(trimmed) && !hasTerminalPunctuation(lastPublishedLivePartialText)
            let sameTextAndWindow = trimmed == lastPublishedLivePartialText && abs(windowAdvance) < 0.05
            let meaningfulAdvance = charGrowth >= livePartialEmitMinimumCharAdvance
                || windowAdvance >= livePartialEmitMinimumWindowAdvance
                || punctuationAdvance
            let minorWindowMovement = windowAdvance < 0.45
            let sameWindowTrack = result.windowStartTime <= (lastPublishedLivePartialWindowStartTime + 0.20)
            let heavyRewrite = trimmed.count + 12 < lastPublishedLivePartialText.count
            let streamShortRewrite = phase == "live_partial_stream"
                && windowAdvance < 1.20
                && trimmed.count + 6 < lastPublishedLivePartialText.count

            if sameTextAndWindow {
                debugTrace("live_output suppress reason=duplicate phase=\(phase)")
                return nil
            }
            if streamShortRewrite {
                debugTrace(
                    "live_output suppress reason=stream_short_rewrite phase=\(phase) prev_chars=\(lastPublishedLivePartialText.count) new_chars=\(trimmed.count)"
                )
                return nil
            }
            if sameWindowTrack && minorWindowMovement && heavyRewrite {
                debugTrace(
                    "live_output suppress reason=unstable_rewrite phase=\(phase) prev_chars=\(lastPublishedLivePartialText.count) new_chars=\(trimmed.count)"
                )
                return nil
            }
            if sinceLastEmission < livePartialEmitMinimumInterval && !meaningfulAdvance {
                debugTrace(
                    "live_output suppress reason=throttled phase=\(phase) dt=\(String(format: "%.2f", sinceLastEmission)) chars=+\(charGrowth)"
                )
                return nil
            }
        }

        lastPublishedLivePartialText = trimmed
        lastPublishedLivePartialWindowStartTime = result.windowStartTime
        lastPublishedLivePartialWindowEndTime = result.windowEndTime
        lastPublishedLivePartialAt = now
        logLivePartialResultIfPresent(result, phase: phase)
        return result
    }

    private func hasTerminalPunctuation(_ text: String) -> Bool {
        guard let last = text.unicodeScalars.last else { return false }
        return CharacterSet(charactersIn: ".!?;:").contains(last)
    }

    private func resetLivePartialOutputState() {
        lastPublishedLivePartialText = ""
        lastPublishedLivePartialWindowStartTime = 0
        lastPublishedLivePartialWindowEndTime = 0
        lastPublishedLivePartialAt = .distantPast
    }

    private func isLiveStreamTextLanguageConsistent(_ text: String, expected: SupportedLanguage?) -> Bool {
        guard expected != nil else { return true }

        // Do not reject short/incremental live transcription.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return true }

        // Diagnostic-only guard: language consistency must not decide
        // engine routing without a true confidence API.
        return true
    }

    private func logPreview(_ text: String, max: Int = 120) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard trimmed.count > max else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: max)
        return String(trimmed[..<idx]) + "..."
    }

    private func debugTrace(_ message: String) {
        STTSessionLogger.shared.log(source: "SpeechToTextManager", message: message)
#if DEBUG
        print("[STT_TRACE][SpeechToTextManager] \(message)")
#endif
    }

    @objc
    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else {
            return
        }

        switch type {
        case .began:
            stopListening()
        case .ended:
            break
        @unknown default:
            break
        }
    }

}

@available(iOS 26.0, *)
final class AppleLiveTranscriptionCoordinator {
    enum EngineKind: String {
        case speechTranscriber
        case dictationTranscriber
    }

    struct EngineSelection {
        let engine: EngineKind
        let locale: Locale
        let reason: String
        let sessionID: UUID
    }

    private struct Entry {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
        var isFinal: Bool
    }

    private let stateLock = NSLock()
    private var entries: [Entry] = []
    private var latestFinalizationTime: TimeInterval = 0
    private var latestWindowEnd: TimeInterval = 0
    private var latestLocale: Locale = .current
    private enum LifecycleState: String {
        case idle
        case starting
        case running
        case stopping
        case failed
    }
    private let lifecycleLock = NSLock()
    private var lifecycleState: LifecycleState = .idle
    private var activeSessionID: UUID?

    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analyzer: SpeechAnalyzer?
    private var analyzeTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var analyzerInputFormat: AVAudioFormat?
    private let inputQueue = DispatchQueue(label: "AppleLiveTranscriptionCoordinator.inputQueue", qos: .userInitiated)
    private var hasLoggedFirstInputBuffer = false

    private var hasLoggedEngineSelection = false

    func start(localeHint: Locale?) async throws -> EngineSelection {
        let sessionID = UUID()
        let priorState = lifecycleLock.withLock { lifecycleState }
        if priorState == .running || priorState == .starting || priorState == .stopping {
            try await stop(finalize: false)
        }
        transitionLifecycle(to: .starting, sessionID: sessionID, detail: "phase=start_begin")
        resetTranscriptState()
        hasLoggedFirstInputBuffer = false

        let resolved = try await resolveEngine(localeHint: localeHint, sessionID: sessionID)
        let stream = AsyncStream<AnalyzerInput> { continuation in
            self.inputContinuation = continuation
        }

        do {
            switch resolved.engine {
            case .speechTranscriber:
                let preset = SpeechTranscriber.Preset(
                    transcriptionOptions: [],
                    reportingOptions: [.volatileResults, .fastResults],
                    attributeOptions: []
                )
                let transcriber = SpeechTranscriber(locale: resolved.locale, preset: preset)
                try await ensureAssetsReady(module: transcriber)

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let defaultFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                )
                let expectedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? defaultFormat
                guard let expectedFormat else {
                    throw NSError(
                        domain: "AppleLiveTranscriptionCoordinator",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to determine analyzer input format"]
                    )
                }
                analyzerInputFormat = expectedFormat
                try await analyzer.prepareToAnalyze(in: expectedFormat)
                self.analyzer = analyzer
                self.latestLocale = resolved.locale

                self.resultsTask = Task(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    do {
                        for try await result in transcriber.results {
                            guard self.isSessionActive(sessionID) else { return }
                            self.applyResult(
                                range: result.range,
                                resultsFinalizationTime: result.resultsFinalizationTime,
                                text: result.text,
                                isFinal: result.isFinal,
                                locale: resolved.locale
                            )
                        }
                    } catch {
                        if self.isSessionActive(sessionID) {
                        }
                    }
                }

                try await analyzer.start(inputSequence: stream)

            case .dictationTranscriber:
                let preset = DictationTranscriber.Preset.progressiveLongDictation
                let transcriber = DictationTranscriber(locale: resolved.locale, preset: preset)
                try await ensureAssetsReady(module: transcriber)

                let analyzer = SpeechAnalyzer(modules: [transcriber])
                let defaultFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 16_000,
                    channels: 1,
                    interleaved: false
                )
                let expectedFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) ?? defaultFormat
                guard let expectedFormat else {
                    throw NSError(
                        domain: "AppleLiveTranscriptionCoordinator",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to determine analyzer input format"]
                    )
                }
                analyzerInputFormat = expectedFormat
                try await analyzer.prepareToAnalyze(in: expectedFormat)
                self.analyzer = analyzer
                self.latestLocale = resolved.locale

                self.resultsTask = Task(priority: .userInitiated) { [weak self] in
                    guard let self else { return }
                    do {
                        for try await result in transcriber.results {
                            guard self.isSessionActive(sessionID) else { return }
                            self.applyResult(
                                range: result.range,
                                resultsFinalizationTime: result.resultsFinalizationTime,
                                text: result.text,
                                isFinal: result.isFinal,
                                locale: resolved.locale
                            )
                        }
                    } catch {
                        if self.isSessionActive(sessionID) {
                        }
                    }
                }

                try await analyzer.start(inputSequence: stream)
            }
        } catch {
            transitionLifecycle(to: .failed, sessionID: sessionID, detail: "phase=start_failed error=\"\(error.localizedDescription)\"")
            try? await stop(finalize: false)
            throw error
        }

        if !hasLoggedEngineSelection {
            hasLoggedEngineSelection = true
        }
        transitionLifecycle(to: .running, sessionID: sessionID, detail: "phase=running")

        return EngineSelection(
            engine: resolved.engine,
            locale: resolved.locale,
            reason: resolved.reason,
            sessionID: sessionID
        )
    }

    func pushBuffer(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        guard let continuation = inputContinuation else { return }
        guard let expectedFormat = analyzerInputFormat else { return }
        guard let sessionID = lifecycleLock.withLock({
            lifecycleState == .running ? activeSessionID : nil
        }) else { return }

        inputQueue.async { [weak self] in
            guard let self else { return }
            guard self.isSessionActive(sessionID) else { return }
            guard let inputBuffer = self.convertBufferIfNeeded(buffer, to: expectedFormat) else {
                return
            }
            let shouldLogFirstBuffer = !self.hasLoggedFirstInputBuffer
            if shouldLogFirstBuffer {
            }
            continuation.yield(AnalyzerInput(buffer: inputBuffer))
            if shouldLogFirstBuffer {
                self.hasLoggedFirstInputBuffer = true
            }
        }
    }

    func latestLivePartial(language: SpeechToTextManager.SupportedLanguage) -> SpeechToTextManager.LivePartialResult? {
        stateLock.lock()
        let sorted = entries.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.end < rhs.end }
            return lhs.start < rhs.start
        }

        let committed = sorted
            .filter { $0.isFinal }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let volatile = sorted
            .filter { !$0.isFinal }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let windowEnd = latestWindowEnd
        let windowStart = max(0, latestFinalizationTime)
        stateLock.unlock()

        let rendered = join(committed: committed, volatile: volatile)
        guard !rendered.isEmpty else { return nil }

        let segments = [
            LiveTranscriptSegment(startTime: 0, endTime: windowStart, text: committed),
            LiveTranscriptSegment(startTime: windowStart, endTime: windowEnd, text: volatile)
        ].filter { !$0.text.isEmpty && $0.endTime >= $0.startTime }

        return SpeechToTextManager.LivePartialResult(
            text: rendered,
            language: language,
            windowStartTime: windowStart,
            windowEndTime: windowEnd,
            segments: segments,
            committedText: committed,
            volatileText: volatile
        )
    }

    func stop(finalize: Bool) async throws {
        guard let sessionID = lifecycleLock.withLock({ activeSessionID }) else {
            return
        }
        transitionLifecycle(to: .stopping, sessionID: sessionID, detail: "phase=stop_begin finalize=\(finalize)")
        inputContinuation?.finish()
        inputContinuation = nil

        if finalize, let analyzer {
            do {
                try await analyzer.finalizeAndFinishThroughEndOfInput()
            } catch {
            }
        }

        if !finalize {
            await analyzer?.cancelAndFinishNow()
        }

        analyzeTask?.cancel()
        resultsTask?.cancel()
        analyzeTask = nil
        resultsTask = nil
        self.analyzer = nil
        analyzerInputFormat = nil
        lifecycleLock.withLock {
            activeSessionID = nil
        }
        hasLoggedEngineSelection = false
        transitionLifecycle(to: .idle, sessionID: sessionID, detail: "phase=stopped")
    }

    private func resolveEngine(localeHint: Locale?, sessionID: UUID) async throws -> EngineSelection {
        let preferred = localeHint ?? Locale.current

        // Live path must prefer DictationTranscriber to match Apple's live dictation behavior.
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferred) {
            return EngineSelection(
                engine: .dictationTranscriber,
                locale: locale,
                reason: "Preferred live path: DictationTranscriber.supportedLocale(equivalentTo:)",
                sessionID: sessionID
            )
        }

        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: preferred) {
            return EngineSelection(
                engine: .speechTranscriber,
                locale: locale,
                reason: "DictationTranscriber unsupported; fallback SpeechTranscriber.supportedLocale(equivalentTo:)",
                sessionID: sessionID
            )
        }

        throw NSError(
            domain: "AppleLiveTranscriptionCoordinator",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "No supported locale equivalent to \(preferred.identifier)"]
        )
    }

    private func ensureAssetsReady(module: some LocaleDependentSpeechModule) async throws {
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await installationRequest.downloadAndInstall()
        }
    }

    private func applyResult(
        range: CMTimeRange,
        resultsFinalizationTime: CMTime,
        text: AttributedString,
        isFinal: Bool,
        locale: Locale
    ) {
        let start = max(0, seconds(range.start))
        let end = max(start, seconds(range.end))
        let finalization = max(0, seconds(resultsFinalizationTime))
        let normalizedText = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)

        stateLock.lock()
        latestLocale = locale
        latestFinalizationTime = max(latestFinalizationTime, finalization)
        latestWindowEnd = max(latestWindowEnd, end)

        entries.removeAll { existing in
            let overlaps = existing.start < end && start < existing.end
            if !overlaps { return false }
            return !existing.isFinal || existing.end > finalization
        }

        if !normalizedText.isEmpty {
            entries.append(
                Entry(
                    start: start,
                    end: end,
                    text: normalizedText,
                    isFinal: isFinal || finalization >= end - 0.0001
                )
            )
        }

        entries = entries.map { entry in
            var updated = entry
            if updated.end <= finalization + 0.0001 {
                updated.isFinal = true
            }
            return updated
        }
        stateLock.unlock()
    }

    private func seconds(_ time: CMTime) -> TimeInterval {
        guard time.isNumeric else { return 0 }
        return CMTimeGetSeconds(time)
    }

    private func join(committed: String, volatile: String) -> String {
        let prefix = committed.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return tail }
        guard !tail.isEmpty else { return prefix }
        return prefix + " " + tail
    }

    private func resetTranscriptState() {
        stateLock.lock()
        entries.removeAll()
        latestFinalizationTime = 0
        latestWindowEnd = 0
        stateLock.unlock()
    }

    private func convertBufferIfNeeded(_ buffer: AVAudioPCMBuffer, to expectedFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if isAudioFormat(buffer.format, equivalentTo: expectedFormat) {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: expectedFormat) else {
            return nil
        }
        let ratio = expectedFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: expectedFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var conversionError: NSError?
        var didSupplyInput = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, status in
            if didSupplyInput {
                status.pointee = .endOfStream
                return nil
            }
            didSupplyInput = true
            status.pointee = .haveData
            return buffer
        }

        guard conversionError == nil, outputBuffer.frameLength > 0 else {
            return nil
        }
        return outputBuffer
    }

    private func isAudioFormat(_ lhs: AVAudioFormat, equivalentTo rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
            && abs(lhs.sampleRate - rhs.sampleRate) < 0.5
    }

    private func transitionLifecycle(to next: LifecycleState, sessionID: UUID, detail: String) {
        lifecycleLock.lock()
        lifecycleState = next
        activeSessionID = (next == .idle) ? nil : sessionID
        lifecycleLock.unlock()
    }

    private func isSessionActive(_ sessionID: UUID) -> Bool {
        lifecycleLock.withLock {
            activeSessionID == sessionID && (lifecycleState == .starting || lifecycleState == .running)
        }
    }

}
