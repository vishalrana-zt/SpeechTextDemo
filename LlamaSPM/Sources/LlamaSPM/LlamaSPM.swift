import Foundation
import llama

public enum LlamaSPMError: LocalizedError {
    case modelNotLoaded
    case contextInitializationFailed
    case decodingFailed

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Model is not loaded."
        case .contextInitializationFailed:
            return "Failed to initialize llama context."
        case .decodingFailed:
            return "llama decoding failed."
        }
    }
}

private func llamaBatchClear(_ batch: inout llama_batch) {
    batch.n_tokens = 0
}

private func llamaBatchAdd(
    _ batch: inout llama_batch,
    token: llama_token,
    position: llama_pos,
    sequenceIDs: [llama_seq_id],
    logits: Bool
) {
    batch.token[Int(batch.n_tokens)] = token
    batch.pos[Int(batch.n_tokens)] = position
    batch.n_seq_id[Int(batch.n_tokens)] = Int32(sequenceIDs.count)
    for index in 0..<sequenceIDs.count {
        batch.seq_id[Int(batch.n_tokens)]?[index] = sequenceIDs[index]
    }
    batch.logits[Int(batch.n_tokens)] = logits ? 1 : 0
    batch.n_tokens += 1
}

public actor LlamaModel {
    private let modelPath: String
    private let contextSize: Int32

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var vocab: OpaquePointer?
    private var isLoaded = false
    private var shouldCancel = false

    public init(modelPath: String, contextSize: Int32 = 4096) {
        self.modelPath = modelPath
        self.contextSize = contextSize
    }

    deinit {
        if let context {
            llama_free(context)
        }
        if let model {
            llama_model_free(model)
        }
        llama_backend_free()
    }

    public func load() throws {
        guard !isLoaded else { return }

        llama_backend_init()

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #endif

        guard let loadedModel = llama_model_load_from_file(modelPath, modelParams) else {
            throw NSError(
                domain: "LlamaSPM",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load GGUF model"]
            )
        }

        let threadCount = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextSize)
        contextParams.n_threads = Int32(threadCount)
        contextParams.n_threads_batch = Int32(threadCount)

        guard let loadedContext = llama_init_from_model(loadedModel, contextParams) else {
            llama_model_free(loadedModel)
            throw LlamaSPMError.contextInitializationFailed
        }

        self.model = loadedModel
        self.context = loadedContext
        self.vocab = llama_model_get_vocab(loadedModel)
        self.isLoaded = true
    }

    public func cancel() {
        shouldCancel = true
    }

    public func resetForNewRequest() throws {
        guard let context else {
            throw LlamaSPMError.modelNotLoaded
        }
        llama_memory_clear(llama_get_memory(context), true)
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        stopSequences: [String]
    ) async throws -> String {
        _ = topP // Current sampler chain uses temperature + distribution.
        if !isLoaded {
            try load()
        }

        guard let context, let vocab else {
            throw LlamaSPMError.modelNotLoaded
        }

        shouldCancel = false

        let promptTokens = tokenize(text: prompt, addBOS: false)
        if promptTokens.isEmpty {
            return ""
        }

        let nCtx = Int(llama_n_ctx(context))
        if promptTokens.count + maxTokens > nCtx {
            throw NSError(
                domain: "LlamaSPM",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Input exceeds context window."]
            )
        }

        var batch = llama_batch_init(Int32(max(512, promptTokens.count + 1)), 0, 1)
        defer {
            llama_batch_free(batch)
        }

        let samplerParams = llama_sampler_chain_default_params()
        guard let sampler = llama_sampler_chain_init(samplerParams) else {
            throw NSError(
                domain: "LlamaSPM",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to initialize sampler."]
            )
        }
        defer {
            llama_sampler_free(sampler)
        }

        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(topP, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_penalties(64, 1.15, 0.0, 0.0))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(1234))

        llamaBatchClear(&batch)
        for (index, token) in promptTokens.enumerated() {
            llamaBatchAdd(
                &batch,
                token: token,
                position: Int32(index),
                sequenceIDs: [0],
                logits: false
            )
        }
        batch.logits[Int(batch.n_tokens) - 1] = 1

        if llama_decode(context, batch) != 0 {
            throw LlamaSPMError.decodingFailed
        }

        var position = batch.n_tokens
        var generatedTokenCount = 0
        var utf8Buffer: [CChar] = []
        var output = ""

        while generatedTokenCount < maxTokens {
            try Task.checkCancellation()
            if shouldCancel {
                throw CancellationError()
            }

            let token = llama_sampler_sample(sampler, context, batch.n_tokens - 1)
            if llama_vocab_is_eog(vocab, token) {
                break
            }

            let tokenPiece = tokenToPiece(vocab: vocab, token: token)
            utf8Buffer.append(contentsOf: tokenPiece)

            if let piece = String(validatingUTF8: utf8Buffer + [0]) {
                output += piece
                utf8Buffer.removeAll(keepingCapacity: true)
            }

            if stopSequences.contains(where: { output.hasSuffix($0) }) {
                break
            }

            llamaBatchClear(&batch)
            llamaBatchAdd(
                &batch,
                token: token,
                position: position,
                sequenceIDs: [0],
                logits: true
            )

            if llama_decode(context, batch) != 0 {
                throw LlamaSPMError.decodingFailed
            }

            position += 1
            generatedTokenCount += 1
        }

        return output
    }

    private func tokenize(text: String, addBOS: Bool) -> [llama_token] {
        guard let vocab else { return [] }
        let utf8Count = text.utf8.count
        let tokenBufferCapacity = utf8Count + (addBOS ? 1 : 0) + 8

        let tokenBuffer = UnsafeMutablePointer<llama_token>.allocate(capacity: tokenBufferCapacity)
        defer {
            tokenBuffer.deallocate()
        }

        let tokenCount = llama_tokenize(
            vocab,
            text,
            Int32(utf8Count),
            tokenBuffer,
            Int32(tokenBufferCapacity),
            addBOS,
            false
        )

        guard tokenCount > 0 else { return [] }

        var tokens: [llama_token] = []
        tokens.reserveCapacity(Int(tokenCount))
        for index in 0..<Int(tokenCount) {
            tokens.append(tokenBuffer[index])
        }
        return tokens
    }

    private func tokenToPiece(vocab: OpaquePointer, token: llama_token) -> [CChar] {
        let smallBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 8)
        smallBuffer.initialize(repeating: 0, count: 8)
        defer {
            smallBuffer.deallocate()
        }

        let pieceLength = llama_token_to_piece(vocab, token, smallBuffer, 8, 0, false)
        if pieceLength >= 0 {
            return Array(UnsafeBufferPointer(start: smallBuffer, count: Int(pieceLength)))
        }

        let requiredCount = Int(-pieceLength)
        let dynamicBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: requiredCount)
        dynamicBuffer.initialize(repeating: 0, count: requiredCount)
        defer {
            dynamicBuffer.deallocate()
        }

        let fullLength = llama_token_to_piece(vocab, token, dynamicBuffer, Int32(requiredCount), 0, false)
        guard fullLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: dynamicBuffer, count: Int(fullLength)))
    }
}
