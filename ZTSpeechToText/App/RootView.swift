//
//  RootView.swift
//  Demo note screen that opens STT flow and receives transcript text.
//

import SwiftUI

struct RootView: View {

    @State private var noteText = ""
    @State private var isSpeechToTextSheetPresented = false
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
            onTextReady: { transcribedText in
                if noteText.isEmpty {
                    noteText = transcribedText
                } else {
                    noteText += "\n" + transcribedText
                }
            }
        )
    }
}

#Preview {
    RootView()
}
