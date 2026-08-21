import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum TextAISupportedLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case french = "fr"
    case spanish = "es"

    nonisolated var displayName: String {
        switch self {
        case .english: return "English"
        case .french: return "French"
        case .spanish: return "Spanish"
        }
    }

    nonisolated var localeIdentifier: String {
        switch self {
        case .english: return "en"
        case .french: return "fr"
        case .spanish: return "es"
        }
    }

    nonisolated var responseLanguageInstruction: String {
        switch self {
        case .english: return "English"
        case .french: return "French"
        case .spanish: return "Spanish"
        }
    }
}

enum TextAIOperation: String, Sendable {
    case cleanup
    case summarize
}

enum TextAISummaryStyle: String, CaseIterable, Sendable {
    case short
    case standard
    case detailed

    nonisolated var displayName: String {
        switch self {
        case .short: return "Short"
        case .standard: return "Standard"
        case .detailed: return "Detailed"
        }
    }
}

struct TextAIRequest: Sendable {
    let operation: TextAIOperation
    let text: String
    let preferredLanguage: TextAISupportedLanguage
    let summaryStyle: TextAISummaryStyle?
}

enum TextAIProviderID: String, Sendable {
    case appleFoundationModels
    case bundledLocalLLM

    nonisolated var displayName: String {
        switch self {
        case .appleFoundationModels: return "Apple Foundation Models"
        case .bundledLocalLLM: return "Bundled Offline LLM"
        }
    }
}

struct TextAIExecutionResult: Sendable {
    let provider: TextAIProviderID
    let outputText: String
}

enum TextAIError: LocalizedError, Sendable {
    case emptyInput
    case offlineModelUnavailable
    case providerUnavailable(reason: String)
    case modelUnavailable(reason: String)
    case modelLoadingFailed(reason: String)
    case inferenceFailed(reason: String)
    case unsupportedOperation
    case unsupportedLanguage
    case memoryResourceFailure
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Please enter text before running AI processing."
        case .offlineModelUnavailable:
            return "Offline AI model is unavailable."
        case let .providerUnavailable(reason):
            return "Provider unavailable: \(reason)"
        case let .modelUnavailable(reason):
            return "Model unavailable: \(reason)"
        case let .modelLoadingFailed(reason):
            return "Model loading failed: \(reason)"
        case let .inferenceFailed(reason):
            return "Inference failed: \(reason)"
        case .unsupportedOperation:
            return "Unsupported operation."
        case .unsupportedLanguage:
            return "Unsupported language for this model."
        case .memoryResourceFailure:
            return "The device is low on resources for offline inference."
        case .cancelled:
            return "The operation was cancelled."
        }
    }
}

protocol OfflineTextModelProvider: Sendable {
    nonisolated var id: TextAIProviderID { get }
    func process(_ request: TextAIRequest) async throws -> String
}

