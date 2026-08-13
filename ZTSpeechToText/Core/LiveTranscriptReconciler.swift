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
}

struct LiveTranscriptRenderState: Equatable {
    let committedText: String
    let provisionalText: String
    let renderedText: String
}

struct LiveTranscriptReconciler {
    private(set) var sessionID: UUID?
    private var committedSegments: [LiveTranscriptSegment] = []
    private var provisionalSegments: [LiveTranscriptSegment] = []
    private var lastRenderedText: String = ""
    private var shortRegressionHoldCount: Int = 0

    /// Keep a small lead in the active window as provisional to allow Whisper to revise it.
    private let commitLeadSeconds: TimeInterval = 0.55
    private let overlapToleranceSeconds: TimeInterval = 0.08
    private let whisperControlTokenRegex = try! NSRegularExpression(
        pattern: #"<\|[^|>]+\|>"#,
        options: [.caseInsensitive]
    )
    private let multiWhitespaceRegex = try! NSRegularExpression(
        pattern: #"\s{2,}"#,
        options: []
    )

    mutating func beginSession(_ sessionID: UUID) {
        self.sessionID = sessionID
        committedSegments = []
        provisionalSegments = []
        lastRenderedText = ""
        shortRegressionHoldCount = 0
    }

    mutating func reset() {
        sessionID = nil
        committedSegments = []
        provisionalSegments = []
        lastRenderedText = ""
        shortRegressionHoldCount = 0
    }

    mutating func apply(_ partial: LiveTranscriptPartial) -> LiveTranscriptRenderState? {
        guard partial.sessionID == sessionID else { return nil }

        let incoming = normalize(segments: partial.segments)
        let commitCutoff = partial.windowStartTime + commitLeadSeconds

        let newlyStableFromPrevious = provisionalSegments.filter { $0.endTime <= commitCutoff }
        appendCommitted(newlyStableFromPrevious)

        let stableFromIncoming = incoming.filter { $0.endTime <= commitCutoff }
        appendCommitted(stableFromIncoming)

        provisionalSegments = incoming.filter { $0.endTime > commitCutoff }

        let state = renderState()
        let candidate = state.renderedText
        if !lastRenderedText.isEmpty,
           !candidate.isEmpty,
           candidate.count < Int(Double(lastRenderedText.count) * 0.55) {
            shortRegressionHoldCount += 1
            if shortRegressionHoldCount <= 2 {
                return LiveTranscriptRenderState(
                    committedText: "",
                    provisionalText: lastRenderedText,
                    renderedText: lastRenderedText
                )
            }
        } else {
            shortRegressionHoldCount = 0
        }

        lastRenderedText = candidate
        return state
    }

    mutating func finalize(sessionID: UUID, finalText: String) -> String? {
        guard sessionID == self.sessionID else { return nil }
        return finalText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private mutating func appendCommitted(_ candidates: [LiveTranscriptSegment]) {
        for segment in candidates {
            guard !segment.text.isEmpty else { continue }
            guard let last = committedSegments.last else {
                committedSegments.append(segment)
                continue
            }

            if segment.endTime <= last.endTime + overlapToleranceSeconds {
                continue
            }

            // Sliding windows often resend overlapping ranges that also extend
            // beyond the previous segment end. Merge that overlap instead of
            // dropping it, otherwise live text appears to "stall" until final.
            if segment.startTime <= last.endTime + overlapToleranceSeconds {
                let mergedText = appendText(last.text, segment.text)
                committedSegments[committedSegments.count - 1] = LiveTranscriptSegment(
                    startTime: min(last.startTime, segment.startTime),
                    endTime: max(last.endTime, segment.endTime),
                    text: mergedText
                )
                continue
            }

            committedSegments.append(segment)
        }
    }

    private func renderState() -> LiveTranscriptRenderState {
        let committedText = render(segments: committedSegments)
        let provisionalText = render(segments: provisionalSegments)
        let renderedText: String
        if committedText.isEmpty {
            renderedText = provisionalText
        } else if provisionalText.isEmpty {
            renderedText = committedText
        } else {
            renderedText = committedText + " " + provisionalText
        }
        return LiveTranscriptRenderState(
            committedText: committedText,
            provisionalText: provisionalText,
            renderedText: renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func render(segments: [LiveTranscriptSegment]) -> String {
        var output = ""
        for segment in segments {
            output = appendText(output, segment.text)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func appendText(_ base: String, _ addition: String) -> String {
        let extra = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !extra.isEmpty else { return base }
        guard !base.isEmpty else { return extra }
        if base.hasSuffix(extra) { return base }

        let baseWords = base.split(whereSeparator: \.isWhitespace).map(String.init)
        let extraWords = extra.split(whereSeparator: \.isWhitespace).map(String.init)
        let maxOverlap = min(8, min(baseWords.count, extraWords.count))
        if maxOverlap > 0 {
            for overlap in stride(from: maxOverlap, through: 1, by: -1) {
                let baseTail = baseWords.suffix(overlap).map(normalizeWord)
                let extraHead = extraWords.prefix(overlap).map(normalizeWord)
                if baseTail == extraHead {
                    let suffix = extraWords.dropFirst(overlap).joined(separator: " ")
                    guard !suffix.isEmpty else { return base }
                    return base + " " + suffix
                }
            }
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

    private func sanitizedSegmentText(_ text: String) -> String {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        let withoutTokens = whisperControlTokenRegex.stringByReplacingMatches(
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
}
