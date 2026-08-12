//
//  SpeechToTextManager.swift
//  Offline, on-device speech-to-text with automatic language detection.
//
//  Requires: WhisperKit (https://github.com/argmaxinc/WhisperKit) added via SPM.
//  Package URL: https://github.com/argmaxinc/WhisperKit
//

import Foundation
import AVFoundation
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
        case french  = "fr-CA"

        var displayName: String {
            switch self {
            case .english: return "English"
            case .spanish: return "Spanish"
            case .french:  return "French (Canada)"
            }
        }
    }

    struct DownloadStatus: Equatable {
        let progress: Double
        let downloadedBytes: Int64
        let totalBytes: Int64
    }

    enum ModelState: Equatable {
        case notDownloaded
        case downloading(DownloadStatus)
        case loadingModel
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

    private var whisperKit: WhisperKit?
    private let audioEngine = AVAudioEngine()
    private var sampleBuffer: [Float] = []
    private let targetSampleRate: Double = 16_000
    private let bufferLock = NSLock()

    private var autoStopOnSilence = false
    private var requiredSilenceDuration: TimeInterval = 1.0
    private var silenceThreshold: Float = 0.003
    private var accumulatedSilenceDuration: TimeInterval = 0
    private var accumulatedRecordingDuration: TimeInterval = 0
    private var hasTriggeredAutoStop = false
    private let maxRecordingDuration: TimeInterval = 10 * 60

    var onSilenceAutoStopTriggered: (() -> Void)?
    var onAudioLevelChange: ((Float) -> Void)?

    private static let modelReadyKey = "SpeechToTextManager.modelReady"
    private static let optedInKey = "SpeechToTextManager.optedIn"
    private static let liveTranscriptionEnabledKey = "SpeechToTextManager.liveTranscriptionEnabled"
    private static let modelName = "openai_whisper-large-v3-v20240930_626MB"
    private static let modelRepo = "argmaxinc/whisperkit-coreml"
    
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

    private static let modelSource: ModelSource = .cdn
    private let cdnDownloader = CDNModelDownloader()

    var isBundledModelSource: Bool {
        Self.modelSource == .bundled
    }
    
    // Safe to call again on relaunch if a previous download was interrupted —
    // the underlying downloader resumes partial files rather than restarting.

    func prepareOnOptIn() async {
        UserDefaults.standard.set(true, forKey: Self.optedInKey)

        if whisperKit != nil {
            modelState = .ready
            return
        }

        if let existingModelFolder = installedModelFolderURL() {
            do {
                modelState = .loadingModel
                whisperKit = try await WhisperKit(modelFolder: existingModelFolder.path)
                modelState = .ready
                return
            } catch {
                // Fall through and attempt fresh preparation/download.
            }
        }
        
        if Self.modelSource == .bundled {
            await loadBundledModel()
            return
        }

        modelState = .downloading(DownloadStatus(progress: 0, downloadedBytes: 0, totalBytes: 0))

        do {
            let modelFolder: URL
            if Self.modelSource == .cdn {
                modelFolder = try await cdnDownloader.downloadAndUnzip { [weak self] transfer in
                    self?.updateDownloadState(
                        fraction: transfer.fraction,
                        downloadedBytes: transfer.downloadedBytes,
                        totalBytes: transfer.totalBytes
                    )
                }
            } else  {
                modelFolder = try await WhisperKit.download(
                    variant: Self.modelName,
                    from: Self.modelRepo,
                    progressCallback: { [weak self] progress in
                        DispatchQueue.main.async {
                            self?.updateDownloadState(
                                fraction: progress.fractionCompleted,
                                downloadedBytes: 0,
                                totalBytes: 0
                            )
                        }
                    }
                )
            }
            modelState = .loadingModel
            whisperKit = try await WhisperKit(modelFolder: modelFolder.path)
            UserDefaults.standard.set(true, forKey: Self.modelReadyKey)
            modelState = .ready
        } catch is CancellationError {
            modelState = .failed("Download cancelled. Tap Retry to resume.")
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }
    
    private func loadBundledModel() async {
        guard let modelURL = bundledModelURL() else {
            modelState = .failed("Bundled model '\(Self.modelName)' not found in app bundle")
            return
        }

        do {
            modelState = .loadingModel
            whisperKit = try await WhisperKit(modelFolder: modelURL.path)
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
        }
    }

    private func bundledModelURL() -> URL? {
        let fileManager = FileManager.default

        let candidates: [URL?] = [
            Bundle.main.url(forResource: Self.modelName, withExtension: nil),
            Bundle.main.url(forResource: Self.modelName, withExtension: nil, subdirectory: "Resource"),
            Bundle.main.resourceURL?.appendingPathComponent(Self.modelName, isDirectory: true),
            Bundle.main.resourceURL?.appendingPathComponent("Resource", isDirectory: true)
                .appendingPathComponent(Self.modelName, isDirectory: true),
            Bundle.main.resourceURL
        ]

        for candidate in candidates.compactMap({ $0 }) {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }

            // Some project setups flatten resources into the app bundle root.
            let hasConfig = fileManager.fileExists(atPath: candidate.appendingPathComponent("config.json").path)
            let hasDecoder = fileManager.fileExists(atPath: candidate.appendingPathComponent("TextDecoder.mlmodelc").path)
            let hasEncoder = fileManager.fileExists(atPath: candidate.appendingPathComponent("AudioEncoder.mlmodelc").path)
            if hasConfig && hasDecoder && hasEncoder {
                return candidate
            }
        }

        return nil
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

    private func installedModelFolderURL() -> URL? {
        let fileManager = FileManager.default
        let destination = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeechModel", isDirectory: true)

        if isModelFolder(destination, fileManager: fileManager) {
            return destination
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        for child in children where isModelFolder(child, fileManager: fileManager) {
            return child
        }
        return nil
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

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
    }

    func stopListening() {
        guard isListening else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isListening = false

        onAudioLevelChange?(0)
        accumulatedSilenceDuration = 0
        accumulatedRecordingDuration = 0
        hasTriggeredAutoStop = false
    }

    // MARK: - Step 3: Transcription

    /// Stops listening (if active) and returns transcript text plus the language used.
    /// - Parameter preferredLanguage: If nil, language is auto-detected from audio.
    ///   If provided, transcription is forced to that language.
    func transcribe(preferredLanguage: SupportedLanguage? = nil) async throws -> (text: String, language: SupportedLanguage) {
        if isListening { stopListening() }
        guard let whisperKit else { throw STTError.notReady }

        let audio = snapshotAudioBuffer()

        guard !audio.isEmpty else { throw STTError.emptyRecording }

        let resolvedLanguage: SupportedLanguage
        if let preferredLanguage {
            resolvedLanguage = preferredLanguage
        } else {
            resolvedLanguage = try await detectSupportedLanguage(audio: audio, using: whisperKit)
        }

        var options = DecodingOptions()
        options.language = resolvedLanguage.rawValue
        options.detectLanguage = false

        let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: options)
        guard let first = results.first else { throw STTError.emptyRecording }

        let text = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, resolvedLanguage)
    }

    /// Lightweight partial transcription for live preview while recording.
    /// Uses a short rolling audio window to keep decoding fast.
    func transcribePartialCurrentBuffer(
        preferredLanguage: SupportedLanguage? = nil,
        maxAudioSeconds: Double = 8.0,
        minimumAudioSeconds: Double = 0.8
    ) async throws -> (text: String, language: SupportedLanguage)? {
        guard let whisperKit else { throw STTError.notReady }

        let fullAudio = snapshotAudioBuffer()
        let minimumSamples = Int(targetSampleRate * max(0.2, minimumAudioSeconds))
        guard fullAudio.count >= minimumSamples else { return nil }

        let audioWindow = recentAudioWindow(fullAudio, maxSeconds: maxAudioSeconds)
        let resolvedLanguage: SupportedLanguage
        if let preferredLanguage {
            resolvedLanguage = preferredLanguage
        } else {
            resolvedLanguage = try await detectSupportedLanguage(audio: audioWindow, using: whisperKit)
        }

        var options = DecodingOptions()
        options.language = resolvedLanguage.rawValue
        options.detectLanguage = false

        let results = try await whisperKit.transcribe(audioArray: audioWindow, decodeOptions: options)
        guard let first = results.first else { return nil }

        let text = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (text, resolvedLanguage)
    }

    private func snapshotAudioBuffer() -> [Float] {
        bufferLock.withLock {
            sampleBuffer
        }
    }

    private func recentAudioWindow(_ audio: [Float], maxSeconds: Double) -> [Float] {
        let maxSamples = Int(targetSampleRate * max(1.0, maxSeconds))
        guard audio.count > maxSamples else { return audio }
        return Array(audio.suffix(maxSamples))
    }

    /// Runs Whisper's language-ID pass and picks the best match restricted to
    /// `SupportedLanguage.allCases`, instead of accepting whatever it names freely.
    private func detectSupportedLanguage(audio: [Float], using whisperKit: WhisperKit) async throws -> SupportedLanguage {
        let (_, langProbs) = try await whisperKit.detectLangauge(audioArray: audio)

        let best = SupportedLanguage.allCases.max { a, b in
            (langProbs[a.rawValue] ?? 0) < (langProbs[b.rawValue] ?? 0)
        }

        // Fallback: if language ID genuinely returned nothing for our set
        // (e.g. silence), default to the first supported language rather than crash.
        return best ?? .english
    }
}
