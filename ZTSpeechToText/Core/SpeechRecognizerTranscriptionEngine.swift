import Foundation
import AVFoundation
import Speech

struct SpeechRecognizerTranscriptionOutput {
    let text: String
    let locale: Locale
}

final class SpeechRecognizerTranscriptionEngine {
    enum EngineError: LocalizedError {
        case authorizationDenied
        case unavailableRecognizer
        case simulatorNotSupported
        case unsupportedLocale
        case emptyAudio
        case noRecognitionResult

        var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                return "Speech recognition authorization denied."
            case .unavailableRecognizer:
                return "Speech recognizer is currently unavailable."
            case .simulatorNotSupported:
                return "Apple SpeechRecognizer live transcription is unavailable on Simulator. Use a physical device."
            case .unsupportedLocale:
                return "No supported speech recognizer locale found."
            case .emptyAudio:
                return "No audio available for transcription."
            case .noRecognitionResult:
                return "Speech recognizer produced no result."
            }
        }
    }

    func transcribe(
        audio: [Float],
        sampleRate: Double,
        localeHint: Locale?,
        timeoutInterval: TimeInterval? = 8.0
    ) async throws -> SpeechRecognizerTranscriptionOutput {
#if targetEnvironment(simulator)
        throw EngineError.simulatorNotSupported
#else
        guard !audio.isEmpty else { throw EngineError.emptyAudio }
        try await ensureSpeechAuthorization()

        let locale = try resolveLocale(localeHint: localeHint)
        STTSessionLogger.shared.log(
            source: "SpeechRecognizerEngine",
            message: "transcribe begin locale=\(locale.identifier) audio_s=\(String(format: "%.2f", Double(audio.count) / sampleRate)) timeout_s=\(timeoutInterval ?? -1)"
        )
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            STTSessionLogger.shared.log(source: "SpeechRecognizerEngine", message: "transcribe fail reason=recognizer_unavailable locale=\(locale.identifier)")
            throw EngineError.unavailableRecognizer
        }

        let fileURL = try writeAudioToTemporaryFile(audio: audio, sampleRate: sampleRate)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let maxAttempts = (timeoutInterval == nil) ? 3 : 2
        var attempt = 0
        while true {
            do {
                return try await transcribeOnce(
                    recognizer: recognizer,
                    fileURL: fileURL,
                    locale: locale,
                    timeoutInterval: timeoutInterval
                )
            } catch {
                attempt += 1
                guard attempt < maxAttempts, shouldRetryRecognition(error) else {
                    throw error
                }
                try? await Task.sleep(nanoseconds: 450_000_000)
            }
        }
#endif
    }

    private func transcribeOnce(
        recognizer: SFSpeechRecognizer,
        fileURL: URL,
        locale: Locale,
        timeoutInterval: TimeInterval?
    ) async throws -> SpeechRecognizerTranscriptionOutput {
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.addsPunctuation = true

        return try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            var task: SFSpeechRecognitionTask?

            func finish(_ body: () -> Void) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                body()
            }

            task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    if result.isFinal {
                        finish {
                            task?.cancel()
                            if text.isEmpty {
                                STTSessionLogger.shared.log(source: "SpeechRecognizerEngine", message: "transcribe fail reason=no_final_text locale=\(locale.identifier)")
                                continuation.resume(throwing: EngineError.noRecognitionResult)
                            } else {
                                STTSessionLogger.shared.log(source: "SpeechRecognizerEngine", message: "transcribe ok locale=\(locale.identifier) chars=\(text.count)")
                                continuation.resume(returning: SpeechRecognizerTranscriptionOutput(text: text, locale: locale))
                            }
                        }
                    }
                    return
                }

                if let error {
                    finish {
                        task?.cancel()
                        let mapped = self.mapRecognitionError(error)
                        STTSessionLogger.shared.log(
                            source: "SpeechRecognizerEngine",
                            message: "transcribe fail locale=\(locale.identifier) raw=\(error.localizedDescription) mapped=\((mapped as NSError).localizedDescription)"
                        )
                        continuation.resume(throwing: mapped)
                    }
                }
            }

            if let timeoutInterval, timeoutInterval > 0 {
                // Prevent long-running recognizer passes from stalling live UI updates.
                Task(priority: .utility) {
                    try? await Task.sleep(nanoseconds: UInt64(timeoutInterval * 1_000_000_000))
                    finish {
                        task?.cancel()
                        let timeoutError = NSError(
                            domain: "SpeechRecognizerTranscriptionEngine",
                            code: -1001,
                            userInfo: [NSLocalizedDescriptionKey: "Speech recognizer request timed out."]
                        )
                        STTSessionLogger.shared.log(source: "SpeechRecognizerEngine", message: "transcribe fail reason=timeout locale=\(locale.identifier)")
                        continuation.resume(throwing: timeoutError)
                    }
                }
            }
        }
    }

    private func shouldRetryRecognition(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" {
            if nsError.code == 203 || nsError.code == 209 || nsError.code == 1101 || nsError.code == 1 {
                return true
            }
        }
        let message = error.localizedDescription.lowercased()
        return message == "retry"
            || message.contains("speech recognizer is currently unavailable")
    }

    private func mapRecognitionError(_ error: Error) -> Error {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" {
            if nsError.code == 203 || nsError.code == 209 || nsError.code == 1101 || nsError.code == 1 {
                return EngineError.unavailableRecognizer
            }
        }
        return error
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

    private func resolveLocale(localeHint: Locale?) throws -> Locale {
        let supported = SFSpeechRecognizer.supportedLocales()

        if let localeHint {
            if supported.contains(localeHint) { return localeHint }
            if let match = supported.first(where: { $0.identifier.lowercased().hasPrefix(localeHint.identifier.lowercased()) }) {
                return match
            }
            if let languageCode = localeHint.language.languageCode?.identifier.lowercased(),
               let match = supported.first(where: { $0.identifier.lowercased().hasPrefix(languageCode) }) {
                return match
            }
        }

        if let current = supported.first(where: { $0.identifier.lowercased() == Locale.current.identifier.lowercased() }) {
            return current
        }
        if let preferredLanguage = Locale.preferredLanguages.first?.lowercased(),
           let preferredMatch = supported.first(where: { preferredLanguage.hasPrefix($0.identifier.lowercased()) || $0.identifier.lowercased().hasPrefix(preferredLanguage.prefix(2)) }) {
            return preferredMatch
        }
        if let first = supported.first {
            return first
        }
        throw EngineError.unsupportedLocale
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
