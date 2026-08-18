import Foundation

struct LiveTranscriptSegment: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

struct LiveTranscriptPartial: Sendable {
    let sessionID: UUID
    let windowStartTime: TimeInterval
    let windowEndTime: TimeInterval
    let segments: [LiveTranscriptSegment]
    let committedText: String?
    let volatileText: String?

    init(
        sessionID: UUID,
        windowStartTime: TimeInterval,
        windowEndTime: TimeInterval,
        segments: [LiveTranscriptSegment],
        committedText: String? = nil,
        volatileText: String? = nil
    ) {
        self.sessionID = sessionID
        self.windowStartTime = windowStartTime
        self.windowEndTime = windowEndTime
        self.segments = segments
        self.committedText = committedText
        self.volatileText = volatileText
    }
}

struct LiveTranscriptRenderState: Equatable {
    let committedText: String
    let provisionalText: String
    let renderedText: String
}

struct LiveTranscriptReconciler {
    private(set) var sessionID: UUID?
    private var committedText: String = ""
    private var provisionalSegments: [LiveTranscriptSegment] = []
    private var provisionalText: String = ""
    private var committedThroughTime: TimeInterval = 0
    private var updateCounter: Int = 0
    private var lastRenderedText: String = ""
    private var rejectedIncomingStreak: Int = 0
    private var pendingStableCommitChunk: String = ""
    private var pendingStableCommitHits: Int = 0

    /// Segments older than current rolling-window start minus this tolerance are
    /// moved from provisional to committed text.
    private let mutableWindowSafetySeconds: TimeInterval = 1.00
    private let controlTokenRegex = try! NSRegularExpression(
        pattern: #"<\|[^|>]+\|>"#,
        options: [.caseInsensitive]
    )
    private let multiWhitespaceRegex = try! NSRegularExpression(
        pattern: #"\s{2,}"#,
        options: []
    )
    private let mutableTailWordsForTextCommit = 10
    private let minimumWordsForTailCommit = 12
    private let maximumProvisionalWords = 18
    private let earlyCommitFreezeSeconds: TimeInterval = 3.0

    mutating func beginSession(_ sessionID: UUID) {
        self.sessionID = sessionID
        committedText = ""
        provisionalSegments = []
        provisionalText = ""
        committedThroughTime = 0
        updateCounter = 0
        lastRenderedText = ""
        rejectedIncomingStreak = 0
        pendingStableCommitChunk = ""
        pendingStableCommitHits = 0
    }

    mutating func reset() {
        sessionID = nil
        committedText = ""
        provisionalSegments = []
        provisionalText = ""
        committedThroughTime = 0
        updateCounter = 0
        lastRenderedText = ""
        rejectedIncomingStreak = 0
        pendingStableCommitChunk = ""
        pendingStableCommitHits = 0
    }

