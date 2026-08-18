//
//  RecordScreen.swift
//  Compact bottom panel for on-device recording + transcription.
//

import SwiftUI

struct RecordScreen: View {
    private enum RecordingUIPhase: Equatable {
        case idle
        case starting
        case recording
        case finishing
        case transcribing
    }

    @Environment(\.colorScheme) private var colorScheme

    private let manager = SpeechToTextManager.shared
    private let autoStartOnAppear: Bool
    private let preferredLanguage: SpeechToTextManager.SupportedLanguage?
    private let initialLiveTranscriptionEnabled: Bool?
    private let showsLiveTranscriptionToggle: Bool
    private let livePartialMaxAudioSeconds: Double
    private let livePartialMinimumAudioSeconds: Double
    private let livePollingIntervalNanoseconds: UInt64
    private let onLiveTranscriptChanged: ((LiveTranscriptPartial) -> Void)?
    private let onTranscriptReady: ((UUID, String) -> Void)?
    private let onProcessingCompleted: (() -> Void)?
    private let minimumRecordingDuration: TimeInterval = 0.45
    private let blankAudioRegex = try! NSRegularExpression(
        pattern: #"\[\s*blank_audio\s*\]"#,
        options: [.caseInsensitive]
    )
    private let nonSpeechAnnotationRegex = try! NSRegularExpression(
        pattern: #"\[[^\]]*\]"#,
        options: [.caseInsensitive]
    )
    private let controlTokenRegex = try! NSRegularExpression(
        pattern: #"<\|[^|>]+\|>"#,
        options: [.caseInsensitive]
    )
    private let multiWhitespaceRegex = try! NSRegularExpression(
        pattern: #"\s{2,}"#,
        options: []
    )
    private let dialogDashRegex = try! NSRegularExpression(
        pattern: #"(^|\s)-\s+"#,
        options: []
    )
    private let dialogChevronRegex = try! NSRegularExpression(
        pattern: #"(^|\s)>>+\s*"#,
        options: []
    )
    private let parentheticalNonSpeechRegex = try! NSRegularExpression(
        pattern: #"\((?:\s*(?:music|upbeat music|laughs?|laughter|inaudible|sighs?)\s*)\)"#,
        options: [.caseInsensitive]
    )
    private let accentedNtRegex = try! NSRegularExpression(
        pattern: #"\b([A-Za-z]+)n[íìîï]t\b"#,
        options: [.caseInsensitive]
    )
    private let invalidTranscriptMarkers: [String] = [
        "SwiftUI.ModifiedContent<",
        "Text(storage:",
        "_EnvironmentKeyTransformModifier<",
        "AccentColorProvider",
        "AnyTextStorage("
    ]

    @State private var uiPhase: RecordingUIPhase = .idle
    @State private var transcript = ""
    @State private var errorMessage: String?
    @State private var recordingStartedAt: Date?
    @State private var lastRecordingDuration: TimeInterval = 0
    @State private var micLevel: CGFloat = 0
    @State private var hasAutoStartedRecording = false
    @State private var isLiveTranscriptionEnabled = SpeechToTextManager.shared.isLiveTranscriptionEnabled
    @State private var liveTranscriptionTask: Task<Void, Never>?
    @State private var liveTickCounter: Int = 0
    @State private var hasLoggedFirstLiveText = false
    @State private var maxMicLevelDuringSession: CGFloat = 0
    @State private var activeSessionID = UUID()
    @State private var isRecordingTransitionInFlight = false
    @State private var liveTaskGeneration: Int = 0
    @State private var hasFinishedFirstLiveDecodeAttempt = false
    @State private var liveRecentDecodeLatencyMs: Double?
    @State private var lastForwardedLiveText = ""
    @State private var lastForwardedLiveAt = Date.distantPast
    @State private var bestLiveTranscriptForSession = ""
    @State private var showDeferredTransitionStatus = false
    @State private var deferredTransitionStatusTask: Task<Void, Never>?
    @State private var recordingUITimerTask: Task<Void, Never>?
    @State private var displayedRecordingSeconds: Int = 0
    @State private var stopTapCoolingDown = false

