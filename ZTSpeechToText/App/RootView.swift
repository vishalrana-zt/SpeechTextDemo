//
//  RootView.swift
//  Demo note screen that opens STT flow and receives transcript text.
//

import SwiftUI
import UIKit

struct RootView: View {
    private let manager = SpeechToTextManager.shared

    private enum CaptureMode: String, CaseIterable, Identifiable {
        case liveStreaming
        case postRecording

        var id: String { rawValue }

        var title: String {
            switch self {
            case .liveStreaming: return "Live dictation"
            case .postRecording: return "After recording"
            }
        }

        var managerMode: SpeechToTextManager.OperationMode {
            switch self {
            case .liveStreaming: return .liveStreaming
            case .postRecording: return .postRecording
            }
        }
    }

    @State private var noteText = ""
    @State private var isSpeechToTextSheetPresented = false
    @State private var liveSessionID: UUID?
    @State private var liveDraftBaseText = ""
    @State private var livePreviewText = ""
    @State private var liveReconciler = LiveTranscriptReconciler()
    @State private var lastAppliedLiveWindowEnd: TimeInterval = 0
    @State private var lastLivePreviewAppliedAt: TimeInterval = 0
    @State private var appleCommittedLiveText = ""
    @State private var appleLastWindowText = ""
    @State private var lastAcceptedAppleWindowStart: TimeInterval = 0
    @State private var applePinnedPrefixText = ""
    @State private var selectedLanguage: SpeechToTextManager.SupportedLanguage = RootView.defaultSupportedLanguage()
    @State private var selectedMode: CaptureMode = .liveStreaming
    @State private var isNoteEditorFocused = false
    @State private var isLogActionsPresented = false
    @State private var isLogSharePresented = false
    @State private var logShareText: String?
    private let bottomPanelReservedHeight: CGFloat = 60
    private let invalidTranscriptMarkers: [String] = [
        "SwiftUI.ModifiedContent<",
        "Text(storage:",
        "_EnvironmentKeyTransformModifier<",
        "AccentColorProvider",
        "AnyTextStorage("
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Language", selection: $selectedLanguage) {
                        ForEach(SpeechToTextManager.SupportedLanguage.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isSpeechToTextSheetPresented)

                    Picker("Mode", selection: $selectedMode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isSpeechToTextSheetPresented)

                }

                ZStack(alignment: .topLeading) {
                    LiveAwareTextView(
                        text: $noteText,
                        shouldAutoScrollLiveInsertion: selectedMode == .liveStreaming && isSpeechToTextSheetPresented,
                        shouldShowLiveCaret: selectedMode == .liveStreaming
                            && isSpeechToTextSheetPresented
                            && !livePreviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        onEditingChanged: { isFocused in
                            isNoteEditorFocused = isFocused
                        }
                    )
                        .padding(4)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color(.secondarySystemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color(.separator).opacity(0.3), lineWidth: 1)
                        )