    mutating func apply(_ partial: LiveTranscriptPartial) -> LiveTranscriptRenderState? {
        guard partial.sessionID == sessionID else { return nil }

        updateCounter += 1
        let previousProvisionalText = provisionalText
        let incoming = normalize(segments: partial.segments)
        let commitBoundary = max(0, partial.windowStartTime - mutableWindowSafetySeconds)
        let shouldFreezeCommit = partial.windowEndTime < earlyCommitFreezeSeconds

        // 1) Commit prior provisional text that is now outside mutable window.
        let toCommit = shouldFreezeCommit ? [] : provisionalSegments.filter { $0.endTime <= commitBoundary }
        if !toCommit.isEmpty {
            let commitChunk = render(segments: toCommit)
            if !commitChunk.isEmpty {
                committedText = stitch(left: committedText, right: commitChunk)
            }
            committedThroughTime = max(committedThroughTime, toCommit.map(\.endTime).max() ?? committedThroughTime)
        }

        // Commit text that rolled out of the current Tiny hypothesis window.
        // Example:
        // previous: "S8 S9 S10", current: "S9 S10 S11" => commit "S8"
        if !shouldFreezeCommit,
           let rolledOutChunk = shiftedOutChunk(previous: previousProvisionalText, currentSegments: incoming),
           !rolledOutChunk.isEmpty {
            committedText = stitch(left: committedText, right: rolledOutChunk)
        }

        // 2) Retain only still-mutable prior provisional segments.
        provisionalSegments = provisionalSegments.filter { $0.endTime > commitBoundary }

        // 3) Replace mutable provisional region with current hypothesis.
        let incomingMutable = incoming.filter { $0.endTime > commitBoundary }
        if !incomingMutable.isEmpty {
            let candidateText = render(segments: incomingMutable)
            if shouldAcceptIncomingProvisional(previous: previousProvisionalText, incoming: candidateText) {
                provisionalSegments = incomingMutable
                provisionalText = candidateText
                rejectedIncomingStreak = 0
            } else {
                rejectedIncomingStreak += 1
                if rejectedIncomingStreak >= 2,
                   shouldForceRealign(previous: previousProvisionalText, incoming: candidateText) {
                    provisionalSegments = incomingMutable
                    provisionalText = candidateText
                    rejectedIncomingStreak = 0
                } else {
                    // Keep prior provisional on obviously regressive/noisy ticks.
                    provisionalText = render(segments: provisionalSegments)
                }
            }
        } else {
            // Keep last provisional when a tick is weak/empty to avoid flicker.
            provisionalText = render(segments: provisionalSegments)
            rejectedIncomingStreak = 0
        }

        // Rolling windows often emit one long mutable segment; time-based
        // commit can stall in that case. Commit only the stable shared prefix and
        // keep a small mutable tail to preserve live correction behavior.
        if !shouldFreezeCommit,
           let stableChunk = stableTextCommitChunk(previous: previousProvisionalText, current: provisionalText),
           !stableChunk.isEmpty {
            maybeCommitStableChunk(stableChunk)
        } else {
            pendingStableCommitChunk = ""
            pendingStableCommitHits = 0
        }
        provisionalText = trimCommittedPrefix(from: provisionalText, committed: committedText)
        enforceProvisionalTailLimit()

        var rendered = join(committedText: committedText, provisionalText: provisionalText)
        if rendered.count < lastRenderedText.count, rendered.count < Int(Double(lastRenderedText.count) * 0.75) {
            // Defensive guard: never allow large visual regressions in live text.
            // Only recent tail should revise; old history must remain visible.
            rendered = lastRenderedText
        } else {
            lastRenderedText = rendered
        }
        debugLog(
            sessionID: partial.sessionID,
            update: updateCounter,
            commitBoundary: commitBoundary,
            window: (partial.windowStartTime, partial.windowEndTime),
            incomingCount: incoming.count,
            commitCount: toCommit.count,
            committed: committedText,
            provisional: provisionalText
        )

        return LiveTranscriptRenderState(
            committedText: committedText,
            provisionalText: provisionalText,
            renderedText: rendered
        )
    }

    mutating func finalize(sessionID: UUID, finalText: String) -> String? {
        guard sessionID == self.sessionID else { return nil }
        let normalizedFinal = sanitize(finalText)
        debugLog(
            sessionID: sessionID,
            update: updateCounter,
            commitBoundary: committedThroughTime,
            window: (0, 0),
            incomingCount: 0,
            commitCount: 0,
            committed: committedText,
            provisional: provisionalText,
            final: normalizedFinal
        )
        return normalizedFinal
    }

    private func render(segments: [LiveTranscriptSegment]) -> String {
        var output = ""
        for segment in segments {
            output = stitch(left: output, right: segment.text)
        }
        return collapseRepeatedPhrases(in: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func join(committedText: String, provisionalText: String) -> String {
        if committedText.isEmpty { return provisionalText }
        if provisionalText.isEmpty { return committedText }
        return stitch(left: committedText, right: provisionalText)
    }

    private func stitch(left: String, right: String) -> String {
        let base = sanitize(left)
        let extra = sanitize(right)

        guard !extra.isEmpty else { return base }
        guard !base.isEmpty else { return extra }

        if base == extra { return base }
        if base.hasSuffix(extra) { return base }
        if extra.hasPrefix(base) { return extra }

        let baseWords = base.split(whereSeparator: \.isWhitespace).map(String.init)
        let extraWords = extra.split(whereSeparator: \.isWhitespace).map(String.init)
        if isLikelyEcho(extraWords: extraWords, inBaseWords: baseWords) {
            return base
        }
        let maxOverlap = min(12, min(baseWords.count, extraWords.count))

        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                let baseTail = baseWords.suffix(overlap).map(normalizeWord)
                let extraHead = extraWords.prefix(overlap).map(normalizeWord)
                if baseTail == extraHead {
                    let suffix = extraWords.dropFirst(overlap).joined(separator: " ")
                    guard !suffix.isEmpty else { return base }
                    return glue(base: base, extra: suffix)
                }
            }
        }

        return glue(base: base, extra: extra)
    }

