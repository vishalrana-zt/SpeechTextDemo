//
//  DownloadScreen.swift
//  Compact bottom panel shown until the on-device model is downloaded and ready.
//

import SwiftUI

struct DownloadScreen: View {

    @Environment(\.colorScheme) private var colorScheme

    let modelState: SpeechToTextManager.ModelState
    let modeTitle: String
    let onPrimaryActionTapped: () -> Void
    let onNotifyTapped: () -> Void
    let onCompactDismissTapped: () -> Void
    let showCompactDownloadingBar: Bool

    @State private var lastSampleTime: Date?
    @State private var lastDownloadedBytes: Int64?
    @State private var downloadStartTime: Date?
    @State private var rateSamples: [(time: Date, downloadedBytes: Int64)] = []
    @State private var estimatedBytesPerSecond: Double = 0

    init(
        modelState: SpeechToTextManager.ModelState,
        modeTitle: String = "Speech",
        onPrimaryActionTapped: @escaping () -> Void,
        onNotifyTapped: @escaping () -> Void = {},
        onCompactDismissTapped: @escaping () -> Void = {},
        showCompactDownloadingBar: Bool = false
    ) {
        self.modelState = modelState
        self.modeTitle = modeTitle
        self.onPrimaryActionTapped = onPrimaryActionTapped
        self.onNotifyTapped = onNotifyTapped
        self.onCompactDismissTapped = onCompactDismissTapped
        self.showCompactDownloadingBar = showCompactDownloadingBar
    }

    var body: some View {
        Group {
            if showCompactDownloadingBar,
               case .downloading(let status) = modelState,
               displayedProgress(for: status) < 0.999 {
                compactDownloadingBar(status: status)
            } else {
                regularPanel
            }
        }
        .onAppear {
            if case .downloading(let status) = modelState {
                updateDownloadMetrics(for: status)
            }
        }
        .onChange(of: modelState) { _, newValue in
            if case .downloading(let status) = newValue {
                updateDownloadMetrics(for: status)
            } else {
                resetDownloadMetrics()
            }
        }
    }

