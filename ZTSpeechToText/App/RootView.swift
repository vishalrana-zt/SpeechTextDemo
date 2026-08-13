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
    @State private var highlightRequest: SpeechHighlightRequest?
    @State private var liveSessionID: UUID?
    @State private var liveDraftBaseText = ""
    @State private var livePreviewText = ""
    @State private var liveReconciler = LiveTranscriptReconciler()
    @State private var selectedLanguage: SpeechToTextManager.SupportedLanguage = RootView.defaultSupportedLanguage()
    @State private var selectedMode: CaptureMode = .postRecording
    private let liveDebugLoggingEnabled = true

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

                LiveAwareTextView(
                    text: $noteText,
                    highlightRequest: highlightRequest,
                    shouldAutoScrollLiveInsertion: selectedMode == .liveStreaming && isSpeechToTextSheetPresented
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
                   

                Spacer()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
            }
            .padding()
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
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            }
        }
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
        let insertedLength = trimmed.count
        let insertedStart = previous.isEmpty ? 0 : previous.count + 1
        highlightRequest = SpeechHighlightRequest(
            id: UUID(),
            range: NSRange(location: insertedStart, length: insertedLength)
        )
    }

    private func applyLiveTranscriptPartial(_ partial: LiveTranscriptPartial) {
        guard selectedMode == .liveStreaming else { return }

        if liveSessionID != partial.sessionID {
            liveSessionID = partial.sessionID
            liveDraftBaseText = noteText
            livePreviewText = ""
            liveReconciler.beginSession(partial.sessionID)
        }

        liveDebugLog("root_partial window=[\(partial.windowStartTime), \(partial.windowEndTime)] segments=\(partial.segments.count)")

        guard let renderState = liveReconciler.apply(partial) else { return }
        let preview = renderState.renderedText
        guard !preview.isEmpty else { return }
        let acceptedPreview = acceptedLivePreview(from: preview)
        guard acceptedPreview != livePreviewText else { return }
        livePreviewText = acceptedPreview

        let updatedNoteText = merge(liveDraftBaseText, with: acceptedPreview)
        let previous = noteText
        noteText = updatedNoteText
        let insertedSuffixLength = max(0, updatedNoteText.count - previous.count)
        applyHighlightForLatestLiveDelta(
            in: updatedNoteText,
            insertedSuffixLength: insertedSuffixLength > 0 ? insertedSuffixLength : acceptedPreview.count
        )
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
        liveDebugLog("final_commit=\"\(trimmed)\"")

        let merged = merge(liveDraftBaseText, with: trimmed)
        noteText = merged
        let insertedStart = liveDraftBaseText.isEmpty ? 0 : liveDraftBaseText.count + 1
        if insertedStart + trimmed.count <= merged.count {
            highlightRequest = SpeechHighlightRequest(
                id: UUID(),
                range: NSRange(location: insertedStart, length: trimmed.count)
            )
        }
        resetLiveDraftState(clearPreview: false)
    }

    private func resetLiveDraftState(clearPreview: Bool) {
        _ = clearPreview
        highlightRequest = nil
        liveSessionID = nil
        liveDraftBaseText = ""
        livePreviewText = ""
        liveReconciler.reset()
    }

    private func applyHighlightForLatestLiveDelta(in fullText: String, insertedSuffixLength: Int) {
        guard insertedSuffixLength > 0 else { return }
        let start = max(0, fullText.count - insertedSuffixLength)
        highlightRequest = SpeechHighlightRequest(
            id: UUID(),
            range: NSRange(location: start, length: insertedSuffixLength)
        )
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

private struct SpeechHighlightRequest: Equatable {
    let id: UUID
    let range: NSRange
}

private struct LiveAwareTextView: UIViewRepresentable {
    @Binding var text: String
    let highlightRequest: SpeechHighlightRequest?
    let shouldAutoScrollLiveInsertion: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .preferredFont(forTextStyle: .body)
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.text = text
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
            uiView.font = .preferredFont(forTextStyle: .body)
            uiView.textColor = .label
            if shouldAutoScrollLiveInsertion {
                DispatchQueue.main.async {
                    let safeOffset = max(0, uiView.contentSize.height - uiView.bounds.height + uiView.adjustedContentInset.bottom)
                    uiView.setContentOffset(CGPoint(x: 0, y: safeOffset), animated: true)
                }
            }
        }

        if let request = highlightRequest, context.coordinator.lastHandledHighlightID != request.id {
            context.coordinator.lastHandledHighlightID = request.id
            context.coordinator.applyHighlight(on: uiView, range: request.range)
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveAwareTextView
        var lastHandledHighlightID: UUID?

        init(_ parent: LiveAwareTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func applyHighlight(on textView: UITextView, range: NSRange) {
            guard range.location >= 0, range.length > 0 else { return }
            let totalLength = (textView.text as NSString).length
            guard NSMaxRange(range) <= totalLength else { return }

            textView.textStorage.addAttribute(
                .backgroundColor,
                value: UIColor.systemYellow.withAlphaComponent(0.35),
                range: range
            )

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak textView] in
                guard let textView else { return }
                let currentLength = (textView.text as NSString).length
                guard NSMaxRange(range) <= currentLength else { return }
                textView.textStorage.removeAttribute(.backgroundColor, range: range)
            }
        }

    }
}

#Preview {
    RootView()
}
