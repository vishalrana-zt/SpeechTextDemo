import Foundation
import Speech

@available(iOS 26.0, *)
final class SpeechTranscriberEngine: FinalTranscriptionEngine {
    let engineID = "speechTranscriber"

    private let analyzerEngine = SpeechAnalyzerTranscriptionEngine()

    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptionResult {
        do {
            let output = try await analyzerEngine.transcribe(
                audio: request.audio,
                sampleRate: request.sampleRate,
                localeHint: request.localeHint,
                preset: .transcription
            )
            return TranscriptionResult(text: output.text, locale: output.locale)
        } catch let error as SpeechAnalyzerTranscriptionEngine.EngineError {
            throw mapEngineError(error)
        } catch {
            throw TranscriptionEngineError.transcriptionFailed(underlying: error)
        }
    }

    private func mapEngineError(_ error: SpeechAnalyzerTranscriptionEngine.EngineError) -> TranscriptionEngineError {
        switch error {
        case .authorizationDenied:
            return .authorizationDenied
        case .unsupportedLocale:
            return .unsupportedLocale
        case .emptyAudio:
            return .emptyAudio
        }
    }
}