                    if shouldShowNotePlaceholder {
                        Text("Tap the AI mic in the top-right to start dictation.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 16)
                            .padding(.leading, 14)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: shouldShowNotePlaceholder)

                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
            }
            .padding()
            .padding(.bottom, isSpeechToTextSheetPresented ? bottomPanelReservedHeight : 0)
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isLogActionsPresented = true
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .accessibilityLabel("Log Actions")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        STTSessionLogger.shared.log(
                            source: "RootView",
                            message: "ui action=note_mic_tap mode=\(selectedMode.rawValue) lang=\(selectedLanguage.rawValue)"
                        )
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        manager.prewarmRecordingPathIfNeeded()
                        isSpeechToTextSheetPresented = true
                    } label: {
                        Image(systemName: "waveform.badge.mic")
                    }
                    .accessibilityLabel("Add note with voice")
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isSpeechToTextSheetPresented)
        .speechToTextSheet(
            isPresented: $isSpeechToTextSheetPresented,
            configuration: sheetConfiguration,
            onLiveTranscriptChanged: { partial in
                applyLiveTranscriptPartial(partial)
            },
            onTextReady: { sessionID, transcribedText in
                commitFinalTranscript(sessionID: sessionID, transcribedText)
            }
        )
        .onChange(of: isSpeechToTextSheetPresented) { isPresented in
            STTSessionLogger.shared.log(source: "RootView", message: "ui sheet_presented=\(isPresented)")
            if !isPresented {
                resetLiveDraftState()
            }
        }
        .onChange(of: selectedMode) { _ in
            STTSessionLogger.shared.log(source: "RootView", message: "ui mode_changed=\(selectedMode.rawValue)")
            resetLiveDraftState()
        }
        .onChange(of: selectedLanguage) { _ in
            STTSessionLogger.shared.log(source: "RootView", message: "ui language_changed=\(selectedLanguage.rawValue)")
            resetLiveDraftState()
            manager.resetSessionStateForLanguageChange(selectedLanguage)
        }
        .onChange(of: noteText) { value in
            STTSessionLogger.shared.log(
                source: "RootView",
                message: "textview render chars=\(value.count) live_preview_chars=\(livePreviewText.count)"
            )
        }
        .onAppear {
            manager.setModelProvider(.appleModels)
            STTSessionLogger.shared.log(
                source: "RootView",
                message: "ui appear mode=\(selectedMode.rawValue) lang=\(selectedLanguage.rawValue) provider=appleModels"
            )
        }
        .sheet(isPresented: $isLogSharePresented) {
            if let logShareText {
                ActivityView(activityItems: [logShareText])
            }
        }
        .confirmationDialog("Log Actions", isPresented: $isLogActionsPresented, titleVisibility: .visible) {
            Button("Clear All Logs") {
                STTSessionLogger.shared.clearAllLogs()
                STTSessionLogger.shared.log(source: "RootView", message: "ui action=clear_all_logs")
            }
            Button("Share Logs") {
                let text = STTSessionLogger.shared.shareableLogText()
                logShareText = text
                isLogSharePresented = true
                STTSessionLogger.shared.log(source: "RootView", message: "ui action=share_logs text_chars=\(text.count)")
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var sheetConfiguration: SpeechToTextSheetConfiguration {
        SpeechToTextSheetConfiguration(
            preferredLanguage: selectedLanguage,
            operationMode: selectedMode.managerMode,
            modelProvider: .appleModels,
            showsModelProviderSelector: false,
            initialLiveTranscriptionEnabled: selectedMode == .liveStreaming,
            showsLiveTranscriptionToggle: false,
            livePartialMaxAudioSeconds: 6.0,
            livePartialMinimumAudioSeconds: 0.6,
            livePollingIntervalNanoseconds: 600_000_000
        )
    }

    private var shouldShowNotePlaceholder: Bool {
        noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isNoteEditorFocused
    }

    private func merge(_ baseText: String, with transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseText }
        if baseText.isEmpty {
            return trimmed
        }
        return baseText + "\n" + trimmed
    }

    private func appendTranscript(_ transcript: String) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isValidTranscriptText(trimmed) else {
            return
        }
        let previous = noteText
        let merged = merge(previous, with: trimmed)
        noteText = merged
    }

    private func applyLiveTranscriptPartial(_ partial: LiveTranscriptPartial) {
        guard selectedMode == .liveStreaming else { return }
        let segmentChars = partial.segments.reduce(0) { $0 + $1.text.count }
        let committedChars = partial.committedText?.count ?? 0
        let volatileChars = partial.volatileText?.count ?? 0
        STTSessionLogger.shared.log(
            source: "RootView",
            message: "live_partial session=\(partial.sessionID.uuidString) window=\(String(format: "%.2f", partial.windowStartTime))-\(String(format: "%.2f", partial.windowEndTime)) segment_chars=\(segmentChars) committed_chars=\(committedChars) volatile_chars=\(volatileChars)"
        )
        if liveSessionID != partial.sessionID {
            liveSessionID = partial.sessionID
            liveDraftBaseText = noteText
            livePreviewText = ""
            appleCommittedLiveText = ""
            appleLastWindowText = ""
            applePinnedPrefixText = ""
            liveReconciler.beginSession(partial.sessionID)
            lastAppliedLiveWindowEnd = 0
            lastLivePreviewAppliedAt = 0
            lastAcceptedAppleWindowStart = 0
        }

        if partial.windowEndTime + 0.001 < lastAppliedLiveWindowEnd {
            return
        }


        let acceptedPreview: String
        if let committed = partial.committedText,
           let volatile = partial.volatileText {
            // Apple streaming path provides an explicit committed/volatile split.
            // Keep committed prefix untouched and replace only the tail.
            let committedTrimmed = committed.trimmingCharacters(in: .whitespacesAndNewlines)
            let volatileTrimmed = volatile.trimmingCharacters(in: .whitespacesAndNewlines)
            let stitched = [committedTrimmed, volatileTrimmed]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            acceptedPreview = acceptedLivePreview(from: stitched)
        } else {
            guard let renderState = liveReconciler.apply(partial) else { return }
            let preview = renderState.renderedText
            guard !preview.isEmpty else { return }
            acceptedPreview = acceptedLivePreview(from: preview)
        }

        guard acceptedPreview != livePreviewText else { return }

        let now = Date().timeIntervalSinceReferenceDate
        let sinceLastApply = now - lastLivePreviewAppliedAt
        if sinceLastApply < 0.16 {
            let delta = abs(acceptedPreview.count - livePreviewText.count)
            if delta < 18 {
                return
            }
        }
        livePreviewText = acceptedPreview

        let updatedNoteText = merge(liveDraftBaseText, with: acceptedPreview)
        noteText = updatedNoteText
        lastAppliedLiveWindowEnd = partial.windowEndTime
        lastLivePreviewAppliedAt = now
    }

    private func commitFinalTranscript(sessionID: UUID, _ finalText: String) {
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        STTSessionLogger.shared.log(
            source: "RootView",
            message: "final_commit begin session=\(sessionID.uuidString) chars=\(trimmed.count)"
        )
        guard isValidTranscriptText(trimmed) else {
            STTSessionLogger.shared.log(source: "RootView", message: "final_commit dropped_invalid")
            return
        }

        if selectedMode != .liveStreaming || liveSessionID == nil {
            appendTranscript(trimmed)
            resetLiveDraftState()
            return
        }

        guard sessionID == liveSessionID else {
            return
        }
        let reconciledFinal = liveReconciler.finalize(sessionID: sessionID, finalText: trimmed) ?? trimmed
        let resolvedFinal = resolvedAppleLiveFinalTextIfNeeded(reconciledFinal)

        let merged = merge(liveDraftBaseText, with: resolvedFinal)
        noteText = merged
        STTSessionLogger.shared.log(
            source: "RootView",
            message: "final_commit applied chars=\(resolvedFinal.count) total_note_chars=\(noteText.count)"
        )
        resetLiveDraftState()
    }

    private func resetLiveDraftState() {
        liveSessionID = nil
        liveDraftBaseText = ""
        livePreviewText = ""
        appleCommittedLiveText = ""
        appleLastWindowText = ""
        applePinnedPrefixText = ""
        lastAppliedLiveWindowEnd = 0
        lastLivePreviewAppliedAt = 0
        lastAcceptedAppleWindowStart = 0
        liveReconciler.reset()
    }

    private func acceptedLivePreview(from incoming: String) -> String {
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return livePreviewText }
        guard isValidTranscriptText(next) else { return livePreviewText }
        return next
    }

    private func isValidTranscriptText(_ text: String) -> Bool {
        !invalidTranscriptMarkers.contains(where: { text.contains($0) })
    }

    private func stabilizedAppleLivePreview(from incoming: String) -> String {
        let cleanedIncoming = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedIncoming.isEmpty else { return livePreviewText }

        let previous = livePreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        if previous.isEmpty {
            return cleanedIncoming
        }

        let previousWords = words(from: previous)
        let incomingWords = words(from: cleanedIncoming)
        let sharedPrefixCount = sharedWordPrefixCount(lhs: previousWords, rhs: incomingWords)

        if sharedPrefixCount >= 8 {
            let keepMutableTailWords = 6
            let commitCount = max(0, sharedPrefixCount - keepMutableTailWords)
            if commitCount > 0 {
                let commitChunk = incomingWords.prefix(commitCount).joined(separator: " ")
                appleCommittedLiveText = stitchWords(left: appleCommittedLiveText, right: commitChunk)
            }
        }

        let committedWords = words(from: appleCommittedLiveText)
        let tailWords = incomingWords.dropFirst(sharedWordPrefixCountForCommitted(committedWords: committedWords, incomingWords: incomingWords))
        let tailText = String(tailWords.joined(separator: " ")).trimmingCharacters(in: .whitespacesAndNewlines)
        let rendered = stitchWords(left: appleCommittedLiveText, right: tailText)
        return rendered.isEmpty ? cleanedIncoming : rendered
    }

    private func updatedAppleRollingLiveText(candidate: String, windowStartTime: TimeInterval) -> String {
        let cleanedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedCandidate.isEmpty else { return livePreviewText }

        let previousWindow = appleLastWindowText.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidateWords = words(from: cleanedCandidate)
        let previousWords = words(from: previousWindow)

        if !previousWords.isEmpty {
            let overlap = maxWordOverlapSuffixPrefix(previous: previousWords, current: candidateWords)
            if overlap > 0 {
                let droppedPrefix = previousWords.dropLast(overlap).joined(separator: " ")
                if !droppedPrefix.isEmpty {
                    appleCommittedLiveText = stitchWords(left: appleCommittedLiveText, right: droppedPrefix)
                }
            } else if windowStartTime > lastAcceptedAppleWindowStart + 0.6 {
                // If window moved and no overlap is found, preserve prior window text
                // as committed to avoid visible backtracking.
                appleCommittedLiveText = stitchWords(left: appleCommittedLiveText, right: previousWindow)
            }
        }

        appleLastWindowText = cleanedCandidate
        return stitchWords(left: appleCommittedLiveText, right: cleanedCandidate)
    }

    private func stabilizedAppleShiftAwareLivePreview(candidate: String, windowStartTime: TimeInterval) -> String {
        let cleanedCandidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedCandidate.isEmpty else { return livePreviewText }

        // Before rolling-window shift, recognizer output is typically cumulative.
        if windowStartTime <= 0.5 {
            return cleanedCandidate
        }

        let previous = livePreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty else { return cleanedCandidate }

        // Capture a stable prefix once when the rolling window starts shifting.
        if applePinnedPrefixText.isEmpty,
           let droppedPrefix = droppedLeadingPrefix(previous: previous, current: cleanedCandidate) {
            applePinnedPrefixText = droppedPrefix
        }

        if !applePinnedPrefixText.isEmpty {
            return stitchWords(left: applePinnedPrefixText, right: cleanedCandidate)
        }

        // If we cannot align but candidate shrank strongly, keep prior text
        // instead of replacing with a likely regressive shifted hypothesis.
        let previousWords = words(from: previous)
        let candidateWords = words(from: cleanedCandidate)
        if candidateWords.count + 5 < previousWords.count {
            return previous
        }

        return cleanedCandidate
    }

    private func droppedLeadingPrefix(previous: String, current: String) -> String? {
        let previousWords = words(from: previous)
        let currentWords = words(from: current)
        guard previousWords.count > 2, currentWords.count > 2 else { return nil }
        guard previousWords.count >= currentWords.count else { return nil }

        let normalizedCurrent = currentWords.map(normalizedWord)
        let normalizedPrevious = previousWords.map(normalizedWord)
        guard !normalizedCurrent.isEmpty else { return nil }

        // Fast reject: if the current tail does not share the same final token,
        // it cannot be a direct shifted tail of the previous hypothesis.
        guard normalizedPrevious.last == normalizedCurrent.last else { return nil }

        let maxStart = max(0, previousWords.count - currentWords.count)
        // Prefer the latest matching window to avoid false matches when phrases
        // repeat earlier in the text ("hello ... hello ...").
        for start in stride(from: maxStart, through: 0, by: -1) {
            let end = start + currentWords.count
            guard end <= previousWords.count else { continue }
            if normalizedPrevious[start..<end].elementsEqual(normalizedCurrent) {
                let prefix = previousWords.prefix(start).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                return prefix.isEmpty ? nil : prefix
            }
        }

        return nil
    }

    private func maxWordOverlapSuffixPrefix(previous: [String], current: [String]) -> Int {
        let limit = min(previous.count, current.count)
        guard limit > 0 else { return 0 }
        for overlap in stride(from: limit, through: 1, by: -1) {
            let previousTail = previous.suffix(overlap).map(normalizedWord)
            let currentHead = current.prefix(overlap).map(normalizedWord)
            if previousTail == currentHead {
                return overlap
            }
        }
        return 0
    }

    private func resolvedAppleLiveFinalTextIfNeeded(_ finalText: String) -> String {
        guard selectedMode == .liveStreaming else {
            return finalText
        }

        let finalTrimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let liveTrimmed = livePreviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !liveTrimmed.isEmpty else { return finalTrimmed }
        guard !finalTrimmed.isEmpty else { return liveTrimmed }

        let finalWords = words(from: finalTrimmed).map(normalizedWord).filter { !$0.isEmpty }
        let liveWords = words(from: liveTrimmed).map(normalizedWord).filter { !$0.isEmpty }
        guard !finalWords.isEmpty, !liveWords.isEmpty else { return finalTrimmed }

        // If final looks like a shifted tail of live preview, preserve dropped prefix.
        if let droppedPrefix = droppedLeadingPrefix(previous: liveTrimmed, current: finalTrimmed) {
            return stitchWords(left: droppedPrefix, right: finalTrimmed)
        }

        let finalSet = Set(finalWords)
        let liveSet = Set(liveWords)
        let intersection = finalSet.intersection(liveSet).count
        let union = finalSet.union(liveSet).count
        let overlap = union > 0 ? Double(intersection) / Double(union) : 0

        let sharedPrefix = sharedWordPrefixCount(lhs: words(from: liveTrimmed), rhs: words(from: finalTrimmed))
        let isStronglyShorter = finalWords.count < Int(Double(liveWords.count) * 0.7)
        let isModeratelyShorter = finalWords.count < Int(Double(liveWords.count) * 0.85)
        let weakPrefixAlignment = sharedPrefix < min(4, finalWords.count)

        // Reject regressive stop-time replacements that shrink too much,
        // even if bag-of-words overlap is moderate.
        if isStronglyShorter && overlap < 0.55 {
            return liveTrimmed
        }
        if isModeratelyShorter && weakPrefixAlignment && overlap < 0.70 {
            return liveTrimmed
        }

        return finalTrimmed
    }

    private func volatileTail(from text: String, committedPrefix: String) -> String {
        let full = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = committedPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "" }
        guard !prefix.isEmpty else { return full }
        if full.hasPrefix(prefix) {
            let idx = full.index(full.startIndex, offsetBy: prefix.count)
            return full[idx...].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }

    private func words(from text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func sharedWordPrefixCount(lhs: [String], rhs: [String]) -> Int {
        let limit = min(lhs.count, rhs.count)
        guard limit > 0 else { return 0 }
        var count = 0
        while count < limit {
            if normalizedWord(lhs[count]) != normalizedWord(rhs[count]) {
                break
            }
            count += 1
        }
        return count
    }

    private func sharedWordPrefixCountForCommitted(committedWords: [String], incomingWords: [String]) -> Int {
        let limit = min(committedWords.count, incomingWords.count)
        guard limit > 0 else { return 0 }
        var count = 0
        while count < limit {
            if normalizedWord(committedWords[count]) != normalizedWord(incomingWords[count]) {
                break
            }
            count += 1
        }
        return count
    }

    private func normalizedWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private func stitchWords(left: String, right: String) -> String {
        let lhs = left.trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = right.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rhs.isEmpty else { return lhs }
        guard !lhs.isEmpty else { return rhs }
        if lhs.hasSuffix(rhs) { return lhs }
        if rhs.hasPrefix(lhs) { return rhs }
        return lhs + " " + rhs
    }

    private func shouldAcceptAppleLiveCandidate(
        previous: String,
        candidate: String,
        windowStartTime: TimeInterval
    ) -> Bool {
        let old = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return false }
        guard !old.isEmpty else { return true }
        if next == old { return false }

        let oldWords = words(from: old).map(normalizedWord).filter { !$0.isEmpty }
        let nextWords = words(from: next).map(normalizedWord).filter { !$0.isEmpty }
        guard !oldWords.isEmpty, !nextWords.isEmpty else { return true }

        let oldSet = Set(oldWords)
        let nextSet = Set(nextWords)
        let intersection = oldSet.intersection(nextSet).count
        let union = oldSet.union(nextSet).count
        let overlap = union > 0 ? Double(intersection) / Double(union) : 0
        let hasWindowShift = (windowStartTime - lastAcceptedAppleWindowStart) >= 0.8

        let nextIsSignificantlyShorter = nextWords.count < Int(Double(oldWords.count) * 0.75)
        if nextIsSignificantlyShorter && overlap < 0.55 && !hasWindowShift {
            return false
        }

        let isHardDivergence = overlap < 0.25
        let hasStrongGrowth = nextWords.count >= oldWords.count + 6
        if isHardDivergence && !hasStrongGrowth && !hasWindowShift {
            return false
        }

        return true
    }

    private static func defaultSupportedLanguage() -> SpeechToTextManager.SupportedLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("es") { return .spanish }
        if preferred.hasPrefix("fr") { return .french }
        return .english
    }

}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