    private var regularPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch modelState {
            case .notDownloaded:
                Text("\(modeTitle) model needs to be downloaded. After setup, transcription works fully offline.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Enable Offline Setup", action: onPrimaryActionTapped)
                    .buttonStyle(.borderedProminent)

            case .downloading(let status):
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Setting up model")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    }
                    Spacer()
                    if displayedProgress(for: status) < 0.995 {
                        Button("Notify Me", action: onNotifyTapped)
                            .font(.caption)
                            .controlSize(.small)
                            .buttonStyle(.bordered)
                    }
                }
                HStack(spacing: 10) {
                    ProgressView(value: displayedProgress(for: status))
                        .frame(maxWidth: .infinity)

                    Text("\(Int((displayedProgress(for: status) * 100).rounded()))%")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 42, alignment: .trailing)
                }
                if let metricsText {
                    Text(metricsText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Preparing offline speech recognition.\nKeeping this open can help it finish faster.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .loadingModel:
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Finalizing model...")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text("Almost done. This may take a few seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

            case .ready:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.green)

            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                Button("Retry", action: onPrimaryActionTapped)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(panelFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(panelBorderColor, lineWidth: 1)
                )
        )
        .shadow(color: panelShadowColor, radius: 14, y: 4)
    }

    private func compactDownloadingBar(status: SpeechToTextManager.DownloadStatus) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(modeTitle) model download")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ProgressView(value: displayedProgress(for: status))

                if let metricsText {
                    Text(metricsText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(Int((displayedProgress(for: status) * 100).rounded()))%")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)

            Button("Dismiss", action: onCompactDismissTapped)
                .font(.caption)
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(panelFillColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(panelBorderColor, lineWidth: 1)
                )
        )
        .shadow(color: panelShadowColor, radius: 10, y: 3)
    }

    private var metricsText: String? {
        guard case .downloading(let status) = modelState else { return nil }

        guard hasReliableByteTelemetry(for: status),
              estimatedBytesPerSecond > 0,
              let downloadStartTime,
              Date().timeIntervalSince(downloadStartTime) >= 5,
              status.downloadedBytes >= 20_000_000,
              displayedProgress(for: status) < 0.995 else {
            return nil
        }

        let remainingBytes = status.totalBytes - status.downloadedBytes
        guard remainingBytes > 0 else { return nil }
        let remainingSeconds = Double(remainingBytes) / estimatedBytesPerSecond
        if remainingSeconds < 3, displayedProgress(for: status) < 0.9 {
            return nil
        }
        let eta = formatDuration(seconds: remainingSeconds)
        return "About \(eta) left"
    }

    private func updateDownloadMetrics(for status: SpeechToTextManager.DownloadStatus) {
        let now = Date()
        if downloadStartTime == nil {
            downloadStartTime = now
        }

        if hasReliableByteTelemetry(for: status) {
            if let lastDownloadedBytes, status.downloadedBytes >= lastDownloadedBytes {
                rateSamples.append((time: now, downloadedBytes: status.downloadedBytes))
            } else if lastDownloadedBytes == nil {
                rateSamples.append((time: now, downloadedBytes: status.downloadedBytes))
            }

            let windowStart = now.addingTimeInterval(-12)
            rateSamples.removeAll { $0.time < windowStart }

            if let firstSample = rateSamples.first, let lastSample = rateSamples.last, firstSample.time < lastSample.time {
                let windowElapsed = lastSample.time.timeIntervalSince(firstSample.time)
                let windowBytes = lastSample.downloadedBytes - firstSample.downloadedBytes
                if windowElapsed > 0.5, windowBytes > 0 {
                    let windowRate = Double(windowBytes) / windowElapsed

                    if let downloadStartTime {
                        let totalElapsed = now.timeIntervalSince(downloadStartTime)
                        if totalElapsed > 1, status.downloadedBytes > 0 {
                            let lifetimeRate = Double(status.downloadedBytes) / totalElapsed
                            let conservativeRate = min(windowRate, lifetimeRate * 1.2)
                            estimatedBytesPerSecond = smoothedRate(current: estimatedBytesPerSecond, newSample: conservativeRate)
                        } else {
                            estimatedBytesPerSecond = smoothedRate(current: estimatedBytesPerSecond, newSample: windowRate)
                        }
                    }
                }
            }
        }

        self.lastSampleTime = now
        self.lastDownloadedBytes = status.downloadedBytes
    }

    private func resetDownloadMetrics() {
        lastSampleTime = nil
        lastDownloadedBytes = nil
        downloadStartTime = nil
        rateSamples.removeAll()
        estimatedBytesPerSecond = 0
    }

    private func displayedProgress(for status: SpeechToTextManager.DownloadStatus) -> Double {
        if hasReliableByteTelemetry(for: status), status.totalBytes > 0 {
            return max(0, min(1, Double(status.downloadedBytes) / Double(status.totalBytes)))
        }
        return max(0, min(1, status.progress))
    }

    private func hasReliableByteTelemetry(for status: SpeechToTextManager.DownloadStatus) -> Bool {
        status.totalBytes >= 1_000_000 && status.downloadedBytes >= 0 && status.downloadedBytes <= status.totalBytes
    }

    private func smoothedRate(current: Double, newSample: Double) -> Double {
        guard newSample.isFinite, newSample > 0 else { return current }
        guard current > 0 else { return newSample }
        return (0.8 * current) + (0.2 * newSample)
    }

    private func formatDuration(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "less than 1 sec" }

        if seconds < 1 {
            return "less than 1 sec"
        }

        if seconds < 60 {
            return "\(Int(seconds.rounded())) sec"
        }

        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 {
            return "\(minutes) min"
        }

        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if remainingMinutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(remainingMinutes)m"
    }

    private var panelFillColor: Color {
        if colorScheme == .dark {
            return Color(.secondarySystemBackground).opacity(0.92)
        }
        return Color(.systemBackground).opacity(0.97)
    }

    private var panelBorderColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.12)
        }
        return Color.black.opacity(0.09)
    }

    private var panelShadowColor: Color {
        if colorScheme == .dark {
            return Color.black.opacity(0.35)
        }
        return Color.black.opacity(0.14)
    }
}

#Preview("Not downloaded") {
    DownloadScreen(modelState: .notDownloaded, onPrimaryActionTapped: {})
}

#Preview("Downloading") {
    DownloadScreen(
        modelState: .downloading(.init(progress: 0.42, downloadedBytes: 210_000_000, totalBytes: 500_000_000)),
        onPrimaryActionTapped: {},
        showCompactDownloadingBar: true
    )
}

#Preview("Failed") {
    DownloadScreen(modelState: .failed("Network error"), onPrimaryActionTapped: {})
}
