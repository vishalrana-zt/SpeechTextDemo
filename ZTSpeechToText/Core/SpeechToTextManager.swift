//
//  SpeechToTextManager.swift
//  Offline, on-device speech-to-text with automatic language detection.
//
//  Requires: WhisperKit (https://github.com/argmaxinc/WhisperKit) added via SPM.
//  Package URL: https://github.com/argmaxinc/WhisperKit
//

import Foundation
import AVFoundation
import CoreML
import WhisperKit

final class SpeechToTextManager: NSObject {

    // MARK: - Singleton

    static let shared = SpeechToTextManager()
    private override init() { super.init() }

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

    // MARK: - Private

    private var liveWhisperKit: WhisperKit?
    private var finalWhisperKit: WhisperKit?
    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private let targetSampleRate: Double = 16_000
    private let bufferLock = NSLock()
    private var hasInputTapInstalled = false

    private var autoStopOnSilence = false
    private var requiredSilenceDuration: TimeInterval = 1.0
    private var silenceThreshold: Float = 0.003
    private var accumulatedSilenceDuration: TimeInterval = 0
    private var accumulatedRecordingDuration: TimeInterval = 0
    private var hasTriggeredAutoStop = false
    private let maxRecordingDuration: TimeInterval = 10 * 60
    private var tinyDownloadTransfer: CDNModelDownloader.TransferProgress?
    private var smallDownloadTransfer: CDNModelDownloader.TransferProgress?
    private var liveLockedLanguage: SupportedLanguage?
    private var pendingLiveLockLanguage: SupportedLanguage?
    private var pendingLiveLockConfirmations: Int = 0
    private var lastLiveResolvedLanguage: SupportedLanguage?
    private let liveLanguageLockMinimumSeconds: Double = 2.0
    private let liveLanguageLockConfirmationsRequired: Int = 2
    private var didPrewarmRecordingPath = false
    private var didPrewarmLiveDecode = false
    private var isPrewarmingSmallModel = false
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

    var onSilenceAutoStopTriggered: (() -> Void)?
    var onAudioLevelChange: ((Float) -> Void)?

    private static let modelReadyKey = "SpeechToTextManager.modelReadyV2"
    private static let optedInKey = "SpeechToTextManager.optedIn"
    private static let liveTranscriptionEnabledKey = "SpeechToTextManager.liveTranscriptionEnabled"
    private static let tinyModelName = "openai_whisper-tiny"
    private static let smallModelName = "openai_whisper-small"
    private static let modelRepo = "argmaxinc/whisperkit-coreml"
    private static let tinyModelZipURL = URL(string: "https://zt-cdn.zentrades.pro/iOS-Assets/openai_whisper-tiny.zip")!
    private static let smallModelZipURL = URL(string: "https://zt-cdn.zentrades.pro/iOS-Assets/openai_whisper-small.zip")!
    
