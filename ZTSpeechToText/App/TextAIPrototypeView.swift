import SwiftUI
import UIKit


struct TextAIPrototypeView: View {
    @Environment(\.dismiss) private var dismiss
    private let service = TextAIService(
        resolver: TextAIProviderResolver(forceBundledLocalLLMForTesting: false)
    )

    @State private var inputText = "i went to the office yesterday and i did not finish my work because the meeting was too long."
    @State private var resultText = ""
    @State private var selectedLanguage: TextAISupportedLanguage = .english
    @State private var summaryStyle: TextAISummaryStyle = .standard
    @State private var providerLabel = "Resolving…"
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var activeTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Language", selection: $selectedLanguage) {
                    ForEach(TextAISupportedLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)

                Text("Input")
                    .font(.headline)

                PrototypeTextView(text: $inputText)
                    .frame(minHeight: 180)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color(.separator), lineWidth: 1)
                    )

                Picker("Summary Style", selection: $summaryStyle) {
                    ForEach(TextAISummaryStyle.allCases, id: \.self) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    Button("Cleanup") {
                        runCleanup()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing)

                    Button("Summarize") {
                        runSummarization()
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProcessing)

                    if isProcessing {
                        Button("Cancel") {
                            activeTask?.cancel()
                        }
                        .buttonStyle(.borderless)
                    }
                }

                Text("Provider: \(providerLabel)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if isProcessing {
                    ProgressView("Processing…")
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                Text("Result")
                    .font(.headline)

                ScrollView {
                    Text(resultText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(minHeight: 140)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.separator), lineWidth: 1)
                )
            }
            .padding()
            .navigationTitle("Offline Text AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                refreshProviderLabel()
            }
            .onChange(of: selectedLanguage) { _ in
                refreshProviderLabel()
            }
            .onDisappear {
                activeTask?.cancel()
            }
        }
    }

    private func refreshProviderLabel() {
        Task {
            let value = await service.preferredProviderDisplayName(for: selectedLanguage)
            await MainActor.run {
                providerLabel = value
            }
        }
    }

    private func runCleanup() {
        runOperation {
            try await service.cleanup(text: inputText, preferredLanguage: selectedLanguage)
        }
    }

    private func runSummarization() {
        runOperation {
            try await service.summarize(
                text: inputText,
                preferredLanguage: selectedLanguage,
                style: summaryStyle
            )
        }
    }

    private func runOperation(_ operation: @escaping @Sendable () async throws -> TextAIExecutionResult) {
        activeTask?.cancel()

        activeTask = Task {
            await MainActor.run {
                isProcessing = true
                errorMessage = nil
            }

            do {
                let response = try await operation()
                await MainActor.run {
                    providerLabel = response.provider.displayName
                    resultText = response.outputText
                    isProcessing = false
                }
            } catch {
                let message: String
                if let typedError = error as? TextAIError {
                    message = typedError.localizedDescription
                } else {
                    message = error.localizedDescription
                }

                await MainActor.run {
                    isProcessing = false
                    errorMessage = message
                }
            }
        }
    }
}

private struct PrototypeTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .secondarySystemBackground
        view.text = text
        view.isScrollEnabled = true
        view.inputAccessoryView = context.coordinator.makeKeyboardAccessoryToolbar()
        context.coordinator.attach(textView: view)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding private var text: String
        private weak var textView: UITextView?

        init(text: Binding<String>) {
            _text = text
        }

        func attach(textView: UITextView) {
            self.textView = textView
        }

        func makeKeyboardAccessoryToolbar() -> UIToolbar {
            let toolbar = UIToolbar()
            toolbar.sizeToFit()

            let flexibleSpace = UIBarButtonItem(systemItem: .flexibleSpace)
            let doneButton = UIBarButtonItem(
                title: "Done",
                style: .done,
                target: self,
                action: #selector(doneButtonTapped)
            )

            toolbar.items = [flexibleSpace, doneButton]
            return toolbar
        }

        @objc
        private func doneButtonTapped() {
            textView?.resignFirstResponder()
        }

        func textViewDidChange(_ textView: UITextView) {
            text = textView.text
        }
    }
}