private struct LiveAwareTextView: UIViewRepresentable {
    @Binding var text: String
    let shouldAutoScrollLiveInsertion: Bool
    let shouldShowLiveCaret: Bool
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.tintColor = .systemBlue
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.inputAccessoryView = context.coordinator.makeKeyboardAccessoryToolbar()
        textView.text = text
        context.coordinator.attach(textView: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.updateLiveMode(shouldAutoScrollLiveInsertion)
        context.coordinator.updateShouldShowLiveCaret(shouldShowLiveCaret)
        context.coordinator.updateBaseText(text)

        let displayText = context.coordinator.currentDisplayText()
        if uiView.text != displayText {
            context.coordinator.applyProgrammaticText(displayText, on: uiView)
        }
        uiView.font = .preferredFont(forTextStyle: .body)
        uiView.textColor = .label
        uiView.tintColor = .systemBlue

        if shouldAutoScrollLiveInsertion {
            context.coordinator.scrollToEnd(uiView)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveAwareTextView
        private weak var textView: UITextView?
        private var caretTimer: Timer?
        private var liveCaretVisible = false
        private var isProgrammaticTextChange = false
        private var baseText = ""
        private var isLiveMode = false
        private var shouldShowLiveCaret = false
        private let liveCaretCharacter = "▌"

        init(_ parent: LiveAwareTextView) {
            self.parent = parent
        }

        deinit {
            caretTimer?.invalidate()
        }

        func attach(textView: UITextView) {
            self.textView = textView
        }

        func makeKeyboardAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()
            let flexible = UIBarButtonItem(systemItem: .flexibleSpace)
            let done = UIBarButtonItem(
                title: "Done",
                style: .plain,
                target: self,
                action: #selector(doneButtonTapped)
            )
            toolbar.items = [flexible, done]
            return toolbar
        }

        @objc
        private func doneButtonTapped() {
            textView?.resignFirstResponder()
        }

        func updateBaseText(_ text: String) {
            baseText = text
        }

        func updateLiveMode(_ enabled: Bool) {
            guard isLiveMode != enabled else { return }
            isLiveMode = enabled
            if enabled {
                startCaretTimer()
            } else {
                stopCaretTimer()
                if let textView {
                    applyProgrammaticText(baseText, on: textView)
                }
            }
        }

        func updateShouldShowLiveCaret(_ enabled: Bool) {
            shouldShowLiveCaret = enabled
            if let textView {
                applyProgrammaticText(currentDisplayText(), on: textView)
                if isLiveMode {
                    scrollToEnd(textView)
                }
            }
        }

        func currentDisplayText() -> String {
            guard isLiveMode else { return baseText }
            guard shouldShowLiveCaret else { return baseText }
            return liveCaretVisible ? baseText + liveCaretCharacter : baseText
        }

        func applyProgrammaticText(_ value: String, on textView: UITextView) {
            isProgrammaticTextChange = true
            if isLiveMode, shouldShowLiveCaret, value.hasSuffix(liveCaretCharacter) {
                let bodyText = String(value.dropLast(liveCaretCharacter.count))
                let bodyAttributes: [NSAttributedString.Key: Any] = [
                    .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.label
                ]
                let caretAttributes: [NSAttributedString.Key: Any] = [
                    .font: textView.font ?? UIFont.preferredFont(forTextStyle: .body),
                    .foregroundColor: UIColor.systemRed
                ]
                let rendered = NSMutableAttributedString(string: bodyText, attributes: bodyAttributes)
                rendered.append(NSAttributedString(string: liveCaretCharacter, attributes: caretAttributes))
                textView.attributedText = rendered
            } else {
                textView.attributedText = nil
                textView.text = value
                textView.textColor = .label
            }
            isProgrammaticTextChange = false
        }

        func scrollToEnd(_ textView: UITextView) {
            let end = (textView.text as NSString).length
            textView.selectedRange = NSRange(location: end, length: 0)
            textView.layoutIfNeeded()
            if end > 0 {
                textView.scrollRangeToVisible(NSRange(location: end - 1, length: 1))
            } else {
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
            let safeOffset = max(0, textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom)
            textView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: false)
        }

        private func startCaretTimer() {
            caretTimer?.invalidate()
            liveCaretVisible = true
            caretTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
                guard let self, self.isLiveMode, let textView else { return }
                self.liveCaretVisible.toggle()
                self.applyProgrammaticText(self.currentDisplayText(), on: textView)
                self.scrollToEnd(textView)
            }
            if let caretTimer {
                RunLoop.main.add(caretTimer, forMode: .common)
            }
        }

        private func stopCaretTimer() {
            caretTimer?.invalidate()
            caretTimer = nil
            liveCaretVisible = false
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !isProgrammaticTextChange else { return }
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onEditingChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onEditingChanged(false)
        }

    }
}

#Preview {
    RootView()
}
