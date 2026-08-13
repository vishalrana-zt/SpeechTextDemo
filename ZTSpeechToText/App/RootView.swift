//
//  RootView.swift
//  Demo note screen that opens STT flow and receives transcript text.
//

import SwiftUI
import UIKit

struct RootView: View {

    @State private var noteText = ""
    @State private var isSpeechToTextSheetPresented = false
    @State private var hasLiveTranscriptDraft = false
    @State private var baseNoteTextBeforeLiveDraft = ""
    @State private var liveAccumulatedTranscript = ""
    @State private var lastLivePartialTranscript = ""
    @State private var liveHighlightRequest: LiveHighlightRequest?
    @State private var preferredSTTLanguage: SpeechToTextManager.SupportedLanguage? = .english

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                LiveAwareTextView(
                    text: $noteText,
                    highlightRequest: liveHighlightRequest,
                    shouldAutoScrollLiveInsertion: hasLiveTranscriptDraft
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
            preferredLanguage: preferredSTTLanguage,
            onLiveTranscriptChanged: { partialText in
                applyLiveTranscriptDraft(partialText)
            },
            onTextReady: { transcribedText in
                commitFinalTranscript(transcribedText)
            }
        )
        .onChange(of: isSpeechToTextSheetPresented) { _, isPresented in
            if !isPresented, hasLiveTranscriptDraft {
                hasLiveTranscriptDraft = false
                baseNoteTextBeforeLiveDraft = noteText
                liveAccumulatedTranscript = ""
                lastLivePartialTranscript = ""
                liveHighlightRequest = nil
            }
        }
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
        let merged = merge(noteText, with: transcript)
        noteText = merged
    }

    private func applyLiveTranscriptDraft(_ partialText: String) {
        let trimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !hasLiveTranscriptDraft {
            baseNoteTextBeforeLiveDraft = noteText
            hasLiveTranscriptDraft = true
            liveAccumulatedTranscript = trimmed
            lastLivePartialTranscript = trimmed
            let updatedText = merge(baseNoteTextBeforeLiveDraft, with: liveAccumulatedTranscript)
            noteText = updatedText
            liveHighlightRequest = makeLiveHighlightRequest(in: updatedText, appendedChunk: trimmed)
            return
        }

        let delta = incrementalDelta(previous: lastLivePartialTranscript, current: trimmed)
        if !delta.isEmpty {
            if liveAccumulatedTranscript.isEmpty {
                liveAccumulatedTranscript = delta
            } else {
                liveAccumulatedTranscript += " " + delta
            }
            let updatedText = merge(baseNoteTextBeforeLiveDraft, with: liveAccumulatedTranscript)
            noteText = updatedText
            liveHighlightRequest = makeLiveHighlightRequest(in: updatedText, appendedChunk: delta)
        }
        lastLivePartialTranscript = trimmed
    }

    private func commitFinalTranscript(_ finalText: String) {
        let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

        if hasLiveTranscriptDraft {
            noteText = merge(baseNoteTextBeforeLiveDraft, with: trimmed)
            baseNoteTextBeforeLiveDraft = noteText
            hasLiveTranscriptDraft = false
            liveAccumulatedTranscript = ""
            lastLivePartialTranscript = ""
            liveHighlightRequest = nil
            return
        }

        appendTranscript(trimmed)
    }

    private func makeLiveHighlightRequest(in fullText: String, appendedChunk: String) -> LiveHighlightRequest? {
        let trimmedChunk = appendedChunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChunk.isEmpty else { return nil }
        let fullNSString = fullText as NSString
        let chunkNSString = trimmedChunk as NSString
        guard fullNSString.length >= chunkNSString.length else { return nil }
        let range = NSRange(location: fullNSString.length - chunkNSString.length, length: chunkNSString.length)
        return LiveHighlightRequest(range: range)
    }

    private func incrementalDelta(previous: String, current: String) -> String {
        let currentTrimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousTrimmed = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentTrimmed.isEmpty else { return "" }
        guard !previousTrimmed.isEmpty else { return currentTrimmed }
        if currentTrimmed == previousTrimmed { return "" }

        if currentTrimmed.hasPrefix(previousTrimmed) {
            return String(currentTrimmed.dropFirst(previousTrimmed.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if previousTrimmed.hasPrefix(currentTrimmed) {
            return ""
        }

        let overlap = longestSuffixPrefixOverlap(a: previousTrimmed, b: currentTrimmed)
        if overlap > 0 {
            return String(currentTrimmed.dropFirst(overlap))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return currentTrimmed
    }

    private func longestSuffixPrefixOverlap(a: String, b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let maxLen = min(aChars.count, bChars.count)
        guard maxLen > 0 else { return 0 }

        for len in stride(from: maxLen, through: 1, by: -1) {
            let aSuffix = aChars[(aChars.count - len)...]
            let bPrefix = bChars[0..<len]
            if Array(aSuffix).elementsEqual(bPrefix) {
                return len
            }
        }
        return 0
    }
}

private struct LiveHighlightRequest: Equatable {
    let id = UUID()
    let range: NSRange
}

private struct LiveAwareTextView: UIViewRepresentable {
    @Binding var text: String
    let highlightRequest: LiveHighlightRequest?
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
        }

        guard let highlightRequest else { return }
        guard context.coordinator.lastHandledHighlightID != highlightRequest.id else { return }
        context.coordinator.lastHandledHighlightID = highlightRequest.id
        context.coordinator.applyTemporaryHighlight(
            in: uiView,
            range: highlightRequest.range,
            requestID: highlightRequest.id,
            autoScrollToCenter: shouldAutoScrollLiveInsertion
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: LiveAwareTextView
        var lastHandledHighlightID: UUID?
        private var activeHighlightID: UUID?

        init(_ parent: LiveAwareTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func applyTemporaryHighlight(in textView: UITextView, range: NSRange, requestID: UUID, autoScrollToCenter: Bool) {
            let fullLength = (textView.text as NSString).length
            guard fullLength > 0, range.location != NSNotFound, NSMaxRange(range) <= fullLength else { return }

            activeHighlightID = requestID
            let selectedRange = textView.selectedRange

            let attributed = NSMutableAttributedString(string: textView.text)
            let fullRange = NSRange(location: 0, length: attributed.length)
            attributed.addAttribute(.font, value: UIFont.preferredFont(forTextStyle: .body), range: fullRange)
            attributed.addAttribute(.foregroundColor, value: UIColor.label, range: fullRange)
            attributed.addAttribute(.backgroundColor, value: UIColor.clear, range: fullRange)
            attributed.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.35), range: range)

            textView.attributedText = attributed
            textView.selectedRange = selectedRange

            if autoScrollToCenter {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.centerRange(range, in: textView)
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { [weak self, weak textView] in
                guard let self, let textView else { return }
                guard self.activeHighlightID == requestID else { return }

                let latestSelectedRange = textView.selectedRange
                textView.attributedText = NSAttributedString(
                    string: textView.text,
                    attributes: [
                        .font: UIFont.preferredFont(forTextStyle: .body),
                        .foregroundColor: UIColor.label
                    ]
                )
                textView.selectedRange = latestSelectedRange
            }
        }

        private func centerRange(_ range: NSRange, in textView: UITextView) {
            textView.layoutIfNeeded()
            textView.layoutManager.ensureLayout(for: textView.textContainer)

            let insertionIndex = min((textView.text as NSString).length, NSMaxRange(range))
            guard
                let insertionPosition = textView.position(from: textView.beginningOfDocument, offset: insertionIndex)
            else {
                return
            }

            // Caret-based centering is more stable than glyph-range bounding boxes
            // when attributed text is updated rapidly during live streaming.
            let caretRect = textView.caretRect(for: insertionPosition)
            let midY = caretRect.midY

            let minOffsetY = -textView.adjustedContentInset.top
            let maxOffsetY = max(
                minOffsetY,
                textView.contentSize.height - textView.bounds.height + textView.adjustedContentInset.bottom
            )
            let targetOffsetY = min(max(midY - (textView.bounds.height * 0.5), minOffsetY), maxOffsetY)
            textView.setContentOffset(CGPoint(x: 0, y: targetOffsetY), animated: false)
        }
    }
}

#Preview {
    RootView()
}