    private func isLikelyEcho(extraWords: [String], inBaseWords baseWords: [String]) -> Bool {
        guard extraWords.count >= 6 else { return false }
        guard baseWords.count >= extraWords.count else { return false }

        let normalizedExtra = extraWords.map(normalizeWord)
        let normalizedBase = baseWords.map(normalizeWord)
        let tailStart = max(0, normalizedBase.count - 72)
        let tail = Array(normalizedBase[tailStart...])
        guard tail.count >= normalizedExtra.count else { return false }

        for start in 0...(tail.count - normalizedExtra.count) {
            let candidate = Array(tail[start..<(start + normalizedExtra.count)])
            if candidate == normalizedExtra {
                return true
            }
        }
        return false
    }

    private func glue(base: String, extra: String) -> String {
        guard !base.isEmpty else { return extra }
        guard !extra.isEmpty else { return base }

        if let first = extra.first, ".,!?;:)]}".contains(first) {
            return base.trimmingCharacters(in: .whitespacesAndNewlines) + extra
        }

        if base.hasSuffix("\n") || base.hasSuffix(" ") {
            return base + extra
        }

        return base + " " + extra
    }

    private func normalize(segments: [LiveTranscriptSegment]) -> [LiveTranscriptSegment] {
        segments
            .map { segment in
                LiveTranscriptSegment(
                    startTime: segment.startTime,
                    endTime: segment.endTime,
                    text: sanitizedSegmentText(segment.text)
                )
            }
            .filter { !$0.text.isEmpty && $0.endTime > $0.startTime }
            .sorted { lhs, rhs in
                if lhs.startTime == rhs.startTime {
                    return lhs.endTime < rhs.endTime
                }
                return lhs.startTime < rhs.startTime
            }
    }

    private func normalizeWord(_ word: String) -> String {
        word.lowercased().trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
    }

