//
//  RootView.swift
//  Demo note screen that opens STT flow and receives transcript text.
//

import SwiftUI
import UIKit

struct RootView: View {

    private enum CaptureMode: String, CaseIterable, Identifiable {
        case liveStreaming
        case postRecording

        var id: String { rawValue }

        var title: String {
            switch self {
            case .liveStreaming: return "Live streaming"
            case .postRecording: return "Post recording"
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
    @State private var selectedLanguage: SpeechToTextManager.SupportedLanguage = RootView.defaultSupportedLanguage()
    @State private var selectedMode: CaptureMode = .liveStreaming
    @State private var isNoteEditorFocused = false
    private let liveDebugLoggingEnabled = true
    private let bottomPanelReservedHeight: CGFloat = 60

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

                    Picker("Mode", selection: $selectedMode) {
                        ForEach(CaptureMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
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
                        Text("Tap the AI mic icon in the top-right to start dictating your note.")
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
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
        .onChange(of: isSpeechToTextSheetPresented) { _, isPresented in
            if !isPresented {
                resetLiveDraftState(clearPreview: true)
            }
        }
        .onChange(of: selectedMode) { _, _ in
            resetLiveDraftState(clearPreview: false)
        }
    }

    private var sheetConfiguration: SpeechToTextSheetConfiguration {
        SpeechToTextSheetConfiguration(
            preferredLanguage: selectedLanguage,
            operationMode: selectedMode.managerMode,
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
        let previous = noteText
        let merged = merge(previous, with: trimmed)
        noteText = merged
    }

    private func applyLiveTranscriptPartial(_ partial: LiveTranscriptPartial) {
        guard selectedMode == .liveStreaming else { return }
        let applyStartedAt = Date()

        if liveSessionID != partial.sessionID {
            liveSessionID = partial.sessionID
            liveDraftBaseText = noteText
            livePreviewText = ""
            liveReconciler.beginSession(partial.sessionID)
            lastAppliedLiveWindowEnd = 0
            lastLivePreviewAppliedAt = 0
        }

        if partial.windowEndTime + 0.001 < lastAppliedLiveWindowEnd {
            liveDebugLog("drop_stale_partial stale_window_end=\(partial.windowEndTime) last=\(lastAppliedLiveWindowEnd)")
            return
        }

        liveDebugLog("root_partial window=[\(partial.windowStartTime), \(partial.windowEndTime)] segments=\(partial.segments.count)")

        guard let renderState = liveReconciler.apply(partial) else { return }
        let preview = renderState.renderedText
        guard !preview.isEmpty else { return }
        let acceptedPreview = acceptedLivePreview(from: preview)
        guard acceptedPreview != livePreviewText else { return }

        let now = Date().timeIntervalSinceReferenceDate
        let sinceLastApply = now - lastLivePreviewAppliedAt
        if sinceLastApply < 0.16 {
            let delta = abs(acceptedPreview.count - livePreviewText.count)
            if delta < 18 {
                liveDebugLog("drop_jitter_partial dt_ms=\(Int(sinceLastApply * 1000)) delta=\(delta)")
                return
            }
        }
        livePreviewText = acceptedPreview

        let updatedNoteText = merge(liveDraftBaseText, with: acceptedPreview)
        let previous = noteText
        noteText = updatedNoteText
        lastAppliedLiveWindowEnd = partial.windowEndTime
        lastLivePreviewAppliedAt = now
        _ = previous
        liveDebugLog("ui_apply_ms=\(Int(Date().timeIntervalSince(applyStartedAt) * 1000))")
    }

    private func commitFinalTranscript(sessionID: UUID, _ finalText: String) {
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if selectedMode != .liveStreaming || liveSessionID == nil {
            appendTranscript(trimmed)
            resetLiveDraftState(clearPreview: false)
            return
        }

        guard sessionID == liveSessionID else {
            liveDebugLog("drop_final_stale_session")
            return
        }
        let reconciledFinal = liveReconciler.finalize(sessionID: sessionID, finalText: trimmed) ?? trimmed
        liveDebugLog("final_commit=\"\(reconciledFinal)\"")

        let merged = merge(liveDraftBaseText, with: reconciledFinal)
        noteText = merged
        resetLiveDraftState(clearPreview: false)
    }

    private func resetLiveDraftState(clearPreview: Bool) {
        _ = clearPreview
        liveSessionID = nil
        liveDraftBaseText = ""
        livePreviewText = ""
        lastAppliedLiveWindowEnd = 0
        lastLivePreviewAppliedAt = 0
        liveReconciler.reset()
    }

    private func acceptedLivePreview(from incoming: String) -> String {
        let next = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !next.isEmpty else { return livePreviewText }
        return next
    }

    private static func defaultSupportedLanguage() -> SpeechToTextManager.SupportedLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
        if preferred.hasPrefix("es") { return .spanish }
        if preferred.hasPrefix("fr") { return .french }
        return .english
    }

    private func liveDebugLog(_ message: String) {
        guard liveDebugLoggingEnabled else { return }
        print("[LIVE_DEBUG][RootView] \(message)")
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