    init(
        autoStartOnAppear: Bool = false,
        preferredLanguage: SpeechToTextManager.SupportedLanguage? = nil,
        initialLiveTranscriptionEnabled: Bool? = nil,
        showsLiveTranscriptionToggle: Bool = true,
        livePartialMaxAudioSeconds: Double = 12.0,
        livePartialMinimumAudioSeconds: Double = 0.8,
        livePollingIntervalNanoseconds: UInt64 = 1_200_000_000,
        onLiveTranscriptChanged: ((LiveTranscriptPartial) -> Void)? = nil,
        onTranscriptReady: ((UUID, String) -> Void)? = nil,
        onProcessingCompleted: (() -> Void)? = nil
    ) {
        self.autoStartOnAppear = autoStartOnAppear
        self.preferredLanguage = preferredLanguage
        self.initialLiveTranscriptionEnabled = initialLiveTranscriptionEnabled
        self.showsLiveTranscriptionToggle = showsLiveTranscriptionToggle
        self.livePartialMaxAudioSeconds = max(2.0, livePartialMaxAudioSeconds)
        self.livePartialMinimumAudioSeconds = max(0.2, min(livePartialMinimumAudioSeconds, self.livePartialMaxAudioSeconds))
        self.livePollingIntervalNanoseconds = max(300_000_000, livePollingIntervalNanoseconds)
        self.onLiveTranscriptChanged = onLiveTranscriptChanged
        self.onTranscriptReady = onTranscriptReady
        self.onProcessingCompleted = onProcessingCompleted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                MicStatusOrb(
                    isListening: isListening,
                    isTranscribing: isTranscribing,
                    level: micLevel
                )

                ZStack(alignment: .leading) {
                    if isListening {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(formatDuration(seconds: displayedRecordingSeconds))
                                .font(.title2.monospacedDigit().weight(.bold))
                                .foregroundStyle(.red)
                            if !hasLoggedFirstLiveText {
                                Text("Listening…")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .transition(.opacity)
                    } else if isTranscribing || ((isAutoStartingRecording || isStoppingRecording) && showDeferredTransitionStatus) {
                        HStack(spacing: 8) {
                            Text(statusText)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                                .transaction { transaction in
                                    transaction.animation = nil
                                }
                            if isTranscribing || isStoppingRecording {
                                Text(formattedRecordingDuration)
                                    .font(.subheadline.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .transition(.opacity)
                    } else if isAutoStartingRecording || isStoppingRecording {
                        Text(" ")
                            .font(.subheadline.weight(.semibold))
                            .transition(.opacity)
                    } else {
                        idlePromptText
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .transaction { transaction in
                                transaction.animation = nil
                            }
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 32, alignment: .leading)

                Spacer(minLength: 8)

                Button(action: {
                    if isListening {
                        handleStopTapped()
                    } else {
                        Task { await toggleRecording() }
                    }
                }) {
                    HStack(spacing: 6) {
                        if isTranscribing || isAutoStartingRecording || isStoppingRecording {
                            ProgressView()
                                .controlSize(.small)
                                .tint(Color.accentColor)
                                .scaleEffect(1.2)
                                .frame(width: 20, height: 20)
                        } else {
                            Image(systemName: isListening ? "pause.fill" : "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                            Text(isListening ? "Stop" : "Speak now")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .foregroundColor((isTranscribing || isAutoStartingRecording || isStoppingRecording) ? .secondary : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        (isTranscribing || isAutoStartingRecording || isStoppingRecording)
                            ? Color.accentColor.opacity(0.18)
                            : (isListening ? Color.red : Color.accentColor),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                (isTranscribing || isAutoStartingRecording || isStoppingRecording) ? Color.accentColor.opacity(0.45) : Color.clear,
                                lineWidth: 1
                            )
                    )
                }
                .allowsHitTesting(
                    !(isTranscribing || isAutoStartingRecording || isStoppingRecording)
                        && !isRecordingTransitionInFlight
                        && !stopTapCoolingDown
                )
                .animation(phaseAnimation, value: uiPhase)
                .animation(phaseAnimation, value: showDeferredTransitionStatus)
            }
            .padding(.horizontal, 2)

            if showsLiveTranscriptionToggle {
                Toggle("Live transcription", isOn: $isLiveTranscriptionEnabled)
                    .font(.caption.weight(.semibold))
                    .tint(.accentColor)
                    .onChange(of: isLiveTranscriptionEnabled) { isEnabled in
                        manager.isLiveTranscriptionEnabled = isEnabled
                        if isEnabled {
                            startLiveTranscriptionIfNeeded()
                        } else {
                            stopLiveTranscription()
                        }
                    }
            }


            if isListening || isTranscribing {
                VStack(alignment: .leading, spacing: 6) {
                    ListeningWaveformView(
                        isListening: isListening,
                        isTranscribing: isTranscribing,
                        level: micLevel
                    )
                    .frame(maxWidth: .infinity)
                }
                .transition(.opacity)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(panelFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isTranscribing
                                    ? [
                                        Color.white.opacity(0.16),
                                        Color.white.opacity(0.04)
                                    ]
                                    : [Color.clear, Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            panelBorderColor,
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: panelShadowColor, radius: 14, y: 4)
        .animation(phaseAnimation, value: uiPhase)
        .onAppear {
            manager.onAudioLevelChange = { rmsLevel in
                Task { @MainActor in
                    let amplified = pow(max(rmsLevel, 0) * 18.0, 0.62)
                    let target = CGFloat(max(0, min(1, amplified)))
                    // Smooth quick fluctuations so the panel feels stable but alive.
                    micLevel = (micLevel * 0.35) + (target * 0.65)
                    if isListening {
                        maxMicLevelDuringSession = max(maxMicLevelDuringSession, target)
                    }
                }
            }
            manager.onSilenceAutoStopTriggered = {
                Task { await handleManagerAutoStop() }
            }
            syncDeferredTransitionStatus(for: uiPhase)
            manager.prewarmRecordingPathIfNeeded()
            if let initialLiveTranscriptionEnabled {
                isLiveTranscriptionEnabled = initialLiveTranscriptionEnabled
                manager.isLiveTranscriptionEnabled = initialLiveTranscriptionEnabled
            } else {
                isLiveTranscriptionEnabled = manager.isLiveTranscriptionEnabled
            }

            guard autoStartOnAppear, !hasAutoStartedRecording else {
                return
            }
            hasAutoStartedRecording = true
            uiPhase = .starting
            Task {
                guard !Task.isCancelled else { return }
                // Let the sheet render one frame before expensive first-start work.
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !isListening, !isTranscribing, !isRecordingTransitionInFlight else {
                        uiPhase = .idle
                        return
                    }
                }
                await toggleRecording()
            }
        }
        .onChange(of: uiPhase) { newPhase in
            syncDeferredTransitionStatus(for: newPhase)
        }
        .onDisappear {
            stopLiveTranscription()
            DispatchQueue.global(qos: .utility).async {
                self.manager.stopListening()
            }
            manager.onAudioLevelChange = nil
            manager.onSilenceAutoStopTriggered = nil
            manager.onBackendStatusChange = nil
            micLevel = 0
            deferredTransitionStatusTask?.cancel()
            deferredTransitionStatusTask = nil
            stopRecordingUITimer()
            showDeferredTransitionStatus = false
            uiPhase = .idle
        }
    }

    private var isListening: Bool { uiPhase == .recording }
    private var isTranscribing: Bool { uiPhase == .transcribing }
    private var isAutoStartingRecording: Bool { uiPhase == .starting }
    private var isStoppingRecording: Bool { uiPhase == .finishing }
    private var phaseAnimation: Animation {
        .interactiveSpring(response: 0.28, dampingFraction: 0.88, blendDuration: 0.12)
    }

    private var statusText: String {
        if isAutoStartingRecording { return "Getting ready..." }
        if isStoppingRecording { return "Wrapping up..." }
        if isTranscribing { return "Finalizing text..." }
        return "Tap Speak now to start dictation"
    }

    private var idlePromptText: Text {
        return Text("Tap Speak now to start dictation")
    }

    private var formattedRecordingDuration: String {
        formatDuration(seconds: Int(lastRecordingDuration))
    }

    private var panelFillColor: Color {
        if colorScheme == .dark {
            return Color(.secondarySystemBackground).opacity(0.92)
        }
        return Color(.systemBackground).opacity(0.97)
    }

    private var panelBorderColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(isTranscribing ? 0.18 : 0.12)
        }
        return Color.black.opacity(isTranscribing ? 0.14 : 0.09)
    }

    private var panelShadowColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.35)
        }
        return Color.black.opacity(0.14)
    }

    private func formatDuration(seconds: Int) -> String {
        let safeSeconds = max(0, seconds)
        let minutes = safeSeconds / 60
        let remainingSeconds = safeSeconds % 60
        return String(format: "%02d:%02d", minutes, remainingSeconds)
    }

    @MainActor
    private func syncDeferredTransitionStatus(for phase: RecordingUIPhase) {
        deferredTransitionStatusTask?.cancel()
        deferredTransitionStatusTask = nil
        showDeferredTransitionStatus = false
        guard phase == .starting || phase == .finishing else { return }
        deferredTransitionStatusTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard uiPhase == phase else { return }
                showDeferredTransitionStatus = true
            }
        }
    }

    @MainActor
    private func toggleRecording() async {
        errorMessage = nil

        if isListening {
            handleStopTapped()
            return
        }

        guard !isRecordingTransitionInFlight else {
            return
        }
        isRecordingTransitionInFlight = true
        defer { isRecordingTransitionInFlight = false }

        guard await manager.gateFeatureUsage() else {
            errorMessage = "Model is not ready yet."
            if isAutoStartingRecording {
                uiPhase = .idle
            }
            return
        }

        uiPhase = .starting
        let granted = await manager.requestMicPermission()
        guard granted else {
            errorMessage = "Microphone access is off. Enable it in Settings."
            uiPhase = .idle
            return
        }

        transcript = ""
        bestLiveTranscriptForSession = ""
        lastRecordingDuration = 0
        hasLoggedFirstLiveText = false
        hasFinishedFirstLiveDecodeAttempt = false
        lastForwardedLiveText = ""
        lastForwardedLiveAt = .distantPast
        maxMicLevelDuringSession = 0
        activeSessionID = UUID()
        // Ensure no stale live loop is still running before a fresh start.
        stopLiveTranscription()
        let startError: Error? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    self.manager.stopListening()
                    try self.manager.startListening(
                        preferredLanguage: self.preferredLanguage,
                        autoStopOnSilence: false,
                        silenceDuration: 1.0,
                        silenceThreshold: 0.003
                    )
                    continuation.resume(returning: nil)
                } catch {
                    continuation.resume(returning: error)
                }
            }
        }

        if let startError {
            uiPhase = .idle
            recordingStartedAt = nil
            errorMessage = startError.localizedDescription
            return
        }

        recordingStartedAt = Date()
        displayedRecordingSeconds = 0
        startRecordingUITimer()
        uiPhase = .recording
        startLiveTranscriptionIfNeeded()
    }

    @MainActor
    private func handleStopTapped() {
        guard !stopTapCoolingDown else { return }
        stopTapCoolingDown = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 450_000_000)
            stopTapCoolingDown = false
        }
        let currentDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        if currentDuration < minimumRecordingDuration {
            return
        }
        uiPhase = .finishing
        finalizeRecordingSessionMetadata()
        guard lastRecordingDuration >= minimumRecordingDuration else {
            errorMessage = "Recording is too short. Speak a bit longer, then tap Stop."
            uiPhase = .idle
            return
        }
        let shouldUseLiveFinalization = isLiveTranscriptionEnabled
        Task { @MainActor in
            await stopManagerListeningAsync()
            if shouldUseLiveFinalization {
                await emitFinalFromLiveSessionIfAvailable()
                onProcessingCompleted?()
                uiPhase = .idle
            } else {
                await transcribeCurrentRecording()
            }
        }
    }

    @MainActor
    private func finalizeRecordingSessionMetadata() {
        stopLiveTranscription()
        if let recordingStartedAt {
            lastRecordingDuration = max(0, Date().timeIntervalSince(recordingStartedAt))
        }
        recordingStartedAt = nil
        stopRecordingUITimer()
    }

    @MainActor
    private func startRecordingUITimer() {
        stopRecordingUITimer()
        recordingUITimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard isListening else { return }
                    displayedRecordingSeconds += 1
                }
            }
        }
    }

    @MainActor
    private func stopRecordingUITimer() {
        recordingUITimerTask?.cancel()
        recordingUITimerTask = nil
    }

    private func stopManagerListeningAsync() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                self.manager.stopListening()
                continuation.resume()
            }
        }
    }

    @MainActor
    private func emitFinalFromLiveSessionIfAvailable() async {
        // Live mode should still emit one final commit event when recording stops.
        do {
            let result = try await manager.transcribe(preferredLanguage: preferredLanguage)
            let cleaned = cleanedTranscript(result.text)
            guard !cleaned.isEmpty else { return }
            transcript = cleaned
            bestLiveTranscriptForSession = cleaned
            onTranscriptReady?(activeSessionID, cleaned)
        } catch {
        }
    }

    @MainActor
    private func transcribeCurrentRecording() async {
        uiPhase = .transcribing
        defer { uiPhase = .idle }
        do {
            let result = try await transcribeWithTimeout(seconds: 90)
            let cleaned = cleanedTranscript(result.text)
            guard !cleaned.isEmpty else {
                if maxMicLevelDuringSession < 0.04 {
                    errorMessage = "No speech detected. Try speaking louder or moving closer to the mic."
                } else {
                    errorMessage = "No clear speech was detected in this recording."
                }
                return
            }
            transcript = cleaned
            bestLiveTranscriptForSession = cleaned
            onTranscriptReady?(activeSessionID, cleaned)
            onProcessingCompleted?()
        } catch {
            let message = error.localizedDescription
            let fallbackSource = bestLiveTranscriptForSession.isEmpty ? transcript : bestLiveTranscriptForSession
            let fallback = cleanedTranscript(fallbackSource)
            if !fallback.isEmpty {
                onTranscriptReady?(activeSessionID, fallback)
                onProcessingCompleted?()
            }
            if message.localizedCaseInsensitiveContains("no audio was captured") {
                errorMessage = "No audio was captured for this recording."
            } else if message.localizedCaseInsensitiveContains("timed out") {
                errorMessage = "Final transcription took too long. Kept the live transcript."
            } else {
                errorMessage = message
            }
        }
    }

    private actor TimeoutGate {
        private var didResolve = false

        func resolveIfNeeded() -> Bool {
            guard !didResolve else { return false }
            didResolve = true
            return true
        }
    }

    private func transcribeWithTimeout(seconds: UInt64) async throws -> (text: String, language: SpeechToTextManager.SupportedLanguage) {
        let gate = TimeoutGate()
        let timeoutError = NSError(
            domain: "SpeechToText",
            code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "Final transcription timed out."]
        )

        let decodeTask = Task(priority: .userInitiated) { [manager, preferredLanguage] in
            try await manager.transcribe(preferredLanguage: preferredLanguage)
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let result = try await decodeTask.value
                    if await gate.resolveIfNeeded() {
                        continuation.resume(returning: result)
                    }
                } catch {
                    if await gate.resolveIfNeeded() {
                        continuation.resume(throwing: error)
                    }
                }
            }

            Task {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                guard await gate.resolveIfNeeded() else { return }
                decodeTask.cancel()
                continuation.resume(throwing: timeoutError)
            }
        }
    }

    @MainActor
    private func handleManagerAutoStop() async {
        guard isListening else { return }
        uiPhase = .finishing
        finalizeRecordingSessionMetadata()
        guard lastRecordingDuration >= minimumRecordingDuration else {
            errorMessage = "Recording is too short. Speak a bit longer, then tap Stop."
            uiPhase = .idle
            return
        }
        await stopManagerListeningAsync()
        if isLiveTranscriptionEnabled {
            await emitFinalFromLiveSessionIfAvailable()
            onProcessingCompleted?()
            uiPhase = .idle
            return
        }
        await transcribeCurrentRecording()
    }

    @MainActor
    private func startLiveTranscriptionIfNeeded() {
        guard isLiveTranscriptionEnabled, isListening, !isTranscribing else { return }
        if liveTranscriptionTask != nil {
            stopLiveTranscription()
        }
        liveTaskGeneration += 1
        let generation = liveTaskGeneration

        liveTranscriptionTask = Task {
            await MainActor.run {
                guard generation == liveTaskGeneration else { return }
                liveTickCounter = 0
                hasFinishedFirstLiveDecodeAttempt = false
                liveRecentDecodeLatencyMs = nil
            }
            while !Task.isCancelled {
                let shouldContinue = await MainActor.run {
                    generation == liveTaskGeneration
                        && isListening
                        && isLiveTranscriptionEnabled
                        && !isTranscribing
                }
                guard shouldContinue else { break }

                let effectivePollingInterval = await MainActor.run {
                    let isSpeechRecognizerBackend = manager.isSpeechRecognizerLiveBackend
                    if isSpeechRecognizerBackend {
                        let bufferedSeconds = manager.currentBufferedAudioSeconds()
                        if bufferedSeconds > 22.0 {
                            return UInt64(1_100_000_000)
                        }
                        let speechRecognizerBase: UInt64 = 650_000_000
                        return micLevel < 0.05 ? 850_000_000 : speechRecognizerBase
                    }
                    if !hasLoggedFirstLiveText, isListening {
                        // Keep first-pass cadence responsive, but avoid busy-loop churn.
                        return UInt64(220_000_000)
                    }
                    // Back off while mostly silent to reduce battery/CPU pressure.
                    let baseInterval = micLevel < 0.05
                        ? min(UInt64(Double(livePollingIntervalNanoseconds) * 2.0), 1_600_000_000)
                        : livePollingIntervalNanoseconds
                    // Use recent decode latency as a conservative backpressure signal.
                    // This avoids issuing new work faster than the decoder can settle.
                    let decodeBackpressureInterval: UInt64
                    if let liveRecentDecodeLatencyMs {
                        decodeBackpressureInterval = UInt64(
                            min(
                                max(liveRecentDecodeLatencyMs * 1_300_000.0, 220_000_000),
                                1_400_000_000
                            )
                        )
                    } else {
                        decodeBackpressureInterval = 0
                    }
                    return max(baseInterval, decodeBackpressureInterval)
                }

                if !(await MainActor.run { hasFinishedFirstLiveDecodeAttempt }) {
                    let bufferedSeconds = manager.currentBufferedAudioSeconds()
                    if bufferedSeconds < 1.00 {
                        try? await Task.sleep(nanoseconds: effectivePollingInterval)
                        continue
                    }
                }

                do {
                    let decodeStartedAt = Date()
                    if let partial = try await manager.transcribePartialCurrentBuffer(
                        preferredLanguage: preferredLanguage,
                        maxAudioSeconds: livePartialMaxAudioSeconds,
                        minimumAudioSeconds: hasLoggedFirstLiveText
                            ? livePartialMinimumAudioSeconds
                            : max(1.00, livePartialMinimumAudioSeconds)
                    ) {
                        await MainActor.run {
                            guard generation == liveTaskGeneration,
                                  isListening,
                                  isLiveTranscriptionEnabled,
                                  !isTranscribing else {
                                return
                            }
                            liveTickCounter += 1
                            let decodeLatencyMs = Double(Int(Date().timeIntervalSince(decodeStartedAt) * 1000))
                            if let liveRecentDecodeLatencyMs {
                                self.liveRecentDecodeLatencyMs = (liveRecentDecodeLatencyMs * 0.7) + (decodeLatencyMs * 0.3)
                            } else {
                                self.liveRecentDecodeLatencyMs = decodeLatencyMs
                            }
                            let cleaned = cleanedTranscript(partial.text)
                            guard !cleaned.isEmpty else {
                                return
                            }
                            if !hasLoggedFirstLiveText, !isMeaningfulFirstLivePartial(cleaned) {
                                return
                            }
                            if !hasLoggedFirstLiveText {
                                hasLoggedFirstLiveText = true
                            }
                            transcript = cleaned
                            if cleaned.count > bestLiveTranscriptForSession.count {
                                bestLiveTranscriptForSession = cleaned
                            }
                            if isLiveTranscriptionEnabled, isListening {
                                var cleanedSegments = partial.segments.compactMap { segment -> LiveTranscriptSegment? in
                                    let cleanedSegmentText = cleanedTranscript(segment.text)
                                    guard !cleanedSegmentText.isEmpty else { return nil }
                                    return LiveTranscriptSegment(
                                        startTime: segment.startTime,
                                        endTime: segment.endTime,
                                        text: cleanedSegmentText
                                    )
                                }
                                if cleanedSegments.isEmpty {
                                    cleanedSegments = [
                                        LiveTranscriptSegment(
                                            startTime: partial.windowStartTime,
                                            endTime: partial.windowEndTime,
                                            text: cleaned
                                        )
                                    ]
                                }
                                let now = Date()
                                let minimumForwardInterval: TimeInterval = 0.35
                                guard shouldForwardLivePartial(cleaned, at: now, minimumInterval: minimumForwardInterval) else {
                                    return
                                }
                                lastForwardedLiveText = cleaned
                                lastForwardedLiveAt = now
                                onLiveTranscriptChanged?(
                                    LiveTranscriptPartial(
                                        sessionID: activeSessionID,
                                        windowStartTime: partial.windowStartTime,
                                        windowEndTime: partial.windowEndTime,
                                        segments: cleanedSegments,
                                        committedText: partial.committedText,
                                        volatileText: partial.volatileText
                                    )
                                )
                            }
                        }
                    }
                    await MainActor.run {
                        if !hasFinishedFirstLiveDecodeAttempt {
                            hasFinishedFirstLiveDecodeAttempt = true
                        }
                    }
                } catch {
                    // Ignore intermittent live decode errors; final decode still runs on stop.
                    await MainActor.run {
                        let isCancellation = (error is CancellationError)
                            || error.localizedDescription.localizedCaseInsensitiveContains("cancellationerror")
                        if !isCancellation {
                        }
                        if !hasFinishedFirstLiveDecodeAttempt {
                            hasFinishedFirstLiveDecodeAttempt = true
                        }
                    }
                }

                try? await Task.sleep(nanoseconds: effectivePollingInterval)
            }

            await MainActor.run {
                guard generation == liveTaskGeneration else { return }
                liveTranscriptionTask = nil
            }
        }
    }

    @MainActor
    private func stopLiveTranscription() {
        liveTaskGeneration += 1
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
    }

    private func shouldForwardLivePartial(
        _ text: String,
        at now: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let previous = lastForwardedLiveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == previous { return false }

        if !previous.isEmpty {
            let elapsed = now.timeIntervalSince(lastForwardedLiveAt)

            if elapsed < minimumInterval {
                let absoluteDelta = abs(trimmed.count - previous.count)
                if absoluteDelta < 4 {
                    return false
                }
            }
        }

        return true
    }

    private func isMeaningfulFirstLivePartial(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count >= 3 { return true }
        if words.count == 2 { return text.count >= 7 }
        if words.count == 1 { return text.count >= 6 && text.last.map({ ".!?".contains($0) }) == true }
        return false
    }

    private func cleanedTranscript(_ text: String) -> String {
        if invalidTranscriptMarkers.contains(where: { text.contains($0) }) {
            return ""
        }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let withoutBlankAudio = blankAudioRegex.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: "")
        let rangeAfterBlank = NSRange(location: 0, length: (withoutBlankAudio as NSString).length)
        let withoutControlTokens = controlTokenRegex.stringByReplacingMatches(
            in: withoutBlankAudio,
            options: [],
            range: rangeAfterBlank,
            withTemplate: ""
        )
        let rangeAfterControlTokens = NSRange(location: 0, length: (withoutControlTokens as NSString).length)
        let withoutNonSpeechTags = nonSpeechAnnotationRegex.stringByReplacingMatches(
            in: withoutControlTokens,
            options: [],
            range: rangeAfterControlTokens,
            withTemplate: ""
        )
        let rangeAfterTags = NSRange(location: 0, length: (withoutNonSpeechTags as NSString).length)
        let withoutParentheticalNonSpeech = parentheticalNonSpeechRegex.stringByReplacingMatches(
            in: withoutNonSpeechTags,
            options: [],
            range: rangeAfterTags,
            withTemplate: ""
        )
        let rangeAfterParenthetical = NSRange(location: 0, length: (withoutParentheticalNonSpeech as NSString).length)
        let withoutDialogDash = dialogDashRegex.stringByReplacingMatches(
            in: withoutParentheticalNonSpeech,
            options: [],
            range: rangeAfterParenthetical,
            withTemplate: " "
        )
        let rangeAfterDialogDash = NSRange(location: 0, length: (withoutDialogDash as NSString).length)
        let withoutDialogChevron = dialogChevronRegex.stringByReplacingMatches(
            in: withoutDialogDash,
            options: [],
            range: rangeAfterDialogDash,
            withTemplate: " "
        )
        let rangeAfterDialogChevron = NSRange(location: 0, length: (withoutDialogChevron as NSString).length)
        let normalizedWhitespace = multiWhitespaceRegex.stringByReplacingMatches(
            in: withoutDialogChevron,
            options: [],
            range: rangeAfterDialogChevron,
            withTemplate: " "
        )
        let normalizedQuotes = normalizedWhitespace
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "ʼ", with: "'")
            .replacingOccurrences(of: "`", with: "'")
            .replacingOccurrences(of: "´", with: "'")
        guard preferredLanguage == .english else {
            return normalizedQuotes.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rangeAfterQuoteNormalization = NSRange(location: 0, length: (normalizedQuotes as NSString).length)
        let normalizedCommonContractions = accentedNtRegex.stringByReplacingMatches(
            in: normalizedQuotes,
            options: [],
            range: rangeAfterQuoteNormalization,
            withTemplate: "$1n't"
        )
        return normalizedCommonContractions.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

private struct MicStatusOrb: View {
    let isListening: Bool
    let isTranscribing: Bool
    let level: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let clampedLevel = max(0, min(1, level))
            let energy = pow(clampedLevel, 0.7)
            let speakingActive = isListening && clampedLevel > 0.08
            let time = context.date.timeIntervalSinceReferenceDate
            let cycle = 1.35
            let reactiveBoost = speakingActive ? (0.22 + (energy * 0.8)) : 0
            let coreColor: Color = isListening ? .red : Color(.tertiarySystemFill)
            let iconColor: Color = isListening ? .white : .secondary
            let coreSize: CGFloat = isListening ? 25 : 40
            let orbSize: CGFloat = isListening ? 50 : 52
            let baseRingSize: CGFloat = coreSize + 2

            ZStack {
                if speakingActive {
                    ForEach(0..<3, id: \.self) { index in
                        let shifted = (time + (Double(index) * (cycle / 3.0))).truncatingRemainder(dividingBy: cycle)
                        let progress = shifted / cycle
                        let scale = 1.0 + (progress * (0.65 + (reactiveBoost * 0.35)))
                        let alpha = max(0, (1.0 - progress)) * (0.34 - (Double(index) * 0.08))

                        Circle()
                            .stroke(Color.red.opacity(alpha), lineWidth: 1.6 - (CGFloat(index) * 0.25))
                            .frame(width: baseRingSize, height: baseRingSize)
                            .scaleEffect(scale)
                            .blur(radius: 0.1 + (CGFloat(index) * 0.18))
                    }
                }

                if isListening {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    Color.red.opacity(0.26),
                                    Color.red.opacity(0.08),
                                    Color.clear
                                ],
                                center: .center,
                                startRadius: 2,
                                endRadius: 24
                            )
                        )
                        .frame(width: coreSize + 18, height: coreSize + 18)
                }

                Circle()
                    .fill(coreColor)
                    .frame(width: coreSize, height: coreSize)

                Image(systemName: isTranscribing ? "waveform" : "mic.fill")
                    .font(.system(size: isListening ? 14 : 17, weight: .bold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: orbSize, height: orbSize)
        }
        .frame(width: isListening ? 46 : 52, height: isListening ? 46 : 52)
        .animation(.easeOut(duration: 0.14), value: isListening)
        .animation(.easeInOut(duration: 0.16), value: isTranscribing)
    }
}

