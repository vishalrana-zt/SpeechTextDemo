//
//  RecordScreen.swift
//  Compact bottom panel for on-device recording + transcription.
//

import SwiftUI

struct RecordScreen: View {

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
    private let whisperControlTokenRegex = try! NSRegularExpression(
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
    private let parentheticalNonSpeechRegex = try! NSRegularExpression(
        pattern: #"\((?:\s*(?:music|upbeat music|laughs?|laughter|inaudible|sighs?)\s*)\)"#,
        options: [.caseInsensitive]
    )

    @State private var isListening = false
    @State private var isTranscribing = false
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

    private let liveDebugLoggingEnabled = true

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

                if isListening, let recordingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1.0)) { context in
                        Text(formatDuration(seconds: Int(context.date.timeIntervalSince(recordingStartedAt))))
                            .font(.title2.monospacedDigit().weight(.bold))
                            .foregroundStyle(.red)
                    }
                } else if isTranscribing {
                    HStack(spacing: 8) {
                        Text("Transcribing...")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(formattedRecordingDuration)
                            .font(.subheadline.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    idlePromptText
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 8)

                Button(action: { Task { await toggleRecording() } }) {
                    HStack(spacing: 6) {
                        if isTranscribing {
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
                    .foregroundColor(isTranscribing ? .secondary : .white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        isTranscribing
                            ? Color.accentColor.opacity(0.18)
                            : (isListening ? Color.red : Color.accentColor),
                        in: Capsule()
                    )
                    .overlay(
                        Capsule()
                            .stroke(
                                isTranscribing ? Color.accentColor.opacity(0.45) : Color.clear,
                                lineWidth: 1
                            )
                    )
                }
                .allowsHitTesting(!isTranscribing && !isRecordingTransitionInFlight)
            }
            .padding(.horizontal, 2)

            if showsLiveTranscriptionToggle {
                Toggle("Live transcription", isOn: $isLiveTranscriptionEnabled)
                    .font(.caption.weight(.semibold))
                    .tint(.accentColor)
                    .onChange(of: isLiveTranscriptionEnabled) { _, isEnabled in
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
            if let initialLiveTranscriptionEnabled {
                isLiveTranscriptionEnabled = initialLiveTranscriptionEnabled
                manager.isLiveTranscriptionEnabled = initialLiveTranscriptionEnabled
            } else {
                isLiveTranscriptionEnabled = manager.isLiveTranscriptionEnabled
            }

            // Prewarm first recording path to reduce initial Speak now latency.
            manager.prewarmRecordingPathIfNeeded()
            // Prewarm Tiny live decoder to reduce first visible partial latency.
            manager.prewarmLiveDecodeIfNeeded()

            guard autoStartOnAppear, !hasAutoStartedRecording else { return }
            hasAutoStartedRecording = true
            Task { await toggleRecording() }
        }
        .onDisappear {
            stopLiveTranscription()
            manager.stopListening()
            manager.onAudioLevelChange = nil
            manager.onSilenceAutoStopTriggered = nil
            micLevel = 0
        }
    }

    private var statusText: String {
        if isTranscribing { return "Transcribing..." }
        if isListening { return formattedRecordingDuration }
        return "Tap Speak now to start recording"
    }

    private var idlePromptText: Text {
        if isListening || isTranscribing {
            return Text(statusText)
        }
        return Text("Tap \(Text("Speak now").foregroundStyle(Color.accentColor).fontWeight(.bold)) to start recording")
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
    private func toggleRecording() async {
        guard !isRecordingTransitionInFlight else {
            liveDebugLog("toggle_ignored_transition_in_flight")
            return
        }
        isRecordingTransitionInFlight = true
        defer { isRecordingTransitionInFlight = false }

        errorMessage = nil

        guard await manager.gateFeatureUsage() else {
            errorMessage = "Model is not ready yet."
            return
        }

        if isListening {
            let currentDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            if currentDuration < minimumRecordingDuration {
                liveDebugLog("stop_ignored_short_press duration=\(currentDuration)")
                return
            }
            liveDebugLog("stop_requested duration_s=\(String(format: "%.2f", currentDuration))")
            finalizeRecordingSession()
            guard lastRecordingDuration >= minimumRecordingDuration else {
                errorMessage = "Recording too short. Speak for a moment, then tap Stop."
                return
            }
            liveDebugLog("stop_mode live_enabled=\(isLiveTranscriptionEnabled) run_small=\(!isLiveTranscriptionEnabled)")
            // Product mode behavior:
            // - Live streaming ON: keep live transcript as final for this session.
            // - Live streaming OFF: run post-recording Small finalization.
            if isLiveTranscriptionEnabled {
                onProcessingCompleted?()
                return
            }
            await transcribeCurrentRecording()
            return
        }

        let granted = await manager.requestMicPermission()
        guard granted else {
            errorMessage = "Microphone permission denied. Enable it in Settings."
            return
        }

        let startupBeganAt = Date()
        do {
            manager.stopListening()
            transcript = ""
            lastRecordingDuration = 0
            recordingStartedAt = Date()
            hasLoggedFirstLiveText = false
            hasFinishedFirstLiveDecodeAttempt = false
            maxMicLevelDuringSession = 0
            activeSessionID = UUID()
            isListening = true
            // Ensure no stale live loop is still running before a fresh start.
            stopLiveTranscription()
            // Only prewarm Small when running in post-recording mode.
            if !isLiveTranscriptionEnabled {
                manager.prewarmSmallFinalModelIfNeeded()
            }
            try manager.startListening(
                autoStopOnSilence: false,
                silenceDuration: 1.0,
                silenceThreshold: 0.003
            )
            liveDebugLog("recording_started startup_latency_ms=\(Int(Date().timeIntervalSince(startupBeganAt) * 1000))")
            startLiveTranscriptionIfNeeded()
        } catch {
            isListening = false
            recordingStartedAt = nil
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func finalizeRecordingSession() {
        stopLiveTranscription()
        liveDebugLog("live_task_cancelled")
        manager.stopListening()
        liveDebugLog("audio_stopped")
        if let recordingStartedAt {
            lastRecordingDuration = max(0, Date().timeIntervalSince(recordingStartedAt))
        }
        recordingStartedAt = nil
        isListening = false
    }

    @MainActor
    private func transcribeCurrentRecording() async {
        isListening = false
        isTranscribing = true
        defer { isTranscribing = false }
        let startedAt = Date()
        liveDebugLog("final_start")

        do {
            let result = try await transcribeWithTimeout(seconds: 90)
            let cleaned = cleanedTranscript(result.text)
            liveDebugLog("final_raw=\"\(result.text)\"")
            liveDebugLog("final_cleaned=\"\(cleaned)\"")
            guard !cleaned.isEmpty else {
                if maxMicLevelDuringSession < 0.04 {
                    errorMessage = "No speech detected. Try speaking louder or closer to the mic."
                } else {
                    errorMessage = "No usable speech detected for this session."
                }
                return
            }
            transcript = cleaned
            onTranscriptReady?(activeSessionID, cleaned)
            onProcessingCompleted?()
            liveDebugLog("final_complete latency_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
        } catch {
            let message = error.localizedDescription
            let fallback = cleanedTranscript(transcript)
            if !fallback.isEmpty {
                liveDebugLog("final_fallback_live_transcript")
                onTranscriptReady?(activeSessionID, fallback)
                onProcessingCompleted?()
            }
            if message.localizedCaseInsensitiveContains("no audio was captured") {
                errorMessage = "No audio detected for this session."
            } else if message.localizedCaseInsensitiveContains("timed out") {
                errorMessage = "Final transcription timed out. Live transcript was kept."
            } else {
                errorMessage = message
            }
            liveDebugLog("final_failed latency_ms=\(Int(Date().timeIntervalSince(startedAt) * 1000)) error=\"\(message)\"")
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

        let decodeTask = Task(priority: .userInitiated) {
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
        finalizeRecordingSession()
        guard lastRecordingDuration >= minimumRecordingDuration else {
            errorMessage = "Recording too short. Speak for a moment, then tap Stop."
            return
        }
        liveDebugLog("autostop_mode live_enabled=\(isLiveTranscriptionEnabled) run_small=\(!isLiveTranscriptionEnabled)")
        if isLiveTranscriptionEnabled {
            onProcessingCompleted?()
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
                liveDebugLog("start_live_task gen=\(generation) max=\(livePartialMaxAudioSeconds)s min=\(livePartialMinimumAudioSeconds)s poll=\(livePollingIntervalNanoseconds)")
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
                    if !hasLoggedFirstLiveText, isListening {
                        // Keep first-pass cadence responsive, but avoid busy-loop churn.
                        return UInt64(220_000_000)
                    }
                    // Back off while mostly silent to reduce battery/CPU pressure.
                    return micLevel < 0.05
                        ? min(UInt64(Double(livePollingIntervalNanoseconds) * 2.0), 1_600_000_000)
                        : livePollingIntervalNanoseconds
                }

                if !(await MainActor.run { hasFinishedFirstLiveDecodeAttempt }) {
                    let bufferedSeconds = manager.currentBufferedAudioSeconds()
                    if bufferedSeconds < 1.10 {
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
                            : max(1.10, livePartialMinimumAudioSeconds)
                    ) {
                        await MainActor.run {
                            guard generation == liveTaskGeneration,
                                  isListening,
                                  isLiveTranscriptionEnabled,
                                  !isTranscribing else {
                                liveDebugLog("tick_stale_drop gen=\(generation) active_gen=\(liveTaskGeneration)")
                                return
                            }
                            liveTickCounter += 1
                            liveDebugLog("tick=\(liveTickCounter) decode_ms=\(Int(Date().timeIntervalSince(decodeStartedAt) * 1000))")
                            let cleaned = cleanedTranscript(partial.text)
                            liveDebugLog("tick=\(liveTickCounter) raw=\"\(partial.text)\"")
                            liveDebugLog("tick=\(liveTickCounter) cleaned=\"\(cleaned)\"")
                            guard !cleaned.isEmpty else {
                                liveDebugLog("tick=\(liveTickCounter) skip_empty_cleaned")
                                return
                            }
                            if !hasLoggedFirstLiveText, !isMeaningfulFirstLivePartial(cleaned) {
                                liveDebugLog("tick=\(liveTickCounter) suppress_noisy_first_partial")
                                return
                            }
                            if !hasLoggedFirstLiveText, let recordingStartedAt {
                                hasLoggedFirstLiveText = true
                                liveDebugLog("first_visible_text_latency_ms=\(Int(Date().timeIntervalSince(recordingStartedAt) * 1000))")
                            }
                            transcript = cleaned
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
                                onLiveTranscriptChanged?(
                                    LiveTranscriptPartial(
                                        sessionID: activeSessionID,
                                        windowStartTime: partial.windowStartTime,
                                        windowEndTime: partial.windowEndTime,
                                        segments: cleanedSegments
                                    )
                                )
                                liveDebugLog("tick=\(liveTickCounter) forwarded_to_root")
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
                            liveDebugLog("decode_error=\"\(error.localizedDescription)\"")
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
                liveDebugLog("end_live_task gen=\(generation)")
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

    private func isMeaningfulFirstLivePartial(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count >= 3 { return true }
        if words.count == 2 { return text.count >= 7 }
        if words.count == 1 { return text.count >= 6 && text.last.map({ ".!?".contains($0) }) == true }
        return false
    }

    private func cleanedTranscript(_ text: String) -> String {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let withoutBlankAudio = blankAudioRegex.stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: "")
        let rangeAfterBlank = NSRange(location: 0, length: (withoutBlankAudio as NSString).length)
        let withoutWhisperControlTokens = whisperControlTokenRegex.stringByReplacingMatches(
            in: withoutBlankAudio,
            options: [],
            range: rangeAfterBlank,
            withTemplate: ""
        )
        let rangeAfterControlTokens = NSRange(location: 0, length: (withoutWhisperControlTokens as NSString).length)
        let withoutNonSpeechTags = nonSpeechAnnotationRegex.stringByReplacingMatches(
            in: withoutWhisperControlTokens,
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
        let normalizedWhitespace = multiWhitespaceRegex.stringByReplacingMatches(
            in: withoutDialogDash,
            options: [],
            range: rangeAfterDialogDash,
            withTemplate: " "
        )
        return normalizedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    private func liveDebugLog(_ message: String) {
        guard liveDebugLoggingEnabled else { return }
        print("[LIVE_DEBUG][RecordScreen] \(message)")
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