    private func sanitize(_ text: String) -> String {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let withoutTokens = controlTokenRegex.stringByReplacingMatches(
            in: text,
            options: [],
            range: fullRange,
            withTemplate: ""
        )
        let whitespaceRange = NSRange(location: 0, length: (withoutTokens as NSString).length)
        let normalizedWhitespace = multiWhitespaceRegex.stringByReplacingMatches(
            in: withoutTokens,
            options: [],
            range: whitespaceRange,
            withTemplate: " "
        )
        return normalizedWhitespace.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func collapseRepeatedPhrases(in text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 6 else { return text }

        var collapsed: [String] = []
        var index = 0

        while index < words.count {
            var consumed = false
            let maxChunkSize = min(10, (words.count - index) / 2)

            if maxChunkSize >= 2 {
                for chunkSize in stride(from: maxChunkSize, through: 2, by: -1) {
                    let firstStart = index
                    let firstEnd = index + chunkSize
                    let firstChunk = Array(words[firstStart..<firstEnd]).map(normalizeWord)
                    guard !firstChunk.allSatisfy({ $0.isEmpty }) else { continue }

                    var repeatCount = 1
                    while firstEnd + (repeatCount - 1) * chunkSize + chunkSize <= words.count {
                        let nextStart = firstEnd + (repeatCount - 1) * chunkSize
                        let nextEnd = nextStart + chunkSize
                        let nextChunk = Array(words[nextStart..<nextEnd]).map(normalizeWord)
                        if nextChunk == firstChunk {
                            repeatCount += 1
                        } else {
                            break
                        }
                    }

                    if repeatCount > 1 {
                        collapsed.append(contentsOf: words[firstStart..<firstEnd])
                        index = firstEnd + (repeatCount - 1) * chunkSize
                        consumed = true
                        break
                    }
                }
            }

            if !consumed {
                collapsed.append(words[index])
                index += 1
            }
        }

        return collapsed.joined(separator: " ")
    }

    private func stableTextCommitChunk(previous: String, current: String) -> String? {
        let old = sanitize(previous)
        let new = sanitize(current)
        guard !old.isEmpty, !new.isEmpty else { return nil }

        let sharedPrefix = commonPrefix(old, new)
        guard !sharedPrefix.isEmpty else { return nil }

        if let sentenceChunk = commitUntilLastSentenceBoundary(sharedPrefix) {
            return sentenceChunk
        }

        let words = sharedPrefix.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= minimumWordsForTailCommit else { return nil }
        let commitWordCount = max(0, words.count - mutableTailWordsForTextCommit)
        guard commitWordCount > 0 else { return nil }
        return words.prefix(commitWordCount).joined(separator: " ")
    }

    private mutating func maybeCommitStableChunk(_ chunk: String) {
        let normalized = sanitize(chunk)
        guard !normalized.isEmpty else { return }
        if pendingStableCommitChunk == normalized {
            pendingStableCommitHits += 1
        } else {
            pendingStableCommitChunk = normalized
            pendingStableCommitHits = 1
        }
        guard pendingStableCommitHits >= 2 else { return }
        committedText = stitch(left: committedText, right: normalized)
        pendingStableCommitChunk = ""
        pendingStableCommitHits = 0
    }

    private func commonPrefix(_ a: String, _ b: String) -> String {
        var result = ""
        var ia = a.startIndex
        var ib = b.startIndex
        while ia < a.endIndex, ib < b.endIndex, a[ia] == b[ib] {
            result.append(a[ia])
            ia = a.index(after: ia)
            ib = b.index(after: ib)
        }
        return sanitize(result)
    }

    private func commitUntilLastSentenceBoundary(_ text: String) -> String? {
        let chars = Array(text)
        guard let boundary = chars.lastIndex(where: { ".!?".contains($0) }) else {
            return nil
        }
        let prefix = String(chars[...boundary])
        let words = prefix.split(whereSeparator: \.isWhitespace)
        guard words.count >= 4 else { return nil }
        return sanitize(prefix)
    }

    private func trimCommittedPrefix(from provisional: String, committed: String) -> String {
        let base = sanitize(committed)
        let live = sanitize(provisional)
        guard !base.isEmpty, !live.isEmpty else { return live }
        guard live.count > base.count else { return live == base ? "" : live }

        if live.hasPrefix(base) {
            let idx = live.index(live.startIndex, offsetBy: base.count)
            return sanitize(String(live[idx...]))
        }

        let baseWords = base.split(whereSeparator: \.isWhitespace).map(String.init)
        let liveWords = live.split(whereSeparator: \.isWhitespace).map(String.init)
        let maxOverlap = min(baseWords.count, liveWords.count)
        guard maxOverlap > 0 else { return live }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let committedTail = baseWords.suffix(overlap).map(normalizeWord)
            let provisionalHead = liveWords.prefix(overlap).map(normalizeWord)
            if committedTail == provisionalHead {
                let tail = liveWords.dropFirst(overlap).joined(separator: " ")
                return sanitize(tail)
            }
        }

        return live
    }

    private mutating func enforceProvisionalTailLimit() {
        let words = provisionalText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > maximumProvisionalWords else { return }

        let overflowCount = words.count - maximumProvisionalWords
        let commitChunk = words.prefix(overflowCount).joined(separator: " ")
        let remaining = words.suffix(maximumProvisionalWords).joined(separator: " ")
        if !commitChunk.isEmpty {
            committedText = stitch(left: committedText, right: commitChunk)
        }
        provisionalText = sanitize(remaining)
    }

    private func sanitizedSegmentText(_ text: String) -> String {
        sanitize(text)
    }

