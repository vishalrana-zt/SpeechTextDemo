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
        case speechTranscriber
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
    private let advancedLiveStreamStartupGraceSecondsFrenchBoost: TimeInterval = 1.2
    private let advancedLiveStreamNoResultDisableThresholdFrenchBoost: Int = 4
    private let advancedLiveStreamNoResultMinimumLiveSecondsFrenchBoost: TimeInterval = 2.0
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
    private var advancedDictationTranscriberCapable = false
    private var advancedSpeechTranscriberCapable = false
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
    private let streamingSpeechRecognizerLock = NSLock()
    private var streamingSpeechRecognizerSession: StreamingSpeechRecognizerSession?
    private var streamingSpeechRecognizerSessionID: UUID?
    private var sttSessionStartedAt: Date?
    private var sttLivePartialSequence: Int = 0
    private var sttPrimaryEngineForSession: TranscriptionEngine?
    private var sttFinalEngineForSession: TranscriptionEngine?
    private var sttFallbackOccurred = false
    private var sttFallbackReason: String?
    private var sttDidLogRecordingStop = false
    private var sttDidLogFirstPartialLatency = false
    private var sttLastPartialLoggedAt: Date?
    private var sttLastStreamUnavailableFallbackLogAt: Date?
    private var sttLastStreamUnavailableFallbackKey: String?
    private var sttDidLogStartupFallbackWarning = false
    private var sttLiveFallbackUsed = false
    private var sttLiveFallbackReason: String?
    private var sttStreamingRetryAttempted = false
    private var sttAppleLiveTapBufferCount: Int = 0
    private var sttAppleLiveTapSampleCount: Int = 0
    private var sttAppleLiveTapFirstBufferAt: Date?
    private var sttAppleLiveTapLastBufferAt: Date?
    private var sttAppleLiveTapLastLogAt: Date?
    private let sttAppleLiveTapLogInterval: TimeInterval = 1.0

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
    
    private var isDeviceEligibleForAdvancedAppleSpeech: Bool {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafeMutablePointer(to: &systemInfo.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        // Exclude devices with A13 Bionic or older (e.g. iPad 9th Gen = iPad12,1 / iPad12,2)
        // from the on-device SpeechAnalyzer/DictationTranscriber path.
        let excludedPrefixes = ["iPad11,", "iPad12,", "iPad7,", "iPhone11,", "iPhone10,", "iPhone9,", "iPhone8,"]
        return !excludedPrefixes.contains { identifier.hasPrefix($0) }
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
        guard !hasDisabledAdvancedLiveStreamForSession else {
            logAppleGateFailure("live_stream_disabled_for_session")
            return false
        }
        // Keep legacy disable gate for analyzer-based fallback only.
        guard !hasDisabledSpeechAnalyzerForSession else {
            logAppleGateFailure("disabled_for_session")
            return false
        }
        guard !isAppleAdvancedPathQuarantined() else {
            logAppleGateFailure("quarantined")
            return false
        }
        appleCapabilityLock.lock()
        let enabled = advancedDictationTranscriberCapable
        appleCapabilityLock.unlock()
        if !enabled {
            logAppleGateFailure("dictation_runtime_capability_check")
        }
        return enabled
    }

    private func logAppleGateFailure(_ reason: String) {
        // Suppress non-session gate noise during UI-only state changes.
        guard activeCaptureSessionID != nil else { return }
        let key = "\(operationMode.rawValue):\(reason)"
        guard !loggedAppleGateFailures.contains(key) else { return }
        loggedAppleGateFailures.insert(key)
        debugTrace("apple_gate fail=\(reason)")
    }

    private func setAdvancedAppleTranscriberCapability(dictation: Bool, speech: Bool, checked: Bool) {
        appleCapabilityLock.lock()
        advancedDictationTranscriberCapable = dictation
        advancedSpeechTranscriberCapable = speech
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
        // One-time drain of any locale reservations left over from before the
        // reserve/release fix (or any other stale reservation), so each fresh
        // app run starts at 0/5 instead of inheriting an already-exhausted quota.
        if #available(iOS 26.0, *) {
            Task(priority: .utility) {
                for locale in await AssetInventory.reservedLocales {
                    await AssetInventory.release(reservedLocale: locale)
                }
            }
        }
    #if DEBUG
        // Enable advanced Apple path testing by default on debug builds only.
        if defaults.object(forKey: Self.appleAdvancedExplicitOptInKey) == nil {
            defaults.set(true, forKey: Self.appleAdvancedExplicitOptInKey)
        }

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
        setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: false)
        Task(priority: .utility) { [weak self] in
            await self?.refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: true)
        }
    }

    private func refreshAdvancedAppleTranscriberCapabilityIfNeeded(force: Bool) async {
        guard selectedModelProvider == .appleModels else {
            setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: false)
            disarmAppleAdvancedPath()
            return
        }
        guard !isAppleAdvancedPathQuarantined() else {
            setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: true)
            publishBackendStatus()
            return
        }
        guard #available(iOS 26.0, *) else {
            setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: true)
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

        let dictationCapable = dictationSupportedLocale != nil
        let speechCapable = speechSupportedLocale != nil
        let enabled = (dictationCapable || speechCapable) && isAdvancedApplePathExplicitlyEnabled
        debugTrace(
            "apple_runtime_capability preferred=\(preferredLocale.identifier) dictation=\(dictationCapable) speech=\(speechCapable) enabled=\(enabled)"
        )
        setAdvancedAppleTranscriberCapability(dictation: dictationCapable, speech: speechCapable, checked: true)
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
        clearStreamingSpeechRecognizerSession(cancel: true)
        liveCaptureStartedAt = nil
        activeCaptureSessionID = nil
        lastSessionTranscribeCache = nil
        setAdvancedAppleTranscriberCapability(dictation: false, speech: false, checked: false)
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
        clearStreamingSpeechRecognizerSession(cancel: true)
        liveCaptureStartedAt = nil
        activeCaptureSessionID = nil
        lastSessionTranscribeCache = nil
        sessionPreferredLanguageHint = nil
        modelState = modelState(for: mode)
        publishBackendStatus()
        debugLogRuntimeConfiguration(reason: "operation_mode_changed")
    }

    func resetSessionStateForLanguageChange(_ language: SupportedLanguage) {
        cancelSpeechAnalyzerValidationTaskIfNeeded()
        hasDisabledSpeechAnalyzerForSession = false
        hasDisabledAdvancedLiveStreamForSession = false
        hasValidatedSpeechAnalyzerForSession = false
        loggedAppleGateFailures.removeAll()
        advancedLiveStreamNoResultStreak = 0
        setFinalizingTranscript(false)
        setAppleLiveFinalText(nil)
        resetLivePartialOutputState()
        liveCaptureStartedAt = nil
        activeCaptureSessionID = nil
        lastSessionTranscribeCache = nil
        sessionPreferredLanguageHint = language
        liveLockedLanguage = language
        pendingLiveLockLanguage = nil
        pendingLiveLockConfirmations = 0
        lastLiveResolvedLanguage = nil
        clearStreamingSpeechRecognizerSession(cancel: true)

        appleLiveStateLock.lock()
        lastNonEmptyLiveTranscriptText = nil
        appleLiveStateLock.unlock()

        Task(priority: .utility) { [liveDecodeCoordinator] in
            await liveDecodeCoordinator.reset()
        }

        publishBackendStatus()
        debugTrace("runtime reason=language_changed language=\(language.rawValue)")
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
        clearStreamingSpeechRecognizerSession(cancel: true)
        Task(priority: .utility) { [liveDecodeCoordinator] in
            await liveDecodeCoordinator.reset()
        }

        sttSessionStartedAt = Date()
        sttLivePartialSequence = 0
        sttPrimaryEngineForSession = nil
        sttFinalEngineForSession = nil
        sttFallbackOccurred = false
        sttFallbackReason = nil
        sttDidLogRecordingStop = false
        sttDidLogFirstPartialLatency = false
        sttLastPartialLoggedAt = nil
        sttLastStreamUnavailableFallbackLogAt = nil
        sttLastStreamUnavailableFallbackKey = nil
        sttDidLogStartupFallbackWarning = false
        sttLiveFallbackUsed = false
        sttLiveFallbackReason = nil
        sttStreamingRetryAttempted = false
        sttAppleLiveTapBufferCount = 0
        sttAppleLiveTapSampleCount = 0
        sttAppleLiveTapFirstBufferAt = nil
        sttAppleLiveTapLastBufferAt = nil
        sttAppleLiveTapLastLogAt = nil
        let requested = preferredLanguage ?? preferredDeviceSupportedLanguage() ?? .english
        let resolvedLocale = speechAnalyzerLocaleHint(for: requested)?.identifier ?? "auto"
        sessionLog(
            "session_start",
            fields: [
                "mode": operationMode.rawValue,
                "requested_language": requested.rawValue,
                "resolved_locale": resolvedLocale,
                "ios": ProcessInfo.processInfo.operatingSystemVersionString,
                "provider": selectedModelProvider.rawValue,
                "platform": currentPlatformLabel()
            ]
        )
        sessionLog("recording_start", fields: ["mode": operationMode.rawValue])

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
                self.logAppleLiveTapInput(buffer: outBuffer)
                self.pushAudioBufferToAppleLiveSessionIfNeeded(outBuffer)
            }
            self.pushAudioBufferToStreamingSpeechRecognizerSessionIfNeeded(outBuffer)

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
        if shouldUseStreamingSpeechRecognizerForLive() {
            Task(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                do {
                    try await self.ensureStreamingSpeechRecognizerSessionIfNeeded(preferredLanguage: preferredLanguage)
                } catch {
                    self.debugTrace("streaming_speech_recognizer start_failed reason=\(error.localizedDescription)")
                }
            }
        }
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
        finishStreamingSpeechRecognizerInputIfNeeded()
        finalizePostRecordingAudioFileIfNeeded()
        try? AVAudioSession.sharedInstance().setActive(false)
        isListening = false

        if let sessionID = activeCaptureSessionID, !sttDidLogRecordingStop {
            let recordingDuration = liveCaptureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            sessionLog(
                "recording_stop",
                sessionID: sessionID,
                fields: [
                    "mode": operationMode.rawValue,
                    "duration_s": String(format: "%.2f", recordingDuration)
                ]
            )
            sttDidLogRecordingStop = true
        }

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

    private func shouldUseStreamingSpeechRecognizerForLive() -> Bool {
        operationMode == .liveStreaming && preferredLivePartialEngine() == .speechRecognizer
    }

    private func clearStreamingSpeechRecognizerSession(cancel: Bool) {
        streamingSpeechRecognizerLock.lock()
        let session = streamingSpeechRecognizerSession
        let sessionID = streamingSpeechRecognizerSessionID
        streamingSpeechRecognizerSession = nil
        streamingSpeechRecognizerSessionID = nil
        streamingSpeechRecognizerLock.unlock()

        guard session != nil else { return }
        sessionLog(
            "streaming_session_release",
            sessionID: sessionID,
            fields: ["cancel": cancel ? "true" : "false"]
        )
        if cancel {
            session?.cancel()
            sessionLog("recognition_task_cancelled", sessionID: sessionID, fields: ["engine": "StreamingSpeechRecognizerSession"])
        }
    }

    private func finishStreamingSpeechRecognizerInputIfNeeded() {
        streamingSpeechRecognizerLock.lock()
        let session = streamingSpeechRecognizerSession
        streamingSpeechRecognizerLock.unlock()
        session?.finishInput()
    }

    private func pushAudioBufferToStreamingSpeechRecognizerSessionIfNeeded(_ buffer: AVAudioPCMBuffer) {
        guard operationMode == .liveStreaming else { return }
        let (session, sessionID, activeID) = streamingSpeechRecognizerLock.withLock {
            (streamingSpeechRecognizerSession, streamingSpeechRecognizerSessionID, activeCaptureSessionID)
        }

        guard sessionID == activeID else { return }
        guard session?.isRunning() == true else { return }
        session?.append(buffer)
    }

    private func ensureStreamingSpeechRecognizerSessionIfNeeded(preferredLanguage: SupportedLanguage?) async throws {
        guard operationMode == .liveStreaming else { return }
        guard let sessionID = activeCaptureSessionID else { return }

        let (currentSession, currentSessionID) = streamingSpeechRecognizerLock.withLock {
            (streamingSpeechRecognizerSession, streamingSpeechRecognizerSessionID)
        }

        if currentSessionID == sessionID, currentSession?.isRunning() == true {
            return
        }

        if currentSessionID != sessionID {
            clearStreamingSpeechRecognizerSession(cancel: true)
        }

        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        let locale = resolveSupportedSpeechRecognizerLocale(for: languageHint, localeHint: localeHint) ?? localeHint ?? Locale(identifier: languageHint.rawValue)

        let session = StreamingSpeechRecognizerSession(locale: locale)
        debugTrace("streaming_speech_recognizer start session=\(sessionID.uuidString) locale=\(locale.identifier)")
        sessionLog(
            "engine_start",
            sessionID: sessionID,
            fields: [
                "engine": "StreamingSpeechRecognizerSession",
                "mode": operationMode.rawValue,
                "locale": locale.identifier
            ]
        )

        try await session.start(
            onResult: { [weak self] result in
                guard let self else { return }
                guard self.activeCaptureSessionID == sessionID else { return }
                self.rememberLiveTranscriptTextIfNonEmpty(result.text)
            },
            onError: { [weak self] error in
                guard let self else { return }
                guard self.activeCaptureSessionID == sessionID else { return }
                let nsError = error as NSError
                let retryable = self.isRetryableStreamingSpeechRecognizerError(error)
                self.debugTrace("streaming_speech_recognizer callback_error session=\(sessionID.uuidString) reason=\(error.localizedDescription)")
                self.sessionLog(
                    "engine_error",
                    sessionID: sessionID,
                    fields: [
                        "engine": "StreamingSpeechRecognizerSession",
                        "reason": error.localizedDescription,
                        "domain": nsError.domain,
                        "code": "\(nsError.code)",
                        "retryable": retryable ? "true" : "false"
                    ]
                )
                guard retryable, !self.sttStreamingRetryAttempted else { return }
                self.sttStreamingRetryAttempted = true
                self.markLiveFallbackUsed(reason: "streaming_retry_203")
                self.sessionLog(
                    "retry_start",
                    sessionID: sessionID,
                    fields: [
                        "engine": "StreamingSpeechRecognizerSession",
                        "attempt": "2",
                        "max_attempts": "2",
                        "reason": "kAFAssistantErrorDomain_203"
                    ]
                )
                self.debugTrace("streaming_speech_recognizer controlled_restart reason=kAFAssistantErrorDomain_203")
                self.clearStreamingSpeechRecognizerSession(cancel: true)
            }
        )

        streamingSpeechRecognizerLock.withLock {
            if activeCaptureSessionID == sessionID {
                streamingSpeechRecognizerSession = session
                streamingSpeechRecognizerSessionID = sessionID
            }
        }
    }

    private func finalizeStreamingSpeechRecognizerSessionIfNeeded(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage)? {
        guard operationMode == .liveStreaming else { return nil }

        let (session, sessionID, activeID) = streamingSpeechRecognizerLock.withLock {
            (streamingSpeechRecognizerSession, streamingSpeechRecognizerSessionID, activeCaptureSessionID)
        }

        guard let session, sessionID == activeID else { return nil }

        defer {
            clearStreamingSpeechRecognizerSession(cancel: true)
        }

        do {
            let finalText = try await session.finishAndAwaitFinal(timeoutInterval: 8.0)
            let normalized = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
                let language = supportedLanguage(from: session.locale, fallback: languageHint)
                rememberLiveTranscriptTextIfNonEmpty(normalized)
                sessionLog(
                    "engine_success",
                    sessionID: sessionID,
                    fields: [
                        "engine": "StreamingSpeechRecognizerSession",
                        "chars": "\(normalized.count)",
                        "language": language.rawValue
                    ]
                )
                return (normalized, language)
            }
            sessionLog("engine_empty", sessionID: sessionID, fields: ["engine": "StreamingSpeechRecognizerSession"])
        } catch {
            if let fallbackText = nonEmptyStreamingFallbackText(from: session) {
                let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
                let language = supportedLanguage(from: session.locale, fallback: languageHint)
                debugTrace("streaming_speech_recognizer final_fallback_last_partial reason=\(error.localizedDescription)")
                sessionLog(
                    "fallback_start",
                    sessionID: sessionID,
                    fields: [
                        "from": "StreamingSpeechRecognizerSession",
                        "to": "StreamingSpeechRecognizerSession.last_non_empty_partial",
                        "reason": error.localizedDescription
                    ]
                )
                return (fallbackText, language)
            }
            sessionLog(
                "engine_error",
                sessionID: sessionID,
                fields: [
                    "engine": "StreamingSpeechRecognizerSession",
                    "reason": error.localizedDescription
                ]
            )
            throw error
        }

        if let fallbackText = nonEmptyStreamingFallbackText(from: session) {
            let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
            let language = supportedLanguage(from: session.locale, fallback: languageHint)
            debugTrace("streaming_speech_recognizer final_empty_use_last_partial")
            sessionLog(
                "fallback_start",
                sessionID: sessionID,
                fields: [
                    "from": "StreamingSpeechRecognizerSession",
                    "to": "StreamingSpeechRecognizerSession.last_non_empty_partial",
                    "reason": "empty_final"
                ]
            )
            return (fallbackText, language)
        }

        return nil
    }

    private func nonEmptyStreamingFallbackText(from session: StreamingSpeechRecognizerSession) -> String? {
        let latest = session.latestTextSnapshot().trimmingCharacters(in: .whitespacesAndNewlines)
        if !latest.isEmpty { return latest }

        let lastNonEmpty = session.lastNonEmptyTextSnapshot().trimmingCharacters(in: .whitespacesAndNewlines)
        if !lastNonEmpty.isEmpty { return lastNonEmpty }

        let managerLast = getLastNonEmptyLiveTranscriptText()?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !managerLast.isEmpty { return managerLast }

        return nil
    }

    private func resolveSupportedSpeechRecognizerLocale(for language: SupportedLanguage, localeHint: Locale?) -> Locale? {
        let supported = SFSpeechRecognizer.supportedLocales()
        let supportedByIdentifier = Dictionary(
            supported.map { ($0.identifier.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return SpeechLocaleResolution.resolve(
            localeHint: localeHint,
            supportedByIdentifier: supportedByIdentifier,
            allSupported: Array(supported)
        )
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
            sessionLog(
                "apple_live_session_start",
                fields: [
                    "mode": operationMode.rawValue,
                    "language": language.rawValue,
                    "resolved_locale": localeHint?.identifier ?? "auto",
                    "engine": "dictationTranscriber",
                    "phase": "attempt",
                    "ios": ProcessInfo.processInfo.operatingSystemVersionString,
                    "elapsed_ms": "\(sttSessionStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0)"
                ]
            )
            _ = try await coordinator.start(localeHint: localeHint, ownerSessionID: activeCaptureSessionID)
            sessionLog(
                "apple_live_session_start",
                fields: [
                    "mode": operationMode.rawValue,
                    "language": language.rawValue,
                    "resolved_locale": localeHint?.identifier ?? "auto",
                    "engine": "dictationTranscriber",
                    "phase": "running",
                    "elapsed_ms": "\(sttSessionStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0)"
                ]
            )
            appleLiveCoordinator = coordinator
        } catch {
            disarmAppleAdvancedPath()
            hasDisabledAdvancedLiveStreamForSession = true
            let nsError = error as NSError
            sessionLog(
                "apple_live_error",
                fields: [
                    "mode": operationMode.rawValue,
                    "phase": "session_start",
                    "domain": nsError.domain,
                    "code": "\(nsError.code)",
                    "reason": error.localizedDescription,
                    "elapsed_ms": "\(sttSessionStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? 0)"
                ]
            )
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
        let requestedLanguage = preferredLanguage ?? effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        sessionLog(
            "transcription_start",
            fields: [
                "mode": transcribeModeSnapshot.rawValue,
                "requested_language": requestedLanguage.rawValue,
                "resolved_locale": (speechAnalyzerLocaleHint(for: requestedLanguage)?.identifier ?? "auto")
            ]
        )
        defer {
            sessionLog("cleanup_start", fields: ["mode": operationMode.rawValue])
            if operationMode == .postRecording {
                cleanupPostRecordingAudioFileIfNeeded()
            }
            sessionLog("cleanup_complete", fields: ["mode": operationMode.rawValue])
        }
        if #available(iOS 26.0, *),
           appleLiveCoordinator != nil {
            await finalizeAppleLiveSessionIfNeeded()
        }
        debugLogRuntimeConfiguration(reason: "final_transcribe", modeOverride: transcribeModeSnapshot)
        let finalRoute = resolvedFinalTranscriptionRoute()
        let preferredEngine = finalRoute.engine
        sttPrimaryEngineForSession = preferredEngine
        sessionLog(
            "engine_selected",
            fields: [
                "mode": transcribeModeSnapshot.rawValue,
                "engine": engineDisplayName(preferredEngine),
                "platform": currentPlatformLabel()
            ]
        )
        debugLogEngineSelection(
            phase: "final_transcribe",
            engine: preferredEngine,
            detail: "mode=\(transcribeModeSnapshot.rawValue) preferredLanguage=\(preferredLanguage?.rawValue ?? "auto") route=\(finalRoute.rawValue) analyzer_gate=\(speechAnalyzerGateReason)"
        )
        let finalResult: (text: String, language: SupportedLanguage)
        do {
            switch finalRoute {
            case .ios26LiveDictation:
                finalResult = try await transcribeFinalWithDictationTranscriber(preferredLanguage: preferredLanguage)
            case .ios26PostSpeechTranscriber:
                finalResult = try await transcribeFinalWithSpeechTranscriber(preferredLanguage: preferredLanguage)
            case .legacySpeechRecognizer:
                finalResult = try await transcribeFinalWithSpeechRecognizer(preferredLanguage: preferredLanguage)
            }
        } catch {
            let finalEngine = sttFinalEngineForSession ?? preferredEngine
            let totalDuration = sttSessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            sessionLog(
                "transcription_complete",
                fields: [
                    "mode": transcribeModeSnapshot.rawValue,
                    "requested_language": requestedLanguage.rawValue,
                    "primary_engine": engineDisplayName(preferredEngine),
                    "final_engine": engineDisplayName(finalEngine),
                    "result": "failure",
                    "chars": "0",
                    "fallback": sttFallbackOccurred ? "true" : "false",
                    "fallback_reason": sttFallbackReason ?? "",
                    "live_fallback_used": sttLiveFallbackUsed ? "true" : "false",
                    "live_fallback_reason": sttLiveFallbackReason ?? "",
                    "duration_s": String(format: "%.2f", totalDuration),
                    "error": error.localizedDescription
                ]
            )
            sessionLog(
                "session_end",
                fields: [
                    "result": "failure",
                    "total_duration_s": String(format: "%.2f", totalDuration)
                ]
            )
            throw error
        }
        debugTrace("transcribe end mode=\(transcribeModeSnapshot.rawValue) lang=\(finalResult.language.rawValue) chars=\(finalResult.text.count)")
        let finalEngine = sttFinalEngineForSession ?? preferredEngine
        let totalDuration = sttSessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        sessionLog(
            "transcription_complete",
            fields: [
                "mode": transcribeModeSnapshot.rawValue,
                "requested_language": requestedLanguage.rawValue,
                "resolved_locale": (speechAnalyzerLocaleHint(for: finalResult.language)?.identifier ?? "auto"),
                "primary_engine": engineDisplayName(preferredEngine),
                "final_engine": engineDisplayName(finalEngine),
                "result": finalResult.text.isEmpty ? "empty" : "success",
                "chars": "\(finalResult.text.count)",
                "fallback": sttFallbackOccurred ? "true" : "false",
                "fallback_reason": sttFallbackReason ?? "",
                "live_fallback_used": sttLiveFallbackUsed ? "true" : "false",
                "live_fallback_reason": sttLiveFallbackReason ?? "",
                "duration_s": String(format: "%.2f", totalDuration)
            ]
        )
        sessionLog(
            "session_end",
            fields: [
                "result": finalResult.text.isEmpty ? "empty" : "success",
                "total_duration_s": String(format: "%.2f", totalDuration)
            ]
        )
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
                let isFrenchSession = isFrenchLiveSession(preferredLanguage: preferredLanguage)
                let startupGraceSeconds = advancedLiveStreamStartupGraceSeconds + (isFrenchSession ? advancedLiveStreamStartupGraceSecondsFrenchBoost : 0)
                let noResultDisableThreshold = advancedLiveStreamNoResultDisableThreshold + (isFrenchSession ? advancedLiveStreamNoResultDisableThresholdFrenchBoost : 0)
                let noResultMinimumLiveSeconds = advancedLiveStreamNoResultMinimumLiveSeconds + (isFrenchSession ? advancedLiveStreamNoResultMinimumLiveSecondsFrenchBoost : 0)
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
                    let liveElapsed = liveCaptureStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                    if liveElapsed < startupGraceSeconds {
                        // Dictation stream frequently needs a short warm-up; avoid noisy
                        // early fallback churn before first stream hypotheses arrive.
                        return nil
                    }
                    let liveSnapshot = appleLiveCoordinator?.diagnosticsSnapshot()
                    let shouldIncrementNoResultStreak =
                        (liveSnapshot?.state == "running") &&
                        (liveSnapshot?.hasReceivedBuffer == true)
                    if shouldIncrementNoResultStreak {
                        advancedLiveStreamNoResultStreak += 1
                    }
                    logAppleLiveNoResultDiagnostics(snapshot: liveSnapshot, liveElapsed: liveElapsed)
                    logStartupFallbackWarningOnce(
                        key: "windowed_partial:no_stream_result",
                        message: "live_partial stream_unavailable fallback=windowed_partial reason=no_stream_result"
                    )
                    if advancedLiveStreamNoResultStreak >= noResultDisableThreshold,
                       liveElapsed >= noResultMinimumLiveSeconds,
                       !hasDisabledAdvancedLiveStreamForSession {
                        hasDisabledAdvancedLiveStreamForSession = true
                        debugTrace(
                            "live_stream disabled_for_session reason=no_stream_result_streak count=\(advancedLiveStreamNoResultStreak) live_s=\(String(format: "%.2f", liveElapsed))"
                        )
                    }
                }
            }
            if operationMode == .liveStreaming {
                logStartupFallbackWarningOnce(
                    key: "streaming_speech_recognizer",
                    message: "live_partial stream_unavailable fallback=streaming_speech_recognizer"
                )
            } else if canUseSpeechAnalyzer {
                logStartupFallbackWarningOnce(
                    key: "windowed_speech_analyzer",
                    message: "live_partial stream_unavailable fallback=windowed_speech_analyzer"
                )
            }
        }

        switch preferredEngine {
        case .speechTranscriber:
            do {
                let transcriberResult = try await transcribePartialCurrentBufferWithSpeechAnalyzer(
                    preferredLanguage: preferredLanguage,
                    maxAudioSeconds: maxAudioSeconds,
                    minimumAudioSeconds: minimumAudioSeconds
                )
                return publishLivePartialResultIfMeaningful(transcriberResult, phase: "speech_transcriber_partial")
            } catch {
                if shouldDisableSpeechAnalyzer(for: error) {
                    hasDisabledSpeechAnalyzerForSession = true
                    publishBackendStatus()
                    debugTrace("speech_transcriber_partial disable_for_session reason=\(error.localizedDescription)")
                    sessionLog(
                        "fallback_start",
                        fields: [
                            "from": engineDisplayName(.speechTranscriber),
                            "to": engineDisplayName(.speechRecognizer),
                            "reason": error.localizedDescription,
                            "mode": operationMode.rawValue
                        ]
                    )
                    let result = try await transcribePartialCurrentBufferWithSpeechRecognizer(
                        preferredLanguage: preferredLanguage,
                        maxAudioSeconds: maxAudioSeconds,
                        minimumAudioSeconds: minimumAudioSeconds
                    )
                    return publishLivePartialResultIfMeaningful(result, phase: "speech_recognizer_partial_fallback")
                }
                debugTrace("speech_transcriber_partial transient_error fallback=speech_recognizer reason=\(error.localizedDescription)")
                sessionLog(
                    "fallback_start",
                    fields: [
                        "from": engineDisplayName(.speechTranscriber),
                        "to": engineDisplayName(.speechRecognizer),
                        "reason": error.localizedDescription,
                        "mode": operationMode.rawValue
                    ]
                )
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
            if operationMode == .liveStreaming {
                markLiveFallbackUsed(reason: "speech_recognizer_live_fallback")
            }
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
        sessionLog(
            "file_opened",
            fields: [
                "mode": operationMode.rawValue,
                "source": "post_recording_file",
                "path": fileURL.lastPathComponent,
                "sample_rate": "\(Int(format.sampleRate))",
                "channels": "\(format.channelCount)"
            ]
        )
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
        sessionLog(
            "file_finalize",
            fields: [
                "mode": operationMode.rawValue,
                "source": "post_recording_file",
                "path": fileURL.lastPathComponent
            ]
        )
        do {
            _ = try AVAudioFile(forReading: fileURL)
            sessionLog(
                "file_validation",
                fields: [
                    "mode": operationMode.rawValue,
                    "source": "post_recording_file",
                    "path": fileURL.lastPathComponent,
                    "readable": "true"
                ]
            )
        } catch {
            sessionLog(
                "file_validation",
                fields: [
                    "mode": operationMode.rawValue,
                    "source": "post_recording_file",
                    "path": fileURL.lastPathComponent,
                    "readable": "false",
                    "reason": error.localizedDescription
                ]
            )
        }
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
                let duration = Double(postAudio.count) / targetSampleRate
                let fileSizeBytes: Int64 = postRecordingFileLock.withLock {
                    guard let fileURL = postRecordingAudioFileURL else { return 0 }
                    let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
                    return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                }
                debugTrace("final_audio source=post_recording_file samples=\(postAudio.count) audio_s=\(String(format: "%.2f", duration))")
                sessionLog(
                    "input_ready",
                    fields: [
                        "source": "post_recording_file",
                        "duration_s": String(format: "%.2f", duration),
                        "sample_rate": "\(Int(targetSampleRate))",
                        "channels": "1",
                        "samples": "\(postAudio.count)",
                        "file_size_bytes": "\(fileSizeBytes)"
                    ]
                )
                return postAudio
            }
        }
        let audio = snapshotAudioBuffer()
        guard !audio.isEmpty else { throw STTError.emptyRecording }
        let duration = Double(audio.count) / targetSampleRate
        debugTrace("final_audio source=live_buffer samples=\(audio.count) audio_s=\(String(format: "%.2f", duration))")
        sessionLog(
            "input_ready",
            fields: [
                "source": "live_audio_buffer",
                "duration_s": String(format: "%.2f", duration),
                "sample_rate": "\(Int(targetSampleRate))",
                "channels": "1",
                "samples": "\(audio.count)"
            ]
        )
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
                sessionLog(
                    "audio_file_cleanup",
                    fields: [
                        "mode": operationMode.rawValue,
                        "path": fileURL.lastPathComponent,
                        "success": "true"
                    ]
                )
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

    private enum FinalTranscriptionRoute: String {
        case ios26LiveDictation
        case ios26PostSpeechTranscriber
        case legacySpeechRecognizer

        var engine: TranscriptionEngine {
            switch self {
            case .ios26LiveDictation:
                return .dictationTranscriber
            case .ios26PostSpeechTranscriber:
                return .speechTranscriber
            case .legacySpeechRecognizer:
                return .speechRecognizer
            }
        }
    }

    private func resolvedFinalTranscriptionRoute() -> FinalTranscriptionRoute {
        guard #available(iOS 26.0, *) else { return .legacySpeechRecognizer }
        switch operationMode {
        case .liveStreaming:
            return .ios26LiveDictation
        case .postRecording:
            return .ios26PostSpeechTranscriber
        }
    }
    
    private func preferredLivePartialEngine() -> TranscriptionEngine {
        if #available(iOS 26.0, *) {
            if operationMode == .liveStreaming {
                return useAdvancedAppleLiveTranscribers ? .dictationTranscriber : .speechRecognizer
            }
            return canUseSpeechAnalyzer ? .speechTranscriber : .speechRecognizer
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
        if !isDeviceEligibleForAdvancedAppleSpeech { return "device_hardware_ineligible_soft" }
        return "available"
    }

    private func isUsableTranscript(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func transcribeFinalWithDictationTranscriber(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        let startedAt = Date()
        sessionLog("engine_start", fields: ["engine": engineDisplayName(.dictationTranscriber), "mode": operationMode.rawValue])
        do {
            let dictationResult = try await transcribeWithDictationTranscriber(preferredLanguage: preferredLanguage)
            if isUsableTranscript(dictationResult.text) {
                sttFinalEngineForSession = .dictationTranscriber
                sessionLog(
                    "engine_success",
                    fields: [
                        "engine": engineDisplayName(.dictationTranscriber),
                        "chars": "\(dictationResult.text.count)",
                        "language": dictationResult.language.rawValue,
                        "latency_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                    ]
                )
                return dictationResult
            }
            sessionLog("engine_empty", fields: ["engine": engineDisplayName(.dictationTranscriber)])
            sttFallbackOccurred = true
            sttFallbackReason = "empty_result"
            sessionLog("fallback_start", fields: ["from": engineDisplayName(.dictationTranscriber), "to": engineDisplayName(.speechRecognizer), "reason": "empty_result"])
            debugTrace("fallback source=dictationTranscriber target=speechRecognizer reason=empty_transcript")
        } catch {
            sttFallbackOccurred = true
            sttFallbackReason = error.localizedDescription
            sessionLog("engine_error", fields: ["engine": engineDisplayName(.dictationTranscriber), "reason": error.localizedDescription])
            sessionLog("fallback_start", fields: ["from": engineDisplayName(.dictationTranscriber), "to": engineDisplayName(.speechRecognizer), "reason": error.localizedDescription])
            debugTrace("fallback source=dictationTranscriber target=speechRecognizer reason=\(error.localizedDescription)")
        }
        return try await transcribeWithSpeechRecognizer(preferredLanguage: preferredLanguage)
    }

    private func transcribeFinalWithSpeechTranscriber(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        let startedAt = Date()
        sessionLog("engine_start", fields: ["engine": engineDisplayName(.speechTranscriber), "mode": operationMode.rawValue])
        do {
            let transcriberResult = try await transcribeWithSpeechTranscriber(preferredLanguage: preferredLanguage)
            if isUsableTranscript(transcriberResult.text) {
                sttFinalEngineForSession = .speechTranscriber
                sessionLog(
                    "engine_success",
                    fields: [
                        "engine": engineDisplayName(.speechTranscriber),
                        "chars": "\(transcriberResult.text.count)",
                        "language": transcriberResult.language.rawValue,
                        "latency_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                    ]
                )
                return transcriberResult
            }
            sessionLog("engine_empty", fields: ["engine": engineDisplayName(.speechTranscriber)])
            sttFallbackOccurred = true
            sttFallbackReason = "empty_result"
            sessionLog("fallback_start", fields: ["from": engineDisplayName(.speechTranscriber), "to": engineDisplayName(.speechRecognizer), "reason": "empty_result"])
            debugTrace("fallback source=speechTranscriber target=speechRecognizer reason=empty_transcript")
        } catch {
            if shouldDisableSpeechAnalyzer(for: error) {
                hasDisabledSpeechAnalyzerForSession = true
                publishBackendStatus()
            }
            sttFallbackOccurred = true
            sttFallbackReason = error.localizedDescription
            sessionLog("engine_error", fields: ["engine": engineDisplayName(.speechTranscriber), "reason": error.localizedDescription])
            sessionLog("fallback_start", fields: ["from": engineDisplayName(.speechTranscriber), "to": engineDisplayName(.speechRecognizer), "reason": error.localizedDescription])
            debugTrace("fallback source=speechTranscriber target=speechRecognizer reason=\(error.localizedDescription)")
        }
        return try await transcribeWithSpeechRecognizer(preferredLanguage: preferredLanguage)
    }

    private func transcribeFinalWithSpeechRecognizer(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        let startedAt = Date()
        sessionLog("engine_start", fields: ["engine": engineDisplayName(.speechRecognizer), "mode": operationMode.rawValue])
        do {
            let result = try await transcribeWithSpeechRecognizer(preferredLanguage: preferredLanguage)
            sttFinalEngineForSession = .speechRecognizer
            sessionLog(
                sttFallbackOccurred ? "fallback_success" : "engine_success",
                fields: [
                    "engine": engineDisplayName(.speechRecognizer),
                    "chars": "\(result.text.count)",
                    "language": result.language.rawValue,
                    "latency_ms": "\(Int(Date().timeIntervalSince(startedAt) * 1000))"
                ]
            )
            return result
        } catch {
            sessionLog(
                sttFallbackOccurred ? "fallback_failed" : "engine_error",
                fields: [
                    "engine": engineDisplayName(.speechRecognizer),
                    "reason": error.localizedDescription
                ]
            )
            throw error
        }
    }
    
    private func transcribeWithSpeechTranscriber(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        guard #available(iOS 26.0, *), canUseSpeechAnalyzer else { throw STTError.notReady }
        if isListening { stopListening() }
        let audio = try await finalAudioForTranscriptionAsync()
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        guard let analyzerLocale = await resolveSupportedSpeechAnalyzerLocale(for: languageHint) else {
            debugTrace("speech_transcriber_final unsupported_locale language=\(languageHint.rawValue) preferred=\(localeHint?.identifier ?? "auto")")
            throw TranscriptionEngineError.unsupportedLocale
        }
        let engine = SpeechTranscriberEngine()
        let audioSeconds = Double(audio.count) / targetSampleRate
        debugLogEngineSelection(
            phase: "speech_transcriber_final",
            engine: .speechTranscriber,
            detail: "preset=transcription localeHint=\(analyzerLocale.identifier) audio_s=\(String(format: "%.2f", audioSeconds))"
        )
        let output = try await engine.transcribe(
            TranscriptionRequest(
                audio: audio,
                sampleRate: targetSampleRate,
                localeHint: analyzerLocale,
                timeoutInterval: nil
            )
        )
        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: languageHint)
        lastLiveResolvedLanguage = resolvedLanguage
        return (output.text, resolvedLanguage)
    }

    private func transcribeWithDictationTranscriber(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        guard #available(iOS 26.0, *) else {
            return try await transcribeWithSpeechRecognizer(preferredLanguage: preferredLanguage)
        }

        if let finalText = getAppleLiveFinalText()?.trimmingCharacters(in: .whitespacesAndNewlines), !finalText.isEmpty {
            let language = preferredLanguage ?? liveLockedLanguage ?? lastLiveResolvedLanguage ?? preferredDeviceSupportedLanguage() ?? .english
            return (finalText, language)
        }

        if isListening { stopListening() }
        let audio = try await finalAudioForTranscriptionAsync()
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        let engine = DictationTranscriberEngine()
        debugLogEngineSelection(
            phase: "dictation_transcriber_final",
            engine: .dictationTranscriber,
            detail: "localeHint=\(localeHint?.identifier ?? "auto") audio_s=\(String(format: "%.2f", Double(audio.count) / targetSampleRate))"
        )
        let output = try await engine.transcribe(
            TranscriptionRequest(
                audio: audio,
                sampleRate: targetSampleRate,
                localeHint: localeHint,
                timeoutInterval: nil
            )
        )
        let resolvedLanguage = supportedLanguage(from: output.locale, fallback: languageHint)
        lastLiveResolvedLanguage = resolvedLanguage
        return (output.text, resolvedLanguage)
    }

    private func transcribeWithSpeechRecognizer(preferredLanguage: SupportedLanguage?) async throws -> (text: String, language: SupportedLanguage) {
        if operationMode == .liveStreaming,
           let streamingResult = try await finalizeStreamingSpeechRecognizerSessionIfNeeded(preferredLanguage: preferredLanguage) {
            lastLiveResolvedLanguage = streamingResult.language
            return streamingResult
        }

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
        guard let analyzerLocale = await resolveSupportedSpeechAnalyzerLocale(for: languageHint) else {
            debugTrace("speech_analyzer_partial unsupported_locale language=\(languageHint.rawValue) preferred=\(localeHint?.identifier ?? "auto")")
            throw SpeechAnalyzerTranscriptionEngine.EngineError.unsupportedLocale
        }
        let engine = SpeechAnalyzerTranscriptionEngine()
        let audioSeconds = Double(audioWindow.count) / targetSampleRate
        debugLogEngineSelection(
            phase: "speech_analyzer_partial",
            engine: .speechTranscriber,
            detail: "preset=progressiveTranscription localeHint=\(analyzerLocale.identifier) window_s=\(String(format: "%.2f", audioSeconds))"
        )
        let output = try await engine.transcribe(
            audio: audioWindow,
            sampleRate: targetSampleRate,
            localeHint: analyzerLocale,
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

        if operationMode == .liveStreaming {
            do {
                let streaming = try await transcribePartialFromStreamingSpeechRecognizer(
                    preferredLanguage: preferredLanguage,
                    minimumAudioSeconds: minimumAudioSeconds
                )
                if streaming.isStreamingActive {
                    return streaming.result
                }
            } catch {
                debugTrace("speech_recognizer_partial streaming_unavailable reason=\(error.localizedDescription)")
            }
        }

        debugTrace("speech_recognizer_partial fallback=windowed_batch")
        return try await transcribePartialCurrentBufferWithSpeechRecognizerWindowedBatch(
            preferredLanguage: preferredLanguage,
            maxAudioSeconds: maxAudioSeconds,
            minimumAudioSeconds: minimumAudioSeconds
        )
    }

    private func transcribePartialFromStreamingSpeechRecognizer(
        preferredLanguage: SupportedLanguage?,
        minimumAudioSeconds: Double
    ) async throws -> (result: LivePartialResult?, isStreamingActive: Bool) {
        guard isListening else { return (nil, false) }
        try await ensureStreamingSpeechRecognizerSessionIfNeeded(preferredLanguage: preferredLanguage)

        let (session, sessionID, activeID) = streamingSpeechRecognizerLock.withLock {
            (streamingSpeechRecognizerSession, streamingSpeechRecognizerSessionID, activeCaptureSessionID)
        }

        guard sessionID == activeID, let session, session.isRunning() else {
            return (nil, false)
        }

        let minimumSamples = Int(targetSampleRate * max(0.2, minimumAudioSeconds))
        let bufferedSamples = bufferLock.withLock { sampleBuffer.count }
        guard bufferedSamples >= minimumSamples else { return (nil, true) }

        let rawText = session.latestTextSnapshot().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawText.isEmpty else { return (nil, true) }

        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let resolvedLanguage = supportedLanguage(from: session.locale, fallback: languageHint)
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
        guard !currentWords.isEmpty else { return (nil, true) }

        let windowEndTime = currentBufferedAudioSeconds()
        let split = stabilizedSpeechRecognizerSplit(
            for: currentWords,
            windowStartTime: 0
        )
        let renderedText = joinCommittedVolatileText(committed: split.committed, volatile: split.volatile)
        rememberLiveTranscriptTextIfNonEmpty(renderedText)

        let segments = [
            LiveTranscriptSegment(
                startTime: 0,
                endTime: windowEndTime,
                text: renderedText
            )
        ]
        let livePartial = LivePartialResult(
            text: renderedText,
            language: resolvedLanguage,
            windowStartTime: 0,
            windowEndTime: windowEndTime,
            segments: segments,
            committedText: split.committed,
            volatileText: split.volatile
        )
        return (livePartial, true)
    }

    private func transcribePartialCurrentBufferWithSpeechRecognizerWindowedBatch(
        preferredLanguage: SupportedLanguage?,
        maxAudioSeconds: Double,
        minimumAudioSeconds: Double
    ) async throws -> LivePartialResult? {
        let fullAudio = snapshotAudioBuffer()
        let minimumSamples = Int(targetSampleRate * max(0.2, minimumAudioSeconds))
        guard fullAudio.count >= minimumSamples else { return nil }

        let audioWindow = recentAudioWindow(fullAudio, maxSeconds: max(maxAudioSeconds, 24.0))
        let windowStartSample = max(0, fullAudio.count - audioWindow.count)
        let windowStartTime = TimeInterval(windowStartSample) / targetSampleRate
        let windowEndTime = TimeInterval(fullAudio.count) / targetSampleRate
        let languageHint = effectiveSessionLanguage(preferredLanguage: preferredLanguage)
        let localeHint = speechAnalyzerLocaleHint(for: languageHint)
        let engine = SpeechRecognizerTranscriptionEngine()
        debugLogEngineSelection(
            phase: "speech_recognizer_partial_windowed",
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
        if #available(iOS 26.0, *),
           let engineError = error as? SpeechAnalyzerTranscriptionEngine.EngineError,
           case .unsupportedLocale = engineError {
            return true
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("not subscribed to transcription")
            || message.contains("cannot check the download status")
            || message.contains("asset")
            || message.contains("speech recognition")
            || message.contains("authorization")
            || message.contains("unsupported locale")
            || message.contains("no supported speechanalyzer locale found")
            || message.contains("too many allocated locales") {
            return true
        }
        // Keep analyzer enabled for transient runtime failures.
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

    // Prefer one stable regional locale per supported language to reduce
    // analyzer locale churn; resolver will still fall back if unavailable.
    private func speechAnalyzerLocaleHint(for language: SupportedLanguage?) -> Locale? {
        guard let language else { return nil }
        switch language {
        case .english:
            return Locale(identifier: "en-US")
        case .spanish:
            return Locale(identifier: "es-MX")
        case .french:
            return Locale(identifier: "fr-CA")
        }
    }

    @available(iOS 26.0, *)
    private func resolveSupportedSpeechAnalyzerLocale(for language: SupportedLanguage) async -> Locale? {
        guard SpeechTranscriber.isAvailable else { return nil }
        let supportedLocales = await SpeechTranscriber.supportedLocales
        guard !supportedLocales.isEmpty else { return nil }

        let supportedByIdentifier = Dictionary(
            supportedLocales.map { ($0.identifier.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let hint = speechAnalyzerLocaleHint(for: language) ?? Locale(identifier: language.rawValue)
        return SpeechLocaleResolution.resolve(
            localeHint: hint,
            supportedByIdentifier: supportedByIdentifier,
            allSupported: supportedLocales
        )
    }

    private func supportedLanguage(from locale: Locale, fallback: SupportedLanguage?) -> SupportedLanguage {
        switch locale.language.languageCode?.identifier {
        case "en": return .english
        case "es": return .spanish
        case "fr": return .french
        default: return fallback ?? preferredDeviceSupportedLanguage() ?? .english
        }
    }

    private func effectiveSessionLanguage(preferredLanguage: SupportedLanguage?) -> SupportedLanguage {
        preferredLanguage
            ?? sessionPreferredLanguageHint
            ?? liveLockedLanguage
            ?? lastLiveResolvedLanguage
            ?? preferredDeviceSupportedLanguage()
            ?? .english
    }

    private func shortSessionID(_ sessionID: UUID?) -> String {
        guard let sessionID else { return "none" }
        return String(sessionID.uuidString.prefix(8))
    }

    private func engineDisplayName(_ engine: TranscriptionEngine) -> String {
        switch engine {
        case .dictationTranscriber: return "DictationTranscriberEngine"
        case .speechTranscriber: return "SpeechTranscriberEngine"
        case .speechRecognizer: return "SpeechRecognizerTranscriptionEngine"
        }
    }

    private func currentPlatformLabel() -> String {
        if #available(iOS 26.0, *) {
            return "iOS26+"
        }
        return "iOS16-25"
    }

    private func sessionLog(
        _ event: String,
        sessionID: UUID? = nil,
        fields: [String: String] = [:]
    ) {
        let resolvedSessionID = sessionID ?? activeCaptureSessionID
        let sid = shortSessionID(resolvedSessionID)
        let payload = fields
            .filter { !$0.value.isEmpty }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        let message = payload.isEmpty
            ? "[session=\(sid)] \(event)"
            : "[session=\(sid)] \(event) \(payload)"
        STTSessionLogger.shared.log(source: "STT", message: message)
#if DEBUG
        print("[STT_TRACE][STT] \(message)")
#endif
    }

    private func logAppleLiveTapInput(buffer: AVAudioPCMBuffer) {
        guard operationMode == .liveStreaming else { return }
        let now = Date()
        sttAppleLiveTapBufferCount += 1
        sttAppleLiveTapSampleCount += Int(buffer.frameLength)
        sttAppleLiveTapLastBufferAt = now
        if sttAppleLiveTapFirstBufferAt == nil {
            sttAppleLiveTapFirstBufferAt = now
            let firstLatencyMs = sttSessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
            sessionLog(
                "apple_live_audio_tap_first_buffer",
                fields: [
                    "mode": operationMode.rawValue,
                    "sample_rate": String(format: "%.0f", buffer.format.sampleRate),
                    "channels": "\(buffer.format.channelCount)",
                    "frames": "\(buffer.frameLength)",
                    "first_buffer_latency_ms": "\(firstLatencyMs)"
                ]
            )
        }
        guard sttAppleLiveTapLastLogAt == nil || now.timeIntervalSince(sttAppleLiveTapLastLogAt!) >= sttAppleLiveTapLogInterval else {
            return
        }
        sttAppleLiveTapLastLogAt = now
        let audioSeconds = Double(sttAppleLiveTapSampleCount) / targetSampleRate
        let elapsedMs = sttSessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
        sessionLog(
            "apple_live_audio_tap",
            fields: [
                "mode": operationMode.rawValue,
                "buffer_count": "\(sttAppleLiveTapBufferCount)",
                "samples": "\(sttAppleLiveTapSampleCount)",
                "audio_s": String(format: "%.2f", audioSeconds),
                "sample_rate": String(format: "%.0f", buffer.format.sampleRate),
                "channels": "\(buffer.format.channelCount)",
                "elapsed_ms": "\(elapsedMs)"
            ]
        )
    }

    private func logLiveStreamUnavailableFallback(_ key: String, message: String, minimumInterval: TimeInterval = 2.0) {
        let now = Date()
        if sttLastStreamUnavailableFallbackKey == key,
           let last = sttLastStreamUnavailableFallbackLogAt,
           now.timeIntervalSince(last) < minimumInterval {
            return
        }
        sttLastStreamUnavailableFallbackKey = key
        sttLastStreamUnavailableFallbackLogAt = now
        debugTrace(message)
    }

    private func logStartupFallbackWarningOnce(key: String, message: String) {
        if sttDidLogFirstPartialLatency {
            logLiveStreamUnavailableFallback(key, message: message)
            return
        }
        guard !sttDidLogStartupFallbackWarning else { return }
        sttDidLogStartupFallbackWarning = true
        sessionLog(
            "startup_fallback_warning",
            fields: [
                "mode": operationMode.rawValue,
                "reason": "no_stream_result",
                "detail": message
            ]
        )
        debugTrace(message)
    }

    @available(iOS 26.0, *)
    private func logAppleLiveNoResultDiagnostics(
        snapshot: AppleLiveTranscriptionCoordinator.LiveDiagnosticsSnapshot?,
        liveElapsed: TimeInterval
    ) {
        let now = Date()
        if sttLastStreamUnavailableFallbackKey == "apple_live_no_result",
           let last = sttLastStreamUnavailableFallbackLogAt,
           now.timeIntervalSince(last) < 2.0 {
            return
        }
        sttLastStreamUnavailableFallbackKey = "apple_live_no_result"
        sttLastStreamUnavailableFallbackLogAt = now

        let fallbackLanguage = effectiveSessionLanguage(preferredLanguage: nil)
        let locale = snapshot?.locale ?? (speechAnalyzerLocaleHint(for: fallbackLanguage)?.identifier ?? "auto")
        sessionLog(
            "apple_live_no_result",
            fields: [
                "locale": locale,
                "streak": "\(advancedLiveStreamNoResultStreak)",
                "live_s": String(format: "%.2f", liveElapsed),
                "state": snapshot?.state ?? "none",
                "coordinator_exists": snapshot == nil ? "false" : "true",
                "has_received_buffer": snapshot?.hasReceivedBuffer == true ? "true" : "false",
                "accepted_buffer_count": "\(snapshot?.acceptedBufferCount ?? 0)",
                "accepted_samples": "\(snapshot?.acceptedSampleCount ?? 0)",
                "converted_buffer_count": "\(snapshot?.convertedBufferCount ?? 0)",
                "dropped_buffer_count": "\(snapshot?.droppedBufferCount ?? 0)",
                "has_received_result": snapshot?.hasReceivedResult == true ? "true" : "false",
                "result_count": "\(snapshot?.resultCount ?? 0)",
                "first_buffer_elapsed_ms": snapshot?.firstBufferElapsedMs.map(String.init) ?? "",
                "first_result_elapsed_ms": snapshot?.firstResultElapsedMs.map(String.init) ?? ""
            ]
        )
    }

    private func isFrenchLiveSession(preferredLanguage: SupportedLanguage?) -> Bool {
        operationMode == .liveStreaming && effectiveSessionLanguage(preferredLanguage: preferredLanguage) == .french
    }

    private func markLiveFallbackUsed(reason: String) {
        guard operationMode == .liveStreaming else { return }
        sttLiveFallbackUsed = true
        if sttLiveFallbackReason == nil {
            sttLiveFallbackReason = reason
        }
    }

    private func isRetryableStreamingSpeechRecognizerError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 203
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

    private func logLivePartialResultIfPresent(_ result: LivePartialResult?, phase: String, previousText: String) {
        guard let result else { return }
        sttLivePartialSequence += 1
        let committedChars = result.committedText?.count ?? 0
        let volatileChars = result.volatileText?.count ?? max(0, result.text.count - committedChars)
        let changed = result.text != previousText
        let now = Date()
        let sessionElapsedMs = sttSessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
        let partialIntervalMs = sttLastPartialLoggedAt.map { Int(now.timeIntervalSince($0) * 1000) }
        sttLastPartialLoggedAt = now

        var fields: [String: String] = [
            "seq": "\(sttLivePartialSequence)",
            "phase": phase,
            "mode": operationMode.rawValue,
            "engine": engineDisplayName(preferredLivePartialEngine()),
            "audio_s": String(format: "%.2f", result.windowEndTime),
            "window_start_s": String(format: "%.2f", result.windowStartTime),
            "window_end_s": String(format: "%.2f", result.windowEndTime),
            "chars": "\(result.text.count)",
            "committed_chars": "\(committedChars)",
            "volatile_chars": "\(volatileChars)",
            "changed": changed ? "true" : "false",
            "session_elapsed_ms": "\(sessionElapsedMs)"
        ]
        if let partialIntervalMs {
            fields["partial_interval_ms"] = "\(partialIntervalMs)"
        }
        if !sttDidLogFirstPartialLatency {
            sttDidLogFirstPartialLatency = true
            fields["first_partial_latency_ms"] = "\(sessionElapsedMs)"
        }

        sessionLog("partial", fields: fields)
        debugTrace(
            "live_output phase=\(phase) lang=\(result.language.rawValue) window=\(String(format: "%.2f", result.windowStartTime))-\(String(format: "%.2f", result.windowEndTime)) chars=\(result.text.count)"
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

        let previousPublishedText = lastPublishedLivePartialText
        lastPublishedLivePartialText = trimmed
        lastPublishedLivePartialWindowStartTime = result.windowStartTime
        lastPublishedLivePartialWindowEndTime = result.windowEndTime
        lastPublishedLivePartialAt = now
        logLivePartialResultIfPresent(result, phase: phase, previousText: previousPublishedText)
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
        let sessionTag = "session=\(shortSessionID(activeCaptureSessionID))"
        STTSessionLogger.shared.log(source: "SpeechToTextManager", message: "\(sessionTag) \(message)")
#if DEBUG
        print("[STT_TRACE][SpeechToTextManager] \(sessionTag) \(message)")
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
    deinit {
        if let reservedLocale {
            Task { await AssetInventory.release(reservedLocale: reservedLocale) }
        }
    }
    
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

    struct LiveDiagnosticsSnapshot {
        let coordinatorSessionID: UUID?
        let state: String
        let locale: String
        let hasReceivedBuffer: Bool
        let acceptedBufferCount: Int
        let acceptedSampleCount: Int
        let convertedBufferCount: Int
        let droppedBufferCount: Int
        let hasReceivedResult: Bool
        let resultCount: Int
        let firstBufferElapsedMs: Int?
        let firstResultElapsedMs: Int?
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
    /// Locale reserved for this coordinator's live session. Held for the
    /// full session lifetime (not just asset install) and released in
    /// stop(finalize:) or deinit.
    private var reservedLocale: Locale?
    private var ownerSessionID: UUID?
    private var sessionStartedAt: Date?
    private var acceptedBufferCount: Int = 0
    private var acceptedSampleCount: Int = 0
    private var convertedBufferCount: Int = 0
    private var droppedBufferCount: Int = 0
    private var firstAcceptedBufferAt: Date?
    private var lastAcceptedBufferAt: Date?
    private var lastAudioInputLogAt: Date?
    private var resultCount: Int = 0
    private var hasReceivedResult: Bool = false
    private var firstResultAt: Date?
    private let audioInputLogInterval: TimeInterval = 1.0

    func start(localeHint: Locale?, ownerSessionID: UUID?) async throws -> EngineSelection {
        let sessionID = UUID()
        self.ownerSessionID = ownerSessionID
        sessionStartedAt = Date()
        let priorState = lifecycleLock.withLock { lifecycleState }
        if priorState == .running || priorState == .starting || priorState == .stopping {
            try await stop(finalize: false)
        }
        transitionLifecycle(to: .starting, sessionID: sessionID, detail: "phase=start_begin")
        resetTranscriptState()
        hasLoggedFirstInputBuffer = false
        acceptedBufferCount = 0
        acceptedSampleCount = 0
        convertedBufferCount = 0
        droppedBufferCount = 0
        firstAcceptedBufferAt = nil
        lastAcceptedBufferAt = nil
        lastAudioInputLogAt = nil
        resultCount = 0
        hasReceivedResult = false
        firstResultAt = nil

        let resolved = try await withThrowingTaskGroup(of: EngineSelection.self) { group in
            group.addTask { try await self.resolveEngine(localeHint: localeHint, sessionID: sessionID) }
            group.addTask {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                throw NSError(
                    domain: "AppleLiveTranscriptionCoordinator",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Engine resolution timed out"]
                )
            }
            guard let result = try await group.next() else {
                throw NSError(domain: "AppleLiveTranscriptionCoordinator", code: 4, userInfo: [NSLocalizedDescriptionKey: "Engine resolution produced no result"])
            }
            group.cancelAll()
            return result
        }
        logEvent(
            "apple_live_session_start",
            fields: [
                "coordinator_session_id": shortSessionID(sessionID),
                "locale": resolved.locale.identifier,
                "engine": resolved.engine.rawValue,
                "state": "resolved",
                "elapsed_ms": "\(elapsedMs())"
            ]
        )
        
        // Reserve for the whole live session — install AND ongoing analysis —
        // not just the install step. Released in stop(finalize:) / deinit.
        try await AssetInventory.reserve(locale: resolved.locale)
        reservedLocale = resolved.locale
        
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
                            self.logEvent("apple_live_error", fields: self.errorFields(error: error, phase: "results_stream_speech_transcriber"))
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
                            self.logEvent("apple_live_error", fields: self.errorFields(error: error, phase: "results_stream_dictation_transcriber"))
                        }
                    }
                }

                try await analyzer.start(inputSequence: stream)
            }
        } catch {
            logEvent("apple_live_error", fields: errorFields(error: error, phase: "start"))
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
                self.recordDroppedBuffer()
                return
            }
            let shouldLogFirstBuffer = !self.hasLoggedFirstInputBuffer
            let didConvert = !self.isAudioFormat(buffer.format, equivalentTo: expectedFormat)
            self.recordAcceptedBuffer(inputBuffer, didConvert: didConvert)
            if shouldLogFirstBuffer {
                self.logEvent(
                    "apple_live_audio_first_buffer",
                    fields: [
                        "coordinator_session_id": self.shortSessionID(sessionID),
                        "sample_rate": String(format: "%.0f", inputBuffer.format.sampleRate),
                        "channels": "\(inputBuffer.format.channelCount)",
                        "frames": "\(inputBuffer.frameLength)",
                        "first_buffer_latency_ms": "\(self.elapsedMs())"
                    ]
                )
            }
            continuation.yield(AnalyzerInput(buffer: inputBuffer))
            if shouldLogFirstBuffer {
                self.hasLoggedFirstInputBuffer = true
            }
            self.logPeriodicAudioInputIfNeeded(inputBuffer)
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
                logEvent("apple_live_error", fields: errorFields(error: error, phase: "stop_finalize"))
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
        lifecycleLock.withLock {
            activeSessionID = nil
        }
        hasLoggedEngineSelection = false
        if let reservedLocale {
            await AssetInventory.release(reservedLocale: reservedLocale)
            self.reservedLocale = nil
        }
        logEvent(
            "apple_live_audio_input",
            fields: [
                "state": "stop_totals",
                "buffer_count": "\(acceptedBufferCount)",
                "samples": "\(acceptedSampleCount)",
                "audio_s": String(format: "%.2f", acceptedAudioSeconds()),
                "converted_buffer_count": "\(convertedBufferCount)",
                "dropped_buffer_count": "\(droppedBufferCount)",
                "result_count": "\(resultCount)"
            ]
        )
        analyzerInputFormat = nil
        transitionLifecycle(to: .idle, sessionID: sessionID, detail: "phase=stopped")
    }

    func diagnosticsSnapshot() -> LiveDiagnosticsSnapshot {
        let state = lifecycleLock.withLock { lifecycleState.rawValue }
        let firstBufferElapsedMs = firstAcceptedBufferAt.map { first in
            sessionStartedAt.map { Int(first.timeIntervalSince($0) * 1000) } ?? 0
        }
        let firstResultElapsedMs = firstResultAt.map { first in
            sessionStartedAt.map { Int(first.timeIntervalSince($0) * 1000) } ?? 0
        }
        return LiveDiagnosticsSnapshot(
            coordinatorSessionID: lifecycleLock.withLock { activeSessionID },
            state: state,
            locale: latestLocale.identifier,
            hasReceivedBuffer: acceptedBufferCount > 0,
            acceptedBufferCount: acceptedBufferCount,
            acceptedSampleCount: acceptedSampleCount,
            convertedBufferCount: convertedBufferCount,
            droppedBufferCount: droppedBufferCount,
            hasReceivedResult: hasReceivedResult,
            resultCount: resultCount,
            firstBufferElapsedMs: firstBufferElapsedMs,
            firstResultElapsedMs: firstResultElapsedMs
        )
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
        let now = Date()
        if !hasReceivedResult {
            hasReceivedResult = true
            firstResultAt = now
            let firstFromSessionMs = sessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0
            let firstFromAudioMs = firstAcceptedBufferAt.map { Int(now.timeIntervalSince($0) * 1000) }
            logEvent(
                "apple_live_first_result",
                fields: [
                    "locale": locale.identifier,
                    "first_result_latency_ms": "\(firstFromSessionMs)",
                    "from_first_buffer_ms": firstFromAudioMs.map(String.init) ?? "",
                    "chars": "\(String(text.characters).count)"
                ]
            )
        }
        resultCount += 1
        logEvent(
            "apple_live_result",
            fields: [
                "locale": locale.identifier,
                "result_count": "\(resultCount)",
                "elapsed_ms": "\(sessionStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? 0)",
                "chars": "\(String(text.characters).count)",
                "is_final": isFinal ? "true" : "false",
                "segment_count": "1"
            ]
        )
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
        logEvent(
            "apple_live_state",
            fields: [
                "state": next.rawValue,
                "coordinator_session_id": shortSessionID(sessionID),
                "locale": latestLocale.identifier,
                "elapsed_ms": "\(elapsedMs())"
            ]
        )
    }

    private func isSessionActive(_ sessionID: UUID) -> Bool {
        lifecycleLock.withLock {
            activeSessionID == sessionID && (lifecycleState == .starting || lifecycleState == .running)
        }
    }

    private func recordAcceptedBuffer(_ buffer: AVAudioPCMBuffer, didConvert: Bool) {
        acceptedBufferCount += 1
        acceptedSampleCount += Int(buffer.frameLength)
        if didConvert {
            convertedBufferCount += 1
        }
        if firstAcceptedBufferAt == nil {
            firstAcceptedBufferAt = Date()
        }
        lastAcceptedBufferAt = Date()
    }

    private func recordDroppedBuffer() {
        droppedBufferCount += 1
    }

    private func logPeriodicAudioInputIfNeeded(_ buffer: AVAudioPCMBuffer) {
        let now = Date()
        guard lastAudioInputLogAt == nil || now.timeIntervalSince(lastAudioInputLogAt!) >= audioInputLogInterval else { return }
        lastAudioInputLogAt = now
        logEvent(
            "apple_live_audio_input",
            fields: [
                "state": lifecycleLock.withLock { lifecycleState.rawValue },
                "buffer_count": "\(acceptedBufferCount)",
                "samples": "\(acceptedSampleCount)",
                "audio_s": String(format: "%.2f", acceptedAudioSeconds()),
                "sample_rate": String(format: "%.0f", buffer.format.sampleRate),
                "channels": "\(buffer.format.channelCount)",
                "converted_buffer_count": "\(convertedBufferCount)",
                "dropped_buffer_count": "\(droppedBufferCount)",
                "has_received_buffer": acceptedBufferCount > 0 ? "true" : "false",
                "elapsed_ms": "\(elapsedMs())"
            ]
        )
    }

    private func acceptedAudioSeconds() -> TimeInterval {
        guard let format = analyzerInputFormat else { return 0 }
        return Double(acceptedSampleCount) / format.sampleRate
    }

    private func elapsedMs() -> Int {
        guard let sessionStartedAt else { return 0 }
        return Int(Date().timeIntervalSince(sessionStartedAt) * 1000)
    }

    private func shortSessionID(_ sessionID: UUID?) -> String {
        guard let sessionID else { return "none" }
        return String(sessionID.uuidString.prefix(8))
    }

    private func errorFields(error: Error, phase: String) -> [String: String] {
        let nsError = error as NSError
        return [
            "phase": phase,
            "domain": nsError.domain,
            "code": "\(nsError.code)",
            "reason": error.localizedDescription,
            "elapsed_ms": "\(elapsedMs())"
        ]
    }

    private func logEvent(_ event: String, fields: [String: String]) {
        let sid = shortSessionID(ownerSessionID)
        let payload = fields
            .filter { !$0.value.isEmpty }
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: " ")
        let message = payload.isEmpty
            ? "[session=\(sid)] \(event)"
            : "[session=\(sid)] \(event) \(payload)"
        STTSessionLogger.shared.log(source: "STT", message: message)
#if DEBUG
        print("[STT_TRACE][STT] \(message)")
#endif
    }

}