    /// True once the model is downloaded AND loaded into memory — the only
    /// state in which recording/transcription is actually usable.
    var isReady: Bool {
        if case .ready = modelState { return true }
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
    
    enum ModelSource {
        case bundled       // shipped inside the app, zero download
        case cdn           // your S3+CloudFront
        case huggingface   // HuggingFace hub
    }

    private enum ModelVariant {
        case tiny
        case small

        var installFolderName: String {
            switch self {
            case .tiny: return "SpeechModelTiny"
            case .small: return "SpeechModelSmall"
            }
        }

        var modelName: String {
            switch self {
            case .tiny: return SpeechToTextManager.tinyModelName
            case .small: return SpeechToTextManager.smallModelName
            }
        }

        var cdnZipURL: URL {
            switch self {
            case .tiny: return SpeechToTextManager.tinyModelZipURL
            case .small: return SpeechToTextManager.smallModelZipURL
            }
        }
    }

    private enum ComputeProfile {
        case liveTinyFast
        case finalSmallBalanced
    }

    private static let modelSource: ModelSource = .bundled
    private let tinyCDNDownloader = CDNModelDownloader()
    private let smallCDNDownloader = CDNModelDownloader()
    private var operationMode: OperationMode = .liveStreaming

    var isBundledModelSource: Bool {
        Self.modelSource == .bundled
    }

    func setOperationMode(_ mode: OperationMode) {
        guard operationMode != mode else { return }
        operationMode = mode
        liveWhisperKit = nil
        finalWhisperKit = nil
        modelState = .notDownloaded
    }
    
    // Safe to call again on relaunch if a previous download was interrupted —
    // the underlying downloader resumes partial files rather than restarting.
    func prepareOnOptIn() async {
        UserDefaults.standard.set(true, forKey: Self.optedInKey)

        if isActiveModelLoaded {
            modelState = .ready
            return
        }

        if await loadInstalledModelsIfAvailable() {
            return
        }

        if Self.modelSource == .bundled {
            await loadBundledModels()
            return
        }

        modelState = .downloading(DownloadStatus(progress: 0, downloadedBytes: 0, totalBytes: 0))
        tinyDownloadTransfer = nil
        smallDownloadTransfer = nil

        do {
            let selectedVariant = activeModelVariant
            let selectedModelFolder: URL

            if Self.modelSource == .cdn {
                selectedModelFolder = try await downloadFromCDN(variant: selectedVariant)
            } else if Self.modelSource == .huggingface {
                selectedModelFolder = try await WhisperKit.download(variant: selectedVariant.modelName, from: Self.modelRepo)
            } else {
                modelState = .failed("Unsupported model source.")
                return
            }

            modelState = .loadingModel(loaded: 0, total: 1)
            try await loadModel(variant: selectedVariant, from: selectedModelFolder)

            UserDefaults.standard.set(true, forKey: Self.modelReadyKey)
            modelState = .ready
        } catch is CancellationError {
            modelState = .failed("Download cancelled. Tap Retry to resume.")
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    private func loadBundledModels() async {
        let selectedVariant = activeModelVariant
        guard let sourceFolder = bundledModelURL(for: selectedVariant) else {
            modelState = .failed("Bundled model '\(selectedVariant.modelName)' not found in app bundle")
            return
        }

        do {
            modelState = .loadingModel(loaded: 0, total: 1)
            let modelFolder = try prepareBundledModelFolder(for: selectedVariant, sourceFolder: sourceFolder)
            try await loadModel(variant: selectedVariant, from: modelFolder)
            UserDefaults.standard.set(true, forKey: Self.modelReadyKey)
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
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
        if isReady { return true }
        if hasOptedIn, case .downloading = modelState {
            return false // already downloading, just show progress UI
        }
        if hasOptedIn, case .loadingModel = modelState {
            return false // model downloaded, now being loaded into memory
        }
        if hasOptedIn {
            await prepareOnOptIn() // opted in earlier, download never finished/started this session
        }
        return false
    }

    private func installedModelFolderURL(for variant: ModelVariant) -> URL? {
        let fileManager = FileManager.default
        let baseDir = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        // 1. Plain location — where CDN-downloaded models land (see
        //    destinationFolderURL in CDNModelDownloader), and also where a
        //    bundled model lands if its files already use clean names.
        let plainDestination = baseDir.appendingPathComponent(variant.installFolderName, isDirectory: true)
        if isModelFolder(plainDestination, fileManager: fileManager) {
            return plainDestination
        }

        // 2. Bundled-prepared location — only relevant for the tiny model when
        //    modelSource == .bundled, where prepareBundledModelFolder() renames
        //    the tiny_-prefixed bundle resource files into this folder.
        let preparedDestination = baseDir.appendingPathComponent("BundledPreparedModels", isDirectory: true)
            .appendingPathComponent(variant.installFolderName, isDirectory: true)
        if isModelFolder(preparedDestination, fileManager: fileManager) {
            return preparedDestination
        }

        // 3. Fallback — some packaging may nest the model one level deeper
        //    than expected under the plain location; check its children.
        let children = (try? fileManager.contentsOfDirectory(
            at: plainDestination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children where isModelFolder(child, fileManager: fileManager) {
            return child
        }

        return nil
    }

    private func bundledModelURL(for variant: ModelVariant) -> URL? {
        let alternateModelName = variant.modelName.replacingOccurrences(of: "-", with: "_")
        let modelNames = Array(Set([variant.modelName, alternateModelName]))
        var candidates: [URL?] = []

        for name in modelNames {
            candidates.append(contentsOf: [
                Bundle.main.url(forResource: name, withExtension: nil),
                Bundle.main.url(forResource: name, withExtension: "bundle"),
                Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Resource"),
                Bundle.main.url(forResource: name, withExtension: "bundle", subdirectory: "Resource"),
                Bundle.main.resourceURL?.appendingPathComponent(name, isDirectory: true),
                Bundle.main.resourceURL?.appendingPathComponent("\(name).bundle", isDirectory: true),
                Bundle.main.resourceURL?.appendingPathComponent("Resource", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true),
                Bundle.main.resourceURL?.appendingPathComponent("Resource", isDirectory: true)
                    .appendingPathComponent("\(name).bundle", isDirectory: true)
            ])
        }

        for candidate in candidates.compactMap({ $0 }) where isBundledModelFolder(candidate, variant: variant) {
            return candidate
        }

        return nil
    }

    private func isBundledModelFolder(_ url: URL, variant: ModelVariant) -> Bool {
        let fileManager = FileManager.default
        if isModelFolder(url, fileManager: fileManager) {
            return true
        }

        guard variant == .tiny else { return false }

        let requiredTinyNames = [
            "tiny_MelSpectrogram.mlmodelc",
            "tiny_AudioEncoder.mlmodelc",
            "tiny_TextDecoder.mlmodelc",
            "tiny_config.json"
        ]
        return requiredTinyNames.allSatisfy { name in
            fileManager.fileExists(atPath: url.appendingPathComponent(name).path)
        }
    }

    private func prepareBundledModelFolder(for variant: ModelVariant, sourceFolder: URL) throws -> URL {
        if variant == .small {
            return sourceFolder
        }

        let fileManager = FileManager.default
        if isModelFolder(sourceFolder, fileManager: fileManager) {
            return sourceFolder
        }

        let tempRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BundledPreparedModels", isDirectory: true)
        let destination = tempRoot.appendingPathComponent(variant.installFolderName, isDirectory: true)

        // Skip recreation if a valid copy already exists — this is what lets
        // Core ML's ANE compile cache actually persist across launches. Without
        // this check, the destination gets deleted and recopied every single
        // launch, giving every file a fresh modification time and invalidating
        // whatever compile cache Core ML had built for it.
        if isModelFolder(destination, fileManager: fileManager) {
            return destination
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let mappings: [(source: String, target: String)] = [
            ("tiny_AudioEncoder.mlmodelc", "AudioEncoder.mlmodelc"),
            ("tiny_MelSpectrogram.mlmodelc", "MelSpectrogram.mlmodelc"),
            ("tiny_TextDecoder.mlmodelc", "TextDecoder.mlmodelc"),
            ("tiny_config.json", "config.json"),
            ("tiny_generation_config.json", "generation_config.json")
        ]

        for mapping in mappings {
            let source = sourceFolder.appendingPathComponent(mapping.source)
            let target = destination.appendingPathComponent(mapping.target)
            if fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: target)
            }
        }

        guard isModelFolder(destination, fileManager: fileManager) else {
            throw STTError.notReady
        }

        return destination
    }

    private func loadInstalledModelsIfAvailable() async -> Bool {
        let selectedVariant = activeModelVariant
        guard let modelFolder = installedModelFolderURL(for: selectedVariant) else {
            return false
        }

        do {
            modelState = .loadingModel(loaded: 0, total: 1)
            try await loadModel(variant: selectedVariant, from: modelFolder)
            modelState = .ready
            return true
        } catch {
            return false
        }
    }

    private func downloadFromCDN(variant: ModelVariant) async throws -> URL {
        let downloader = variant == .tiny ? tinyCDNDownloader : smallCDNDownloader
        return try await downloader.downloadAndUnzip(
            modelZipURL: variant.cdnZipURL,
            installFolderName: variant.installFolderName
        ) { [weak self] transfer in
            self?.updateDownloadState(for: variant, transfer: transfer)
        }
    }

    private func updateDownloadState(for variant: ModelVariant, transfer: CDNModelDownloader.TransferProgress) {
        switch variant {
        case .tiny:
            tinyDownloadTransfer = transfer
        case .small:
            smallDownloadTransfer = transfer
        }

        let tinyDownloaded = tinyDownloadTransfer?.downloadedBytes ?? 0
        let smallDownloaded = smallDownloadTransfer?.downloadedBytes ?? 0
        let tinyTotal = tinyDownloadTransfer?.totalBytes ?? 0
        let smallTotal = smallDownloadTransfer?.totalBytes ?? 0

        let combinedDownloaded = max(0, tinyDownloaded + smallDownloaded)
        let combinedTotal = max(0, tinyTotal + smallTotal)
        let combinedFraction: Double
        if combinedTotal > 0 {
            combinedFraction = Double(combinedDownloaded) / Double(combinedTotal)
        } else {
            let tinyFraction = tinyDownloadTransfer?.fraction ?? 0
            let smallFraction = smallDownloadTransfer?.fraction ?? 0
            combinedFraction = (tinyFraction + smallFraction) * 0.5
        }

        updateDownloadState(
            fraction: combinedFraction,
            downloadedBytes: combinedDownloaded,
            totalBytes: combinedTotal
        )
    }

    private func isModelFolder(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }

        let requiredNames = [
            "MelSpectrogram.mlmodelc",
            "AudioEncoder.mlmodelc",
            "TextDecoder.mlmodelc",
            "config.json"
        ]

        return requiredNames.allSatisfy { name in
            fileManager.fileExists(atPath: url.appendingPathComponent(name).path)
        }
    }

    private func createWhisperKit(modelFolder: String, profile: ComputeProfile) async throws -> WhisperKit {
        let preferredCompute: ModelComputeOptions
        switch profile {
        case .liveTinyFast:
            preferredCompute = ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            )
        case .finalSmallBalanced:
            // Force CPU-only for final Small decode. On some devices/OS states,
            // ANE compilation can fail at stop-time with:
            // MILCompilerForANE ... "Couldn't communicate with a helper application".
            // CPU-only is slower but significantly more reliable for completion.
            preferredCompute = ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuOnly,
                textDecoderCompute: .cpuOnly
            )
        }

        do {
            return try await WhisperKit(
                modelFolder: modelFolder,
                computeOptions: preferredCompute,
                verbose: false
            )
        } catch {
            let fallbackCompute = ModelComputeOptions(
                melCompute: .cpuOnly,
                audioEncoderCompute: .cpuOnly,
                textDecoderCompute: .cpuOnly
            )
            return try await WhisperKit(
                modelFolder: modelFolder,
                computeOptions: fallbackCompute,
                verbose: false
            )
        }
    }

    private func updateDownloadState(fraction: Double, downloadedBytes: Int64, totalBytes: Int64) {
        let clamped = max(0, min(1, fraction.isFinite ? fraction : 0))
        modelState = .downloading(
            DownloadStatus(
                progress: clamped,
                downloadedBytes: max(0, downloadedBytes),
                totalBytes: max(0, totalBytes)
            )
        )
    }

    // MARK: - Step 2: Mic capture

    func requestMicPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Prepares the audio route/session once so the first user tap doesn't pay
    /// the full activation cost on the main interaction path.
    func prewarmRecordingPathIfNeeded() {
        guard !didPrewarmRecordingPath else { return }
        guard case .ready = modelState else { return }
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
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

    /// Best-effort warmup for the Tiny live decoder to reduce the first partial decode cost.
    func prewarmLiveDecodeIfNeeded() {
        guard !didPrewarmLiveDecode else { return }
        guard let liveWhisperKit else { return }
        didPrewarmLiveDecode = true

        Task(priority: .utility) {
            do {
                var options = DecodingOptions()
                options.language = SupportedLanguage.english.rawValue
                options.detectLanguage = false
                let silentAudio = Array(repeating: Float.zero, count: Int(targetSampleRate * 0.5))
                _ = try await liveWhisperKit.transcribe(audioArray: silentAudio, decodeOptions: options)
#if DEBUG
                print("[LIVE_DEBUG][SpeechToTextManager] prewarm_live_decode_ready")
#endif
            } catch {
#if DEBUG
                print("[LIVE_DEBUG][SpeechToTextManager] prewarm_live_decode_failed error=\"\(error.localizedDescription)\"")
#endif
            }
        }
    }

    func startListening(
        autoStopOnSilence: Bool = false,
        silenceDuration: TimeInterval = 1.0,
        silenceThreshold: Float = 0.003
    ) throws {
        guard case .ready = modelState else { throw STTError.notReady }

        self.autoStopOnSilence = autoStopOnSilence
        requiredSilenceDuration = silenceDuration
        self.silenceThreshold = silenceThreshold
        accumulatedSilenceDuration = 0
        accumulatedRecordingDuration = 0
        hasTriggeredAutoStop = false
        liveLockedLanguage = nil
        pendingLiveLockLanguage = nil
        pendingLiveLockConfirmations = 0
        lastLiveResolvedLanguage = nil
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
            try? AVAudioSession.sharedInstance().setActive(false)
            throw STTError.audioSessionFailure
        }
        isListening = true
    }

    func stopListening() {
        if hasInputTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTapInstalled = false
        }
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isListening = false

        onAudioLevelChange?(0)
        accumulatedSilenceDuration = 0
        accumulatedRecordingDuration = 0
        hasTriggeredAutoStop = false
        Task(priority: .utility) { [liveDecodeCoordinator] in
            await liveDecodeCoordinator.reset()
        }
    }

    // MARK: - Step 3: Transcription

    /// Stops listening (if active) and returns transcript text plus language used.
    /// In live-streaming mode, this final decode is performed with the Small model
    /// for higher post-recording accuracy.
    func transcribe(preferredLanguage: SupportedLanguage? = nil) async throws -> (text: String, language: SupportedLanguage) {
#if DEBUG
        print("[LIVE_DEBUG][SpeechToTextManager] final_decode_phase start")
#endif
        if isListening { stopListening() }

        let audio = snapshotAudioBuffer()
        guard !audio.isEmpty else { throw STTError.emptyRecording }

        let startedAt = Date()
#if DEBUG
        print("[LIVE_DEBUG][SpeechToTextManager] final_decode_phase ensure_model_start")
#endif
        let (transcriptionWhisperKit, modelVariantUsed, shouldReleaseAfterDecode) = try await finalTranscriptionWhisperKit()
#if DEBUG
        print("[LIVE_DEBUG][SpeechToTextManager] final_decode_phase model_ready model=\(modelVariantUsed.modelName)")
#endif
        defer {
            if shouldReleaseAfterDecode {
                finalWhisperKit = nil
            }
        }

        let resolvedLanguage: SupportedLanguage
        if let preferredLanguage {
            resolvedLanguage = preferredLanguage
        } else {
            resolvedLanguage = try await detectSupportedLanguage(audio: audio, using: transcriptionWhisperKit)
        }
        logDetectedLanguage(stage: "final_transcribe", language: resolvedLanguage)

        var options = DecodingOptions()
        options.language = resolvedLanguage.rawValue
        options.detectLanguage = false

#if DEBUG
        print("[LIVE_DEBUG][SpeechToTextManager] final_decode_phase decode_start lang=\(resolvedLanguage.rawValue)")
#endif
        let results = try await transcriptionWhisperKit.transcribe(audioArray: audio, decodeOptions: options)
        guard !results.isEmpty else { throw STTError.emptyRecording }

        // WhisperKit may return multiple chunk-level results for longer recordings.
        // Combine all chunk texts to avoid dropping earlier parts of the recording.
        let text = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
#if DEBUG
        print(
            "[LIVE_DEBUG][SpeechToTextManager] final_decode model=\(modelVariantUsed.modelName) audio_s=\(String(format: "%.2f", Double(audio.count) / targetSampleRate)) latency_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))"
        )
#endif
        return (text, resolvedLanguage)
    }

    /// Lightweight partial transcription for live preview while recording.
    /// Uses a short rolling audio window to keep decoding fast.
    func transcribePartialCurrentBuffer(
        preferredLanguage: SupportedLanguage? = nil,
        maxAudioSeconds: Double = 8.0,
        minimumAudioSeconds: Double = 0.8
    ) async throws -> LivePartialResult? {
        guard let liveWhisperKit else { throw STTError.notReady }
        guard await beginLivePartialDecodeIfPossible() else {
#if DEBUG
            print("[LIVE_DEBUG][SpeechToTextManager] partial_decode_skip reason=busy")
#endif
            return nil
        }
        defer {
            Task(priority: .utility) { [liveDecodeCoordinator] in
                await liveDecodeCoordinator.end()
            }
        }

        let decodeStartedAt = Date()
        let fullAudio = snapshotAudioBuffer()
        let minimumSamples = Int(targetSampleRate * max(0.2, minimumAudioSeconds))
        guard fullAudio.count >= minimumSamples else { return nil }

        let audioWindow = recentAudioWindow(fullAudio, maxSeconds: maxAudioSeconds)
        let windowStartSample = max(0, fullAudio.count - audioWindow.count)
        let windowStartTime = TimeInterval(windowStartSample) / targetSampleRate
        let windowEndTime = TimeInterval(fullAudio.count) / targetSampleRate
        let resolvedLanguage: SupportedLanguage
        if let preferredLanguage {
            resolvedLanguage = preferredLanguage
        } else if let liveLockedLanguage {
            resolvedLanguage = liveLockedLanguage
            logDetectedLanguage(stage: "live_locked_reuse", language: resolvedLanguage)
        } else {
            let languageLockSamples = Int(targetSampleRate * max(1.0, liveLanguageLockMinimumSeconds))
            if fullAudio.count >= languageLockSamples {
                let languageWindow = recentAudioWindow(fullAudio, maxSeconds: liveLanguageLockMinimumSeconds + 1.0)
                // Keep live-language detection on the Tiny engine so we don't contend
                // with stop-time Small finalization on the same model instance.
                if let detectedLanguage = try await detectSupportedLanguageForLiveLock(audio: languageWindow, using: liveWhisperKit) {
                    if pendingLiveLockLanguage == detectedLanguage {
                        pendingLiveLockConfirmations += 1
                    } else {
                        pendingLiveLockLanguage = detectedLanguage
                        pendingLiveLockConfirmations = 1
                    }

                    if pendingLiveLockConfirmations >= liveLanguageLockConfirmationsRequired {
                        liveLockedLanguage = detectedLanguage
                        resolvedLanguage = detectedLanguage
                        logDetectedLanguage(stage: "live_lock_from_small", language: detectedLanguage)
                    } else {
                        resolvedLanguage = preferredDeviceSupportedLanguage() ?? .english
                        logDetectedLanguage(stage: "live_lock_waiting_confirmation", language: resolvedLanguage)
                    }
                } else {
                    // Keep candidate state across occasional weak ticks instead of
                    // resetting instantly; this helps lock language in noisy input.
                    pendingLiveLockConfirmations = max(0, pendingLiveLockConfirmations - 1)
                    resolvedLanguage = preferredDeviceSupportedLanguage() ?? .english
                    logDetectedLanguage(stage: "live_lock_deferred_device_prior", language: resolvedLanguage)
                }
            } else {
                // Before small model locks language, use device preference as a temporary prior.
                resolvedLanguage = preferredDeviceSupportedLanguage() ?? .english
                logDetectedLanguage(stage: "live_temporary_device_prior", language: resolvedLanguage)
            }
        }

        var options = DecodingOptions()
        options.language = resolvedLanguage.rawValue
        options.detectLanguage = false

#if DEBUG
        print(
            "[LIVE_DEBUG][SpeechToTextManager] partial_decode_start full_audio_s=\(String(format: "%.2f", Double(fullAudio.count) / targetSampleRate)) window_s=\(String(format: "%.2f", Double(audioWindow.count) / targetSampleRate)) lang=\(resolvedLanguage.rawValue)"
        )
#endif
        let results = try await liveWhisperKit.transcribe(audioArray: audioWindow, decodeOptions: options)
        guard !results.isEmpty else { return nil }

        // For longer/complex windows WhisperKit can return multiple chunk results.
        // Combine all chunk texts to avoid dropping live content.
        let text = results
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var segments: [LiveTranscriptSegment] = results.flatMap { result in
            result.segments.compactMap { segment -> LiveTranscriptSegment? in
                let trimmedText = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedText.isEmpty else { return nil }
                let absoluteStart = windowStartTime + TimeInterval(segment.start)
                let absoluteEnd = windowStartTime + TimeInterval(segment.end)
                guard absoluteEnd > absoluteStart else { return nil }
                return LiveTranscriptSegment(
                    startTime: absoluteStart,
                    endTime: absoluteEnd,
                    text: trimmedText
                )
            }
        }
        if segments.isEmpty {
            segments = [
                LiveTranscriptSegment(
                    startTime: windowStartTime,
                    endTime: windowEndTime,
                    text: text
                )
            ]
        } else {
            segments.sort {
                if $0.startTime == $1.startTime { return $0.endTime < $1.endTime }
                return $0.startTime < $1.startTime
            }
        }
        await liveDecodeCoordinator.markTextEmitted()
        lastLiveResolvedLanguage = resolvedLanguage
#if DEBUG
        print(
            "[LIVE_DEBUG][SpeechToTextManager] partial_decode_done latency_ms=\(Int(Date().timeIntervalSince(decodeStartedAt) * 1000)) text_chars=\(text.count) segments=\(segments.count)"
        )
#endif
        return LivePartialResult(
            text: text,
            language: resolvedLanguage,
            windowStartTime: windowStartTime,
            windowEndTime: windowEndTime,
            segments: segments
        )
    }

    private func beginLivePartialDecodeIfPossible() async -> Bool {
        await liveDecodeCoordinator.tryBegin(now: Date())
    }

    private func snapshotAudioBuffer() -> [Float] {
        bufferLock.withLock {
            sampleBuffer
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

    /// Runs Whisper's language-ID pass and picks the best match restricted to
    /// `SupportedLanguage.allCases`, instead of accepting whatever it names freely.
    private func detectSupportedLanguage(audio: [Float], using whisperKit: WhisperKit) async throws -> SupportedLanguage {
        let probabilities = try await stableSupportedLanguageProbabilities(audio: audio, using: whisperKit)
        let sorted = probabilities.sorted { $0.value > $1.value }
        let top = sorted.first
        let second = sorted.dropFirst().first
        let topConfidence = top?.value ?? 0
        let margin = topConfidence - (second?.value ?? 0)

        // Use device language as a soft prior only when language-ID is ambiguous.
        if let deviceLanguage = preferredDeviceSupportedLanguage(),
           let deviceConfidence = probabilities[deviceLanguage] {
            let weakPrediction = topConfidence < 0.45 || margin < 0.12
            if weakPrediction, deviceConfidence >= topConfidence * 0.7 {
                return deviceLanguage
            }
        }

        // Fallback: if language ID genuinely returned nothing for our set
        // (e.g. silence), default to the first supported language rather than crash.
        return top?.key ?? preferredDeviceSupportedLanguage() ?? .english
    }

    /// Builds a more stable final language decision by averaging language-ID
    /// probabilities over multiple windows instead of trusting one pass.
    private func stableSupportedLanguageProbabilities(
        audio: [Float],
        using whisperKit: WhisperKit
    ) async throws -> [SupportedLanguage: Double] {
        let minimumWindowSamples = Int(targetSampleRate * 1.2)
        guard audio.count >= minimumWindowSamples else {
            return try await supportedLanguageProbabilities(audio: audio, using: whisperKit)
        }

        let fullWindow = recentAudioWindow(audio, maxSeconds: 30)
        let tailWindow = recentAudioWindow(audio, maxSeconds: 10)
        let headWindow: [Float] = {
            let maxHeadSamples = Int(targetSampleRate * 10)
            if audio.count <= maxHeadSamples { return audio }
            return Array(audio.prefix(maxHeadSamples))
        }()

        let weightedWindows: [(samples: [Float], weight: Double)] = [
            (fullWindow, 0.35),
            (tailWindow, 0.45),
            (headWindow, 0.20)
        ]

        var aggregate: [SupportedLanguage: Double] = [:]
        var totalWeight: Double = 0
        for (samples, weight) in weightedWindows where samples.count >= minimumWindowSamples {
            let probabilities = try await supportedLanguageProbabilities(audio: samples, using: whisperKit)
            for language in SupportedLanguage.allCases {
                aggregate[language, default: 0] += (probabilities[language] ?? 0) * weight
            }
            totalWeight += weight
        }

        guard totalWeight > 0 else {
            return try await supportedLanguageProbabilities(audio: audio, using: whisperKit)
        }

        var normalized: [SupportedLanguage: Double] = [:]
        for language in SupportedLanguage.allCases {
            normalized[language] = (aggregate[language] ?? 0) / totalWeight
        }
        return normalized
    }

    private func detectSupportedLanguageForLiveLock(audio: [Float], using whisperKit: WhisperKit) async throws -> SupportedLanguage? {
        let probabilities = try await supportedLanguageProbabilities(audio: audio, using: whisperKit)
        let sorted = probabilities.sorted { $0.value > $1.value }
        guard let top = sorted.first else { return nil }
        let second = sorted.dropFirst().first?.value ?? 0
        let confidence = top.value
        let margin = confidence - second

        // Be stricter before locking language for the session.
        let minConfidenceToLock: Double = 0.45
        let minMarginToLock: Double = 0.08
        guard confidence >= minConfidenceToLock, margin >= minMarginToLock else {
            return nil
        }
        return top.key
    }

    private func supportedLanguageProbabilities(audio: [Float], using whisperKit: WhisperKit) async throws -> [SupportedLanguage: Double] {
        let (_, langProbs) = try await whisperKit.detectLangauge(audioArray: audio)
        var probabilities: [SupportedLanguage: Double] = [:]
        for language in SupportedLanguage.allCases {
            probabilities[language] = Double(langProbs[language.rawValue] ?? 0)
        }
        return probabilities
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

    private var activeModelVariant: ModelVariant {
        switch operationMode {
        case .liveStreaming:
            return .tiny
        case .postRecording:
            return .small
        }
    }

    private var isActiveModelLoaded: Bool {
        switch operationMode {
        case .liveStreaming:
            return liveWhisperKit != nil
        case .postRecording:
            return finalWhisperKit != nil
        }
    }

    private var activeTranscriptionWhisperKit: WhisperKit? {
        switch operationMode {
        case .liveStreaming:
            return liveWhisperKit
        case .postRecording:
            return finalWhisperKit
        }
    }

    private func finalTranscriptionWhisperKit() async throws -> (whisper: WhisperKit, model: ModelVariant, releaseAfterDecode: Bool) {
        switch operationMode {
        case .liveStreaming:
            let small = try await ensureModelLoaded(for: .small)
            // Keep Small cached after first load to avoid stop-time hangs on subsequent sessions.
            return (small, .small, false)
        case .postRecording:
            let small = try await ensureModelLoaded(for: .small)
            return (small, .small, false)
        }
    }

    private func ensureModelLoaded(for variant: ModelVariant) async throws -> WhisperKit {
        switch variant {
        case .tiny:
            if let liveWhisperKit { return liveWhisperKit }
        case .small:
            if let finalWhisperKit { return finalWhisperKit }
        }

        let modelFolder: URL
        if let installed = installedModelFolderURL(for: variant) {
            modelFolder = installed
        } else if Self.modelSource == .bundled {
            guard let sourceFolder = bundledModelURL(for: variant) else {
                throw STTError.notReady
            }
            modelFolder = try prepareBundledModelFolder(for: variant, sourceFolder: sourceFolder)
        } else {
            modelFolder = try await downloadFromCDN(variant: variant)
        }

        try await loadModel(variant: variant, from: modelFolder)

        switch variant {
        case .tiny:
            guard let liveWhisperKit else { throw STTError.notReady }
            return liveWhisperKit
        case .small:
            guard let finalWhisperKit else { throw STTError.notReady }
            return finalWhisperKit
        }
    }

    /// Best-effort background warmup to reduce first stop-time latency in live mode.
    func prewarmSmallFinalModelIfNeeded() {
        if isLiveTranscriptionEnabled {
#if DEBUG
            print("[LIVE_DEBUG][SpeechToTextManager] prewarm_small_skipped reason=live_mode_on")
#endif
            return
        }
        guard !isPrewarmingSmallModel, finalWhisperKit == nil else { return }
        isPrewarmingSmallModel = true
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { self.isPrewarmingSmallModel = false }
            do {
                _ = try await self.ensureModelLoaded(for: .small)
#if DEBUG
                print("[LIVE_DEBUG][SpeechToTextManager] prewarm_small_ready")
#endif
            } catch {
#if DEBUG
                print("[LIVE_DEBUG][SpeechToTextManager] prewarm_small_failed error=\"\(error.localizedDescription)\"")
#endif
            }
        }
    }

    private func loadModel(variant: ModelVariant, from folder: URL) async throws {
        switch variant {
        case .tiny:
            liveWhisperKit = try await createWhisperKit(
                modelFolder: folder.path,
                profile: .liveTinyFast
            )
        case .small:
            finalWhisperKit = try await createWhisperKit(
                modelFolder: folder.path,
                profile: .finalSmallBalanced
            )
        }
    }

    private func logDetectedLanguage(stage: String, language: SupportedLanguage) {
        _ = stage
        _ = language
    }
}
