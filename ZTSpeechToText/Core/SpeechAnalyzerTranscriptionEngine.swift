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
        try await ensureSpeechAuthorization()

        let locale = try await resolveLocale(localeHint: localeHint)
        let transcriber = SpeechTranscriber(locale: locale, preset: preset)
        try await ensureAssetsReady(for: transcriber, locale: locale)

        let fileURL = try writeAudioToTemporaryFile(audio: audio, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: fileURL)
        let resultsTask = Task<String, Error> {
            var latestText = ""
            var cumulativeText = ""
            for try await result in transcriber.results {
                let candidate = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    latestText = candidate
                    if cumulativeText.isEmpty {
                        cumulativeText = candidate
                    } else if candidate == cumulativeText || cumulativeText.hasSuffix(candidate) {
                        continue
                    } else if candidate.hasPrefix(cumulativeText) {
                        cumulativeText = candidate
                    } else if cumulativeText.hasPrefix(candidate) {
                        continue
                    } else {
                        cumulativeText = stitch(left: cumulativeText, right: candidate)
                    }
                }
            }
            return cumulativeText.isEmpty ? latestText : cumulativeText
        }

        let lastSampleTime = try await analyzer.analyzeSequence(from: file)
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let text = try await resultsTask.value
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
        // Avoid supportedLocale(equivalentTo:) due runtime traps seen on some
        // iOS 26 builds. Choose locale from hint/current and then supported list.
        if let localeHint {
            return localeHint
        }

        let supportedLocales = await SpeechTranscriber.supportedLocales
        if supportedLocales.isEmpty {
            throw EngineError.unsupportedLocale
        }

        let current = Locale.current
        if let exact = supportedLocales.first(where: { $0.identifier == current.identifier }) {
            return exact
        }

        if let currentLanguage = current.language.languageCode?.identifier,
           let byLanguage = supportedLocales.first(where: {
               $0.language.languageCode?.identifier == currentLanguage
           }) {
            return byLanguage
        }

        return supportedLocales[0]
    }

    private func ensureAssetsReady(for transcriber: SpeechTranscriber, locale: Locale) async throws {
        if await Self.assetPreparationState.isPrepared(locale: locale) {
            return
        }
        try await reserveLocaleForAssets(locale)

        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installationRequest.downloadAndInstall()
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
                _ = try await AssetInventory.reserve(locale: candidate)
                return
            } catch {
                lastError = error
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

    private func stitch(left: String, right: String) -> String {
        let base = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let extra = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.isEmpty else { return base }
        guard !base.isEmpty else { return extra }

        if base == extra { return base }
        if base.hasSuffix(extra) { return base }
        if extra.hasPrefix(base) { return extra }

        let baseWords = base.split(whereSeparator: \.isWhitespace).map(String.init)
        let extraWords = extra.split(whereSeparator: \.isWhitespace).map(String.init)
        let maxOverlap = min(16, min(baseWords.count, extraWords.count))

        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                let baseTail = baseWords.suffix(overlap).map(normalizeWord)
                let extraHead = extraWords.prefix(overlap).map(normalizeWord)
                if baseTail == extraHead {
                    let suffix = extraWords.dropFirst(overlap).joined(separator: " ")
                    guard !suffix.isEmpty else { return base }
                    return base + " " + suffix
                }
            }
        }

        return base + " " + extra
    }

    private func normalizeWord(_ value: String) -> String {
        value
            .trimmingCharacters(in: .punctuationCharacters)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
    }
}
