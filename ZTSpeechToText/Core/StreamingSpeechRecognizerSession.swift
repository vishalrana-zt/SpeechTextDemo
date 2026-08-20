import Foundation
import AVFoundation
import Speech

final class StreamingSpeechRecognizerSession {
    struct LiveResult {
        let text: String
        let isFinal: Bool
        let locale: Locale
    }

    enum SessionError: LocalizedError {
        case authorizationDenied
        case recognizerUnavailable
        case noFinalText
        case timeout
        case cancelled

        var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                return "Speech recognition authorization denied."
            case .recognizerUnavailable:
                return "Speech recognizer is currently unavailable."
            case .noFinalText:
                return "Speech recognizer produced no final text."
            case .timeout:
                return "Speech recognizer finalization timed out."
            case .cancelled:
                return "Speech recognizer session was cancelled."
            }
        }
    }

    let locale: Locale

    private let lock = NSLock()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    private var latestText: String = ""
    private var lastNonEmptyText: String = ""
    private var finalText: String?
    private var finalError: Error?
    private var finalContinuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?

    private var hasEndedAudio = false
    private var hasStarted = false
    private var hasCompleted = false

    private var onResult: ((LiveResult) -> Void)?
    private var onError: ((Error) -> Void)?

    init(locale: Locale) {
        self.locale = locale
    }

    deinit {
        cancel()
    }

    func start(
        onResult: @escaping (LiveResult) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws {
        try await ensureSpeechAuthorization()

        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SessionError.recognizerUnavailable
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // Reliability-first default: do not force on-device mode.
        // If the platform can satisfy on-device it may still do so automatically.

        let didStart = lock.withLock { () -> Bool in
            guard !hasStarted else { return false }
            hasStarted = true
            self.recognizer = recognizer
            self.request = request
            self.onResult = onResult
            self.onError = onError
            return true
        }
        guard didStart else { return }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.handleCallback(result: result, error: error)
        }

        lock.withLock {
            recognitionTask = task
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard hasStarted, !hasEndedAudio, !hasCompleted, let request else { return }
            request.append(buffer)
        }
    }

    func finishInput() {
        let requestToEnd = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            guard hasStarted, !hasEndedAudio else { return nil }
            hasEndedAudio = true
            return request
        }
        requestToEnd?.endAudio()
    }

    func finishAndAwaitFinal(timeoutInterval: TimeInterval) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var immediateResult: Swift.Result<String, Error>?

            lock.withLock {
                if let finalText {
                    immediateResult = .success(finalText)
                } else if let finalError {
                    immediateResult = .failure(finalError)
                } else {
                    finalContinuation = continuation
                    if timeoutInterval > 0 {
                        let timeout = timeoutInterval
                        timeoutTask = Task { [weak self] in
                            guard let self else { return }
                            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                            self.completeFinal(with: .failure(SessionError.timeout))
                        }
                    }
                }
            }

            if let immediateResult {
                continuation.resume(with: immediateResult)
                return
            }

            finishInput()
        }
    }

    func cancel() {
        completeFinal(with: .failure(SessionError.cancelled))

        let task = lock.withLock { () -> SFSpeechRecognitionTask? in
            let task = recognitionTask
            recognitionTask = nil
            request = nil
            recognizer = nil
            onResult = nil
            onError = nil
            hasStarted = false
            hasEndedAudio = true
            return task
        }

        task?.cancel()
    }

    func isRunning() -> Bool {
        lock.withLock {
            hasStarted && !hasCompleted && recognitionTask != nil
        }
    }

    func latestTextSnapshot() -> String {
        lock.withLock { latestText }
    }

    func lastNonEmptyTextSnapshot() -> String {
        lock.withLock { lastNonEmptyText }
    }

    private func handleCallback(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let text = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)

            let callback = lock.withLock { () -> ((LiveResult) -> Void)? in
                latestText = text
                if !text.isEmpty {
                    lastNonEmptyText = text
                }
                return onResult
            }

            callback?(LiveResult(text: text, isFinal: result.isFinal, locale: locale))

            if result.isFinal {
                let final = !text.isEmpty ? text : lastNonEmptyTextSnapshot()
                if final.isEmpty {
                    completeFinal(with: .failure(SessionError.noFinalText))
                } else {
                    completeFinal(with: .success(final))
                }
            }
            return
        }

        guard let error else { return }

        let mapped = mapRecognitionError(error)
        let callback = lock.withLock { onError }
        callback?(mapped)

        completeFinal(with: .failure(mapped))
    }

    private func completeFinal(with result: Swift.Result<String, Error>) {
        let completionState = lock.withLock { () -> (CheckedContinuation<String, Error>?, Task<Void, Never>?, SFSpeechRecognitionTask?, SFSpeechAudioBufferRecognitionRequest?)? in
            guard !hasCompleted else { return nil }
            hasCompleted = true

            let continuation = finalContinuation
            finalContinuation = nil

            switch result {
            case .success(let text):
                finalText = text
            case .failure(let error):
                finalError = error
            }

            let timeoutTask = self.timeoutTask
            self.timeoutTask = nil

            let task = recognitionTask
            recognitionTask = nil
            let request = self.request
            self.request = nil
            return (continuation, timeoutTask, task, request)
        }

        guard let (continuation, timeoutTask, task, request) = completionState else { return }

        timeoutTask?.cancel()
        request?.endAudio()
        task?.cancel()

        if let continuation {
            continuation.resume(with: result)
        }
    }

    private func mapRecognitionError(_ error: Error) -> Error {
        if error is CancellationError {
            return SessionError.cancelled
        }
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" {
            if nsError.code == 1101 || nsError.code == 1 {
                return SessionError.recognizerUnavailable
            }
        }
        let message = error.localizedDescription.lowercased()
        if message.contains("not authorized") {
            return SessionError.authorizationDenied
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
            throw SessionError.authorizationDenied
        }
    }
}