    private func shiftedOutChunk(previous: String, currentSegments: [LiveTranscriptSegment]) -> String? {
        let old = sanitize(previous)
        let current = render(segments: currentSegments)
        guard !old.isEmpty, !current.isEmpty else { return nil }

        let oldWords = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let currentWords = current.split(whereSeparator: \.isWhitespace).map(String.init)
        let maxOverlap = min(oldWords.count, currentWords.count)
        guard maxOverlap > 0 else { return nil }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let oldTail = oldWords.suffix(overlap).map(normalizeWord)
            let currentHead = currentWords.prefix(overlap).map(normalizeWord)
            if oldTail == currentHead {
                let shifted = oldWords.dropLast(overlap).joined(separator: " ")
                let cleaned = sanitize(shifted)
                guard !cleaned.isEmpty else { return nil }
                let shiftedWords = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
                // Ignore tiny shifted-out fragments; these are often jitter artifacts.
                // Keep early short phrases so we don't lose the very start of speech.
                let minimumShiftedWords = committedText.isEmpty ? 2 : 4
                guard shiftedWords.count >= minimumShiftedWords else { return nil }
                // Avoid echoing text that's already in committed history.
                let committedTailWords = committedText
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .suffix(min(14, committedText.split(whereSeparator: \.isWhitespace).count))
                if !committedTailWords.isEmpty {
                    let shiftedHead = shiftedWords.prefix(min(shiftedWords.count, committedTailWords.count)).map(normalizeWord)
                    let committedTail = committedTailWords.suffix(shiftedHead.count).map(normalizeWord)
                    if shiftedHead == committedTail {
                        return nil
                    }
                }
                return cleaned
            }
        }

        return nil
    }

    private func shouldAcceptIncomingProvisional(previous: String, incoming: String) -> Bool {
        let old = sanitize(previous)
        let next = sanitize(incoming)
        guard !next.isEmpty else { return false }
        guard !old.isEmpty else { return true }
        if next.count >= old.count { return true }

        let oldWords = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let newWords = next.split(whereSeparator: \.isWhitespace).map(String.init)
        let shrinkRatio = Double(newWords.count) / Double(max(oldWords.count, 1))
        let maxOverlap = min(oldWords.count, newWords.count)
        if maxOverlap == 0 { return false }

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let oldTail = oldWords.suffix(overlap).map(normalizeWord)
            let newHead = newWords.prefix(overlap).map(normalizeWord)
            if oldTail == newHead {
                // For shorter replacements, require stronger overlap to avoid
                // accepting noisy regressions that chop stable context.
                if shrinkRatio < 0.75 {
                    return overlap >= 2
                }
                if shrinkRatio < 0.90 {
                    return overlap >= 1 && (overlap >= 2 || newWords.count <= 3)
                }
                return true
            }
        }
        return false
    }

    private func shouldForceRealign(previous: String, incoming: String) -> Bool {
        let old = sanitize(previous)
        let next = sanitize(incoming)
        guard !old.isEmpty, !next.isEmpty else { return false }

        let oldWords = old.split(whereSeparator: \.isWhitespace).map(String.init)
        let newWords = next.split(whereSeparator: \.isWhitespace).map(String.init)
        guard oldWords.count >= 5, newWords.count >= 5 else { return false }

        let overlap = normalizedWordOverlapRatio(lhs: oldWords, rhs: newWords)
        // Realign only when drift is persistent and overlap is low.
        return overlap < 0.45
    }

    private func normalizedWordOverlapRatio(lhs: [String], rhs: [String]) -> Double {
        let leftSet = Set(lhs.map(normalizeWord).filter { !$0.isEmpty })
        let rightSet = Set(rhs.map(normalizeWord).filter { !$0.isEmpty })
        guard !leftSet.isEmpty, !rightSet.isEmpty else { return 0 }
        let intersection = leftSet.intersection(rightSet).count
        let union = leftSet.union(rightSet).count
        guard union > 0 else { return 0 }
        return Double(intersection) / Double(union)
    }

    private func debugLog(
        sessionID: UUID,
        update: Int,
        commitBoundary: TimeInterval,
        window: (TimeInterval, TimeInterval),
        incomingCount: Int,
        commitCount: Int,
        committed: String,
        provisional: String,
        final: String? = nil
    ) {
        _ = sessionID
        _ = update
        _ = commitBoundary
        _ = window
        _ = incomingCount
        _ = commitCount
        _ = committed
        _ = provisional
        _ = final
    }
}