actor TextAIProviderResolver {
    struct Resolution: Sendable {
        let provider: any OfflineTextModelProvider
        let fallbackReason: String?
    }

    private var bundledProvider: BundledLocalLLMProvider?
    private let forceBundledLocalLLMForTesting: Bool

    init(forceBundledLocalLLMForTesting: Bool = false) {
        self.forceBundledLocalLLMForTesting = forceBundledLocalLLMForTesting
    }

    func resolveProvider(for request: TextAIRequest) async -> Resolution {
        if forceBundledLocalLLMForTesting {
            TextAILogger.log("provider=bundledLocalLLM")
            TextAILogger.log("fallbackReason=forcedBundledForTesting")
            return Resolution(provider: await bundledProviderInstance(), fallbackReason: "forcedBundledForTesting")
        }

        if #available(iOS 26.0, *) {
            #if canImport(FoundationModels)
            let appleProvider = await AppleFoundationModelProvider()
            let appleAvailability = await appleProvider.capability(for: request.preferredLanguage)
            if case .available = appleAvailability {
                TextAILogger.log("provider=appleFoundationModels")
                TextAILogger.log("providerAvailability=available")
                return Resolution(provider: appleProvider, fallbackReason: nil)
            }

            TextAILogger.log("provider=bundledLocalLLM")
            TextAILogger.log("fallbackReason=foundationModelsUnavailable")
            TextAILogger.log("providerAvailability=\(appleAvailability.logValue)")
            return Resolution(provider: await bundledProviderInstance(), fallbackReason: "foundationModelsUnavailable")
            #else
            TextAILogger.log("provider=bundledLocalLLM")
            TextAILogger.log("fallbackReason=foundationModelsFrameworkUnavailable")
            return Resolution(provider: await bundledProviderInstance(), fallbackReason: "foundationModelsFrameworkUnavailable")
            #endif
        }

        TextAILogger.log("provider=bundledLocalLLM")
        TextAILogger.log("fallbackReason=osBelow26")
        return Resolution(provider: await bundledProviderInstance(), fallbackReason: "osBelow26")
    }

    func fallbackBundledProvider(reason: String) async -> any OfflineTextModelProvider {
        TextAILogger.log("provider=bundledLocalLLM")
        TextAILogger.log("fallbackReason=\(reason)")
        return await bundledProviderInstance()
    }

    func preferredProviderDisplayName(for language: TextAISupportedLanguage) async -> String {
        let request = TextAIRequest(operation: .cleanup, text: "ping", preferredLanguage: language, summaryStyle: nil)
        let resolution = await resolveProvider(for: request)
        return resolution.provider.id.displayName
    }

    private func bundledProviderInstance() async -> BundledLocalLLMProvider {
        if let bundledProvider {
            return bundledProvider
        }
        let created = await BundledLocalLLMProvider()
        bundledProvider = created
        return created
    }
}

actor TextAIService {
    private let resolver: TextAIProviderResolver

    init(resolver: TextAIProviderResolver = TextAIProviderResolver()) {
        self.resolver = resolver
    }

    func cleanup(text: String, preferredLanguage: TextAISupportedLanguage) async throws -> TextAIExecutionResult {
        let request = TextAIRequest(
            operation: .cleanup,
            text: text,
            preferredLanguage: preferredLanguage,
            summaryStyle: nil
        )
        return try await process(request)
    }

    func summarize(
        text: String,
        preferredLanguage: TextAISupportedLanguage,
        style: TextAISummaryStyle
    ) async throws -> TextAIExecutionResult {
        let request = TextAIRequest(
            operation: .summarize,
            text: text,
            preferredLanguage: preferredLanguage,
            summaryStyle: style
        )
        return try await process(request)
    }

    func preferredProviderDisplayName(for language: TextAISupportedLanguage) async -> String {
        await resolver.preferredProviderDisplayName(for: language)
    }

    private func process(_ request: TextAIRequest) async throws -> TextAIExecutionResult {
        try Task.checkCancellation()

        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TextAIError.emptyInput
        }

        TextAILogger.log("operation=\(request.operation.rawValue)")
        TextAILogger.log("preferredLanguage=\(request.preferredLanguage.rawValue)")

        let normalizedRequest = TextAIRequest(
            operation: request.operation,
            text: trimmed,
            preferredLanguage: request.preferredLanguage,
            summaryStyle: request.summaryStyle
        )

        let resolution = await resolver.resolveProvider(for: normalizedRequest)

        do {
            let output = try await resolution.provider.process(normalizedRequest)
            return TextAIExecutionResult(provider: resolution.provider.id, outputText: output)
        } catch {
            if resolution.provider.id == .appleFoundationModels {
                let fallbackProvider = await resolver.fallbackBundledProvider(reason: "appleFoundationModelsInferenceFailure")
                do {
                    let output = try await fallbackProvider.process(normalizedRequest)
                    return TextAIExecutionResult(provider: fallbackProvider.id, outputText: output)
                } catch {
                    throw mapProviderError(error)
                }
            }
            throw mapProviderError(error)
        }
    }

    private func mapProviderError(_ error: Error) -> TextAIError {
        if error is CancellationError {
            return .cancelled
        }
        if let textAIError = error as? TextAIError {
            return textAIError
        }

        let nsError = error as NSError
        if nsError.localizedDescription.localizedCaseInsensitiveContains("out of memory") {
            return .memoryResourceFailure
        }
        return .inferenceFailed(reason: nsError.localizedDescription)
    }
}

