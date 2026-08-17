import Foundation
import AVFoundation
import Speech

@available(iOS 26.0, *)
struct SpeechAnalyzerTranscriptionOutput {
    let text: String
    let locale: Locale
}

@available(iOS 26.0, *)
final class SpeechAnalyzerTranscriptionEngine {
    private actor AssetPreparationState {
        private var preparedLocales: Set<String> = []

        func isPrepared(locale: Locale) -> Bool {
            preparedLocales.contains(locale.identifier)
        }

        func markPrepared(locale: Locale) {
            preparedLocales.insert(locale.identifier)
        }
    }

    private static let assetPreparationState = AssetPreparationState()

    enum EngineError: LocalizedError {
        case authorizationDenied
        case unsupportedLocale
        case emptyAudio

        var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                return "Speech recognition authorization denied."
            case .unsupportedLocale:
                return "No supported SpeechAnalyzer locale found."
            case .emptyAudio:
                return "No audio available for transcription."
            }
        }
    }

    func transcribe(
        audio: [Float],
        sampleRate: Double,
        localeHint: Locale?,
        preset: SpeechTranscriber.Preset
    ) async throws -> SpeechAnalyzerTranscriptionOutput {
        guard !audio.isEmpty else { throw EngineError.emptyAudio }
        let audioSeconds = Double(audio.count) / sampleRate
#if DEBUG
        print(
            "[LIVE_DEBUG][SpeechAnalyzer] transcribe_start preset=\(String(describing: preset)) localeHint=\(localeHint?.identifier ?? "auto") audio_s=\(String(format: "%.2f", audioSeconds))"
        )
#endif
        try await ensureSpeechAuthorization()

        let locale = try await resolveLocale(localeHint: localeHint)
#if DEBUG
        print("[LIVE_DEBUG][SpeechAnalyzer] locale_resolved locale=\(locale.identifier)")
#endif
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)
        try await ensureAssetsReady(for: transcriber, locale: locale)

        let fileURL = try writeAudioToTemporaryFile(audio: audio, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: fileURL)
        let resultsTask = Task<String, Error> {
            var latestText = ""
            for try await result in transcriber.results {
                let candidate = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    latestText = candidate
                }
            }
            return latestText
        }

        let lastSampleTime = try await analyzer.analyzeSequence(from: file)
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let text = try await resultsTask.value
#if DEBUG
        print("[LIVE_DEBUG][SpeechAnalyzer] transcribe_done locale=\(locale.identifier) text_chars=\(text.count)")
#endif
        return SpeechAnalyzerTranscriptionOutput(text: text, locale: locale)
    }

    func prepare(
        localeHint: Locale?,
        preset: SpeechTranscriber.Preset
    ) async throws {
        try await ensureSpeechAuthorization()
        let locale = try await resolveLocale(localeHint: localeHint)
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)
        try await ensureAssetsReady(for: transcriber, locale: locale)
    }

    private func ensureSpeechAuthorization() async throws {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        if currentStatus == .authorized { return }

        let resolvedStatus: SFSpeechRecognizerAuthorizationStatus
        if currentStatus == .notDetermined {
            resolvedStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            resolvedStatus = currentStatus
        }

        guard resolvedStatus == .authorized else {
            throw EngineError.authorizationDenied
        }
    }

    private func resolveLocale(localeHint: Locale?) async throws -> Locale {
        if let localeHint,
           let supported = await SpeechTranscriber.supportedLocale(equivalentTo: localeHint) {
            return supported
        }

        if let current = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return current
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        if let first = supportedLocales.first {
            return first
        }

        throw EngineError.unsupportedLocale
    }

    private func ensureAssetsReady(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        if await Self.assetPreparationState.isPrepared(locale: locale) {
            return
        }
        try await reserveLocaleForAssets(locale)

        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
#if DEBUG
            print("[LIVE_DEBUG][SpeechAnalyzer] asset_installation_start locale=\(locale.identifier)")
#endif
            try await installationRequest.downloadAndInstall()
#if DEBUG
            print("[LIVE_DEBUG][SpeechAnalyzer] asset_installation_done locale=\(locale.identifier)")
#endif
        }

        await Self.assetPreparationState.markPrepared(locale: locale)
    }

    private func reserveLocaleForAssets(_ locale: Locale) async throws {
        var candidates: [Locale] = [locale]
        if let languageCode = locale.language.languageCode?.identifier {
            let languageOnlyLocale = Locale(identifier: languageCode)
            if languageOnlyLocale.identifier != locale.identifier {
                candidates.append(languageOnlyLocale)
            }
        }

        var lastError: Error?
        for candidate in candidates {
            do {
#if DEBUG
                print("[LIVE_DEBUG][SpeechAnalyzer] reserve_locale_start locale=\(candidate.identifier)")
#endif
                _ = try await AssetInventory.reserve(locale: candidate)
#if DEBUG
                print("[LIVE_DEBUG][SpeechAnalyzer] reserve_locale_done locale=\(candidate.identifier)")
#endif
                return
            } catch {
                lastError = error
#if DEBUG
                print("[LIVE_DEBUG][SpeechAnalyzer] reserve_locale_failed locale=\(candidate.identifier) error=\"\(error.localizedDescription)\"")
#endif
            }
        }

        if let lastError {
            throw lastError
        }
    }

    private func writeAudioToTemporaryFile(audio: [Float], sampleRate: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
        guard let format else { throw EngineError.emptyAudio }

        let frameCount = AVAudioFrameCount(audio.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw EngineError.emptyAudio
        }
        buffer.frameLength = frameCount
        buffer.floatChannelData?.pointee.update(from: audio, count: audio.count)

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
