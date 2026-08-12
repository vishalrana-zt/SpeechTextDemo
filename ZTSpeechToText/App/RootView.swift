//
//  RootView.swift
//  Demo note screen that opens STT flow and receives transcript text.
//

import SwiftUI

struct RootView: View {

    @State private var noteText = ""
    @State private var isSpeechToTextSheetPresented = false
    @State private var hasLiveTranscriptDraft = false
    @State private var baseNoteTextBeforeLiveDraft = ""
    @State private var liveAccumulatedTranscript = ""
    @State private var lastLivePartialTranscript = ""
    @FocusState private var isNoteEditorFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                TextEditor(text: $noteText)
                    .font(.body)
                    .focused($isNoteEditorFocused)
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
                        isNoteEditorFocused = false
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
                        isNoteEditorFocused = false
                    }
                }
            }
        }
        .speechToTextSheet(
            isPresented: $isSpeechToTextSheetPresented,
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
            noteText = merge(baseNoteTextBeforeLiveDraft, with: liveAccumulatedTranscript)
            return
        }

        let delta = incrementalDelta(previous: lastLivePartialTranscript, current: trimmed)
        if !delta.isEmpty {
            if liveAccumulatedTranscript.isEmpty {
                liveAccumulatedTranscript = delta
            } else {
                liveAccumulatedTranscript += " " + delta
            }
            noteText = merge(baseNoteTextBeforeLiveDraft, with: liveAccumulatedTranscript)
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
            return
        }

        appendTranscript(trimmed)
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

#Preview {
    RootView()
}
