import Foundation
import AVFoundation
import Speech

@available(iOS 26.0, *)
final class DictationTranscriberEngine: FinalTranscriptionEngine {
    let engineID = "dictationTranscriber"

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        guard !request.audio.isEmpty else { throw TranscriptionEngineError.emptyAudio }
        try await ensureSpeechAuthorization()

        let preferredLocale = request.localeHint ?? .current
        guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: preferredLocale) else {
            throw TranscriptionEngineError.unsupportedLocale
        }

        let transcriber = DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
        try await prepareAssets(for: transcriber)

        let fileURL = try writeAudioToTemporaryFile(audio: request.audio, sampleRate: request.sampleRate)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: fileURL)

        let resultsTask = Task<String, Error> {
            var latest = ""
            for try await result in transcriber.results {
                let candidate = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                if !candidate.isEmpty {
                    latest = candidate
                }
            }
            return latest
        }

        let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile)
        if let lastSampleTime {
            try await analyzer.finalizeAndFinish(through: lastSampleTime)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let text = try await resultsTask.value
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw TranscriptionEngineError.noFinalText }
        return TranscriptionResult(text: normalized, locale: locale)
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
            throw TranscriptionEngineError.authorizationDenied
        }
    }

    private func prepareAssets(for transcriber: DictationTranscriber) async throws {
        if let installationRequest = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installationRequest.downloadAndInstall()
        }
    }

    private func writeAudioToTemporaryFile(audio: [Float], sampleRate: Double) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionEngineError.emptyAudio
        }

        let frameCount = AVAudioFrameCount(audio.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscriptionEngineError.emptyAudio
        }
        buffer.frameLength = frameCount
        buffer.floatChannelData?.pointee.update(from: audio, count: audio.count)

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