private struct ListeningWaveformView: View {
    let isListening: Bool
    let isTranscribing: Bool
    let level: CGFloat

    var body: some View {
        GeometryReader { proxy in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let width = max(proxy.size.width, 1)
                let barWidth: CGFloat = 3.5
                let spacing: CGFloat = 2.5
                let barCount = max(Int((width + spacing) / (barWidth + spacing)), 16)

                let time = context.date.timeIntervalSinceReferenceDate
                let activeLevel = max(0, min(1, level))
                let speakingLevel = max(0, (activeLevel - 0.08) / 0.92)
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        let phase = time * 7 + Double(index) * 0.65
                        let pulse = (sin(phase) + 1) * 0.5
                        let envelope = (sin((Double(index) * 0.9) + (time * 2.2)) + 1) * 0.5
                        let speakingBase = 0.72 + (pulse * 0.62) + (envelope * 0.38)
                let speakingBoost = isListening ? Double(speakingLevel) * speakingBase : 0
                let processingBoost = isTranscribing ? (0.18 + 0.2 * pulse) : 0
                let boost = speakingBoost + processingBoost
                let barHeight = min(24, 6 + (boost * 16))
                let neutralOpacity = isTranscribing ? (0.25 + (0.2 * pulse)) : 0.3
                let barColor = isListening
                    ? Color.red
                    : (isTranscribing
                        ? Color.secondary.opacity(0.22 + (0.14 * pulse))
                        : Color.secondary.opacity(neutralOpacity))

                        Capsule()
                            .fill(barColor)
                            .frame(width: barWidth, height: barHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 30)
                .clipped()
            }
        }
        .frame(height: 30)
    }
}

#Preview {
    RecordScreen()
}