actor BundledLocalLLMProvider: OfflineTextModelProvider {
    nonisolated let id: TextAIProviderID = .bundledLocalLLM
    private var runtimeEngine: (any BundledLocalLLMRuntimeEngine)?
    private let configuration = BundledLocalLLMConfiguration.default

    func process(_ request: TextAIRequest) async throws -> String {
        try Task.checkCancellation()
        let engine = try await ensureEngineLoaded()
        let prompt = promptText(for: request)
        let inputCharacterCount = request.text.count
        let maxTokens: Int
        if request.operation == .cleanup {
            maxTokens = configuration.cleanupMaxTokens
        } else {
            switch request.summaryStyle ?? .standard {
            case .short:
                maxTokens = configuration.shortSummaryMaxTokens
            case .standard:
                maxTokens = configuration.standardSummaryMaxTokens
            case .detailed:
                maxTokens = configuration.detailedSummaryMaxTokens
            }
        }
        let startedAt = Date()
        TextAILogger.log("bundledModel contextReset operation=\(request.operation.rawValue)")
        try await engine.resetContext()
        TextAILogger.log("bundledModel inferenceStart operation=\(request.operation.rawValue) language=\(request.preferredLanguage.rawValue) inputChars=\(inputCharacterCount)")
        TextAILogger.log("bundledModel generationConfig operation=\(request.operation.rawValue) maxTokens=\(maxTokens) temperature=\(configuration.temperature) topP=\(configuration.topP) stopCount=\(configuration.stopSequences.count)")
        TextAILogger.logPayload("bundledModel input", text: request.text)
        TextAILogger.logPayload("bundledModel prompt", text: prompt)

        do {
            let rawOutput = try await engine.generate(
                prompt: prompt,
                maxTokens: maxTokens,
                temperature: configuration.temperature,
                topP: configuration.topP,
                stopSequences: configuration.stopSequences
            )

            let output = sanitizeModelOutput(
                rawOutput,
                originalInput: request.text,
                operation: request.operation
            )

            guard !output.isEmpty else {
                throw TextAIError.inferenceFailed(reason: "bundledModelEmptyOutput")
            }
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            TextAILogger.logPayload("bundledModel output", text: output)
            TextAILogger.log("bundledModel inferenceEnd operation=\(request.operation.rawValue) language=\(request.preferredLanguage.rawValue) latencyMs=\(latencyMs) inputChars=\(inputCharacterCount) outputChars=\(output.count)")
            return output
        } catch is CancellationError {
            await engine.cancelGeneration()
            throw TextAIError.cancelled
        } catch let textAIError as TextAIError {
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            TextAILogger.log("bundledModel inferenceFailed operation=\(request.operation.rawValue) language=\(request.preferredLanguage.rawValue) latencyMs=\(latencyMs) inputChars=\(inputCharacterCount) error=\(textAIError.localizedDescription)")
            throw textAIError
        } catch {
            let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            TextAILogger.log("bundledModel inferenceFailed operation=\(request.operation.rawValue) language=\(request.preferredLanguage.rawValue) latencyMs=\(latencyMs) inputChars=\(inputCharacterCount) error=\(error.localizedDescription)")
            throw TextAIError.inferenceFailed(reason: error.localizedDescription)
        }
    }

    private func ensureEngineLoaded() async throws -> any BundledLocalLLMRuntimeEngine {
        if let runtimeEngine {
            return runtimeEngine
        }

        guard let modelURL = modelURLInBundle() else {
            TextAILogger.log("provider=bundledLocalLLM")
            TextAILogger.log("fallbackReason=bundledModelFileMissing")
            throw TextAIError.offlineModelUnavailable
        }

        #if canImport(LlamaSPM)
        let createdEngine: (any BundledLocalLLMRuntimeEngine)? = await LlamaCppRuntimeEngine(modelURL: modelURL)
        #else
        let createdEngine: (any BundledLocalLLMRuntimeEngine)? = nil
        #endif

        guard let createdEngine else {
            TextAILogger.log("provider=bundledLocalLLM")
            TextAILogger.log("fallbackReason=bundledRuntimeMissing")
            TextAILogger.log("bundledModel modelLoadFailed reason=bundledRuntimeMissing")
            throw TextAIError.modelLoadingFailed(reason: "Bundled runtime is not linked.")
        }

        do {
            TextAILogger.log("bundledModel loading runtime=\(configuration.runtime.rawValue) model=\(configuration.modelFileName)")
            try await createdEngine.loadIfNeeded()
            runtimeEngine = createdEngine
            TextAILogger.log("provider=bundledLocalLLM")
            TextAILogger.log("bundledRuntime=\(configuration.runtime.rawValue)")
            TextAILogger.log("bundledModel=\(configuration.modelFileName)")
            TextAILogger.log("bundledModel loaded runtime=\(configuration.runtime.rawValue) model=\(configuration.modelFileName)")
            return createdEngine
        } catch is CancellationError {
            throw TextAIError.cancelled
        } catch {
            TextAILogger.log("bundledModel modelLoadFailed reason=\(error.localizedDescription)")
            throw TextAIError.modelLoadingFailed(reason: error.localizedDescription)
        }
    }

    private func modelURLInBundle() -> URL? {
        let bundle = Bundle.main
        let subdirectories = [
            configuration.modelSubdirectory,
            "Resource/Models",
            "Models",
            ""
        ]

        for subdirectory in subdirectories where !subdirectory.isEmpty {
            if let url = bundle.url(
                forResource: configuration.modelResourceName,
                withExtension: configuration.modelFileExtension,
                subdirectory: subdirectory
            ) {
                return url
            }
        }

        return bundle.url(
            forResource: configuration.modelResourceName,
            withExtension: configuration.modelFileExtension
        )
    }
    
    private func promptText(for request: TextAIRequest) -> String {
        let language = request.preferredLanguage.responseLanguageInstruction
        let userPrompt: String

        switch request.operation {
        case .cleanup:
            userPrompt = """
            Clean up the following speech-to-text transcript.

            Language: \(language)

            Return only the corrected transcript.

            Rules:
            - Keep the original language. Do not translate.
            - Preserve the original meaning and intent.
            - Fix grammar, spelling, capitalization, punctuation, and obvious sentence structure issues.
            - Apply standard sentence capitalization and proper-noun capitalization.
            - Fix obvious speech-to-text errors when the intended word is clear from context.
            - If a word is uncertain, keep the original word.
            - Preserve names, numbers, dates, URLs, email addresses, and technical terms.
            - Do not add information.
            - Do not remove meaningful information.
            - If there are obvious writing errors, do not return the transcript unchanged.
            - Do not summarize.
            - Do not explain the changes.

            Transcript:
            \(request.text)
            """

        case .summarize:
            let style: String
            switch request.summaryStyle ?? .standard {
            case .short:
                style = "Style: 1 to 2 sentences."
            case .standard:
                style = "Style: 3 to 5 sentences."
            case .detailed:
                style = "Style: 6 to 10 sentences."
            }

            userPrompt = """
            Summarize the following speech-to-text transcript.

            Language: \(language)

            Return only the summary.

            Rules:
            - Keep the original language. Do not translate.
            - Keep the main meaning and important facts.
            - Keep important decisions, actions, names, numbers, dates, and conclusions.
            - Remove repetition, filler, and unnecessary details.
            - Do not invent or assume information.
            - Do not add information that is not in the transcript.
            - Do not explain the summary.

            \(style)

            Transcript:
            \(request.text)
            """
        }

        return """
        <|im_start|>system
        You are a careful text processing assistant. Follow the user instructions exactly. Return only the requested output text.
        <|im_end|>
        <|im_start|>user
        \(userPrompt)
        <|im_end|>
        <|im_start|>assistant
        """
    }

    private func sanitizeModelOutput(
        _ output: String,
        originalInput: String,
        operation: TextAIOperation
    ) -> String {
        let original = originalInput
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var value = output
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            return original
        }

        // Remove markdown code fences without assuming a language.
        if value.hasPrefix("```") {
            if let firstNewline = value.firstIndex(of: "\n") {
                value = String(value[value.index(after: firstNewline)...])
            } else {
                value = value.replacingOccurrences(of: "```", with: "")
            }

            if value.hasSuffix("```") {
                value.removeLast(3)
            }

            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Remove common model/template prefixes.
        let prefixes = [
            "Sure, here is the improved text:",
            "Sure, here's the improved text:",
            "Here is the improved text:",
            "Improved text:",
            "Sure, here is the cleaned text:",
            "Sure, here's the cleaned text:",
            "Here is the cleaned text:",
            "Cleaned text:",
            "Sure, here is the corrected text:",
            "Sure, here's the corrected text:",
            "Here is the corrected text:",
            "Corrected text:",
            "Sure, here is the summary:",
            "Sure, here's the summary:",
            "Here is the summary:",
            "Summary:"
        ]

        for prefix in prefixes {
            if value.range(
                of: prefix,
                options: [.caseInsensitive, .anchored]
            ) != nil {
                value = String(value.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Remove template labels only when they appear as a standalone
        // line/section marker. Do not split based on English sentence logic.
        let delimiters = [
            "\nOutput:",
            "\nAnswer:",
            "\nResult:",
            "\nResponse:"
        ]

        for delimiter in delimiters {
            if let range = value.range(
                of: delimiter,
                options: [.caseInsensitive]
            ) {
                value = String(value[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Remove leaked chat-template markers from output if emitted verbatim.
        let chatMarkers = ["<|im_end|>", "<|im_start|>", "<|endoftext|>"]
        for marker in chatMarkers {
            value = value.replacingOccurrences(of: marker, with: "")
        }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            return original
        }

        // Cleanup-specific protection against model repetition/hallucination.
        if operation == .cleanup {
            value = removeRepeatedContent(value)

            guard !value.isEmpty else {
                return original
            }

            // A cleanup operation should normally not produce output that is
            // dramatically larger than the source text. This protects against
            // small local models generating repeated/hallucinated content.
            if isAbnormallyExpandedOutput(
                originalInput: original,
                output: value
            ) {
                return original
            }
        }

        return value
    }

    private func removeRepeatedContent(_ text: String) -> String {
        let lines = text
            .components(separatedBy: .newlines)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter {
                !$0.isEmpty
            }

        guard !lines.isEmpty else {
            return ""
        }

        // Remove exact repeated lines/paragraphs while preserving order.
        var seenBlocks = Set<String>()
        var uniqueBlocks: [String] = []

        for line in lines {
            let key = normalizedComparisonKey(line)

            guard !key.isEmpty else {
                continue
            }

            if !seenBlocks.contains(key) {
                seenBlocks.insert(key)
                uniqueBlocks.append(line)
            }
        }

        let merged = uniqueBlocks.joined(separator: " ")

        guard !merged.isEmpty else {
            return ""
        }

        // Detect repeated blocks without relying on English punctuation.
        //
        // Example:
        // "I went home and I was tired. I went home and I was tired.
        //  I went home and I was tired."
        //
        // This works across English, Spanish, French, etc. because it compares
        // normalized text rather than English-specific sentence rules.
        let words = merged.split(whereSeparator: \.isWhitespace)

        guard words.count >= 8 else {
            return merged.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var result = merged

        // Look for a repeated prefix/block of at least 4 words.
        let maxBlockWords = min(words.count / 2, 40)

        for blockSize in stride(
            from: maxBlockWords,
            through: 4,
            by: -1
        ) {
            let blockWords = Array(words.prefix(blockSize))

            let blockKey = normalizedComparisonKey(
                blockWords.joined(separator: " ")
            )

            guard !blockKey.isEmpty else {
                continue
            }

            var occurrenceCount = 0
            var searchStart = 0

            while searchStart + blockSize <= words.count {
                let candidate = words[
                    searchStart..<(searchStart + blockSize)
                ]

                let candidateKey = normalizedComparisonKey(
                    candidate.joined(separator: " ")
                )

                if candidateKey == blockKey {
                    occurrenceCount += 1
                    searchStart += blockSize
                } else {
                    searchStart += 1
                }
            }

            // If the same block appears repeatedly, keep only the first
            // occurrence and preserve everything after it that is different.
            if occurrenceCount >= 2 {
                let firstBlock = blockWords.joined(separator: " ")

                let remainingWords = Array(words.dropFirst(blockSize))

                let remainingText = remainingWords.joined(separator: " ")

                if !remainingText.isEmpty {
                    let remainingKey = normalizedComparisonKey(remainingText)

                    if remainingKey == blockKey {
                        result = firstBlock
                    }
                }

                break
            }
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedComparisonKey(_ text: String) -> String {
        text
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: nil
            )
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func isAbnormallyExpandedOutput(
        originalInput: String,
        output: String
    ) -> Bool {
        let input = originalInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = output.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !input.isEmpty, !result.isEmpty else {
            return false
        }

        let inputLength = input.count
        let outputLength = result.count

        // For very small inputs, use a slightly more conservative threshold.
        let multiplier: Double

        if inputLength < 50 {
            multiplier = 5.0
        } else if inputLength < 150 {
            multiplier = 4.0
        } else {
            multiplier = 3.0
        }

        // Absolute expansion threshold prevents a long legitimate cleanup
        // from being rejected just because of a small ratio.
        let exceedsRatio = Double(outputLength) > Double(inputLength) * multiplier
        let exceedsAbsoluteExpansion = outputLength - inputLength > 500

        return exceedsRatio && exceedsAbsoluteExpansion
    }
}

private struct BundledLocalLLMConfiguration: Sendable {
    let runtime: BundledLocalLLMRuntime
    let modelResourceName: String
    let modelFileExtension: String
    let modelSubdirectory: String
    let cleanupMaxTokens: Int
    let shortSummaryMaxTokens: Int
    let standardSummaryMaxTokens: Int
    let detailedSummaryMaxTokens: Int
    let temperature: Float
    let topP: Float
    let stopSequences: [String]

    nonisolated var modelFileName: String {
        "\(modelResourceName).\(modelFileExtension)"
    }

    nonisolated static let `default` = BundledLocalLLMConfiguration(
        runtime: .llamaCpp,
        modelResourceName: "Qwen2.5-0.5B-Instruct-Q4_K_M",
        modelFileExtension: "gguf",
        modelSubdirectory: "Resource/Models",
        cleanupMaxTokens: 160,
        shortSummaryMaxTokens: 120,
        standardSummaryMaxTokens: 200,
        detailedSummaryMaxTokens: 280,
        temperature: 0.1,
        topP: 0.9,
        stopSequences: ["<|im_end|>", "<|endoftext|>"]
    )
}

private enum BundledLocalLLMRuntime: String, Sendable {
    case llamaCpp
}

private protocol BundledLocalLLMRuntimeEngine: Sendable {
    func loadIfNeeded() async throws
    func resetContext() async throws
    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stopSequences: [String]
    ) async throws -> String
    func cancelGeneration() async
}

#if canImport(LlamaSPM)
import LlamaSPM

private actor LlamaCppRuntimeEngine: BundledLocalLLMRuntimeEngine {
    private let runner: LlamaModel
    private var isLoaded = false

    init(modelURL: URL) {
        self.runner = LlamaModel(modelPath: modelURL.path)
    }

    func loadIfNeeded() async throws {
        guard !isLoaded else { return }
        try await runner.load()
        isLoaded = true
    }

    func resetContext() async throws {
        try await runner.resetForNewRequest()
    }

    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stopSequences: [String]
    ) async throws -> String {
        try await runner.generate(
            prompt: prompt,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            stopSequences: stopSequences
        )
    }

    func cancelGeneration() async {
        await runner.cancel()
    }
}
#endif

#if canImport(FoundationModels)
@available(iOS 26.0, *)
private enum AppleProviderCapability: Sendable {
    case available
    case unavailable(reason: String)

    nonisolated var logValue: String {
        switch self {
        case .available:
            return "available"
        case let .unavailable(reason):
            return "unavailable_\(reason)"
        }
    }
}

@available(iOS 26.0, *)
actor AppleFoundationModelProvider: OfflineTextModelProvider {
    nonisolated let id: TextAIProviderID = .appleFoundationModels
    private let model = SystemLanguageModel.default

    fileprivate func capability(for language: TextAISupportedLanguage) -> AppleProviderCapability {
        if !model.isAvailable {
            return .unavailable(reason: "modelNotAvailable")
        }

        switch model.availability {
        case .available:
            break
        case let .unavailable(reason):
            return .unavailable(reason: "availability_\(String(describing: reason))")
        }

        let locale = Locale(identifier: language.localeIdentifier)
        guard model.supportsLocale(locale) else {
            return .unavailable(reason: "unsupportedLocale")
        }

        return .available
    }

    func process(_ request: TextAIRequest) async throws -> String {
        try Task.checkCancellation()

        let capabilityResult = capability(for: request.preferredLanguage)
        guard case .available = capabilityResult else {
            throw TextAIError.modelUnavailable(reason: capabilityResult.logValue)
        }

        let instructions = baseInstructions(for: request)
        let prompt = promptText(for: request)
        TextAILogger.logPayload("appleModel input", text: request.text)
        TextAILogger.logPayload("appleModel prompt", text: prompt)

        do {
            let session = LanguageModelSession(model: model, instructions: instructions)
            let response = try await session.respond(to: prompt)
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else {
                throw TextAIError.inferenceFailed(reason: "emptyResponse")
            }
            TextAILogger.logPayload("appleModel output", text: content)
            return content
        } catch is CancellationError {
            throw TextAIError.cancelled
        } catch let generationError as LanguageModelSession.GenerationError {
            switch generationError {
            case .unsupportedLanguageOrLocale:
                throw TextAIError.unsupportedLanguage
            default:
                throw TextAIError.inferenceFailed(reason: String(describing: generationError))
            }
        } catch {
            throw TextAIError.inferenceFailed(reason: error.localizedDescription)
        }
    }

    private func baseInstructions(for request: TextAIRequest) -> String {
        switch request.operation {
        case .cleanup:
            return """
            You improve text quality while preserving meaning.
            You MUST respond in \(request.preferredLanguage.responseLanguageInstruction).
            Keep the original language and never translate.
            Fix grammar, spelling, punctuation, and sentence flow.
            Preserve names, numbers, dates, URLs, technical terms, and facts.
            Do not add new facts.
            Return only the improved text.
            """
        case .summarize:
            let styleInstruction: String
            switch request.summaryStyle ?? .standard {
            case .short:
                styleInstruction = "Write a short summary in 1 to 2 sentences."
            case .standard:
                styleInstruction = "Write a concise summary in 3 to 5 sentences."
            case .detailed:
                styleInstruction = "Write a detailed summary in 6 to 10 sentences."
            }

            return """
            You summarize text while preserving the source facts.
            You MUST respond in \(request.preferredLanguage.responseLanguageInstruction).
            Keep the original language and never translate.
            Do not invent facts.
            \(styleInstruction)
            Return only the summary.
            """
        }
    }

    private func promptText(for request: TextAIRequest) -> String {
        switch request.operation {
        case .cleanup:
            return "Improve this text:\n\n\(request.text)"
        case .summarize:
            return "Summarize this text:\n\n\(request.text)"
        }
    }
}
#endif

private enum TextAILogger {
    nonisolated static func log(_ message: String) {
        #if DEBUG
        print("[TEXT_AI] \(message)")
        #endif
    }

    nonisolated static func logPayload(_ label: String, text: String, maxChars: Int = 400) {
        #if DEBUG
        let normalized = text.replacingOccurrences(of: "\n", with: "\\n")
        let clipped: String
        if normalized.count > maxChars {
            let index = normalized.index(normalized.startIndex, offsetBy: maxChars)
            clipped = String(normalized[..<index]) + "…"
        } else {
            clipped = normalized
        }
        print("[TEXT_AI] \(label)=\(clipped)")
        #endif
    }
}
