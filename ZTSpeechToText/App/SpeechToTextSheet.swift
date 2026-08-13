//
//  SpeechToTextSheet.swift
//  Reusable presenter for opening STT flow and returning transcribed text.
//

import SwiftUI
import UserNotifications

private struct SpeechToTextFlowSheet: View {

    @Environment(\.colorScheme) private var colorScheme

    @State private var modelState: SpeechToTextManager.ModelState = .notDownloaded
    @State private var didStartDownloadInThisSession = false
    @State private var isPreparingBundledModel = false
    @State private var wantsSetupCompletionNotification = false
    @State private var didHandleSetupCompletion = false
    @State private var hasCollapsedToCompactDownloadingBar = false
    @State private var showNotifyInfoAlert = false
    @State private var notifyInfoTitle = ""
    @State private var notifyInfoMessage = ""
    @State private var shouldAutoStartRecording = true
    @State private var showSetupReadyAlert = false

    private let manager = SpeechToTextManager.shared
    private let compactDownloadBarPreferenceKey = "SpeechToTextFlowSheet.prefersCompactDownloadBar"
    let preferredLanguage: SpeechToTextManager.SupportedLanguage?
    let onLiveTranscriptChanged: (String) -> Void
    let onTextReady: (String) -> Void
    let onSetupReady: () -> Void
    let onCloseRequested: () -> Void

    var body: some View {
        panelView
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .onAppear {
                hasCollapsedToCompactDownloadingBar = UserDefaults.standard.bool(forKey: compactDownloadBarPreferenceKey)
                modelState = manager.modelState
                shouldAutoStartRecording = true

                manager.onModelStateChange = { state in
                    DispatchQueue.main.async { modelState = state }
                }

                if manager.isBundledModelSource {
                    isPreparingBundledModel = true
                    Task {
                        await manager.prepareOnOptIn()
                        await MainActor.run {
                            isPreparingBundledModel = false
                        }
                    }
                } else if manager.hasOptedIn {
                    Task { await manager.restoreIfAlreadyDownloaded() }
                } else {
                    startDownloadIfNeeded()
                }
            }
            .onDisappear {
                manager.onModelStateChange = nil
            }
            .onChange(of: modelState) { _, newState in
                if case .downloading = newState {
                    didStartDownloadInThisSession = true
                }

                guard didStartDownloadInThisSession, !didHandleSetupCompletion else { return }
                if case .ready = newState {
                    didHandleSetupCompletion = true
                    UserDefaults.standard.set(false, forKey: compactDownloadBarPreferenceKey)
                    hasCollapsedToCompactDownloadingBar = false

                    if wantsSetupCompletionNotification {
                        scheduleSetupReadyNotification()
                    }
                    shouldAutoStartRecording = true
                    didStartDownloadInThisSession = true
                    showSetupReadyAlert = true
                    onSetupReady()
                }
            }
            .alert(notifyInfoTitle, isPresented: $showNotifyInfoAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notifyInfoMessage)
            }
            .alert("One-time model setup ready", isPresented: $showSetupReadyAlert) {
                Button("OK", role: .cancel) {
                    didStartDownloadInThisSession = false
                }
            } message: {
                Text("Speech-to-text can now run fully offline.")
            }
    }

    @ViewBuilder
    private var panelView: some View {
        if case .ready = modelState, !didStartDownloadInThisSession {
            RecordScreen(
                autoStartOnAppear: shouldAutoStartRecording,
                preferredLanguage: preferredLanguage,
                onLiveTranscriptChanged: { text in
                    onLiveTranscriptChanged(text)
                },
                onTranscriptReady: { text in
                    onTextReady(text)
                },
                onProcessingCompleted: {
                    onCloseRequested()
                }
            )
        } else if manager.isBundledModelSource, isPreparingBundledModel {
            bundledPreparingView
        } else {
            DownloadScreen(
                modelState: modelState,
                onPrimaryActionTapped: {
                    startDownloadIfNeeded(force: true)
                },
                onNotifyTapped: {
                    requestNotifyPermissionAndShowMessage()
                    hasCollapsedToCompactDownloadingBar = true
                    UserDefaults.standard.set(true, forKey: compactDownloadBarPreferenceKey)
                },
                onCompactDismissTapped: {
                    onCloseRequested()
                },
                showCompactDownloadingBar: hasCollapsedToCompactDownloadingBar
            )
        }
    }

    private var bundledPreparingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Model Setup")
                        .font(.headline)
                    TimelineView(.periodic(from: .now, by: 0.6)) { context in
                        let step = Int(context.date.timeIntervalSinceReferenceDate * (1.0 / 0.6)) % 4
                        Text(bundledLoadingText + String(repeating: ".", count: step))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ProgressView()
                .controlSize(.regular)
        }
        .padding(14)
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

    private var bundledLoadingText: String {
        if case .loadingModel(let loaded, let total) = modelState {
            return "Loading bundled models (\(loaded) of \(total) loaded)"
        }
        return "Loading bundled model"
    }

    private func startDownloadIfNeeded(force: Bool = false) {
        if manager.isBundledModelSource {
            isPreparingBundledModel = true
            Task {
                await manager.prepareOnOptIn()
                await MainActor.run {
                    isPreparingBundledModel = false
                }
            }
            return
        }

        guard force || !didStartDownloadInThisSession else { return }
        didStartDownloadInThisSession = true
        Task { await manager.prepareOnOptIn() }
    }

    private func requestNotifyPermissionAndShowMessage() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async {
                if granted {
                    wantsSetupCompletionNotification = true
                    notifyInfoTitle = "We’ll Notify You"
                    notifyInfoMessage = "You’ll get a notification when the one-time model download is complete."
                } else {
                    notifyInfoTitle = "Notification Permission Needed"
                    notifyInfoMessage = "Notifications are off. Enable them in Settings to get a setup-complete alert."
                }
                showNotifyInfoAlert = true
            }
        }
    }

    private func scheduleSetupReadyNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Model Setup Ready"
        content.body = "One-time model setup is complete. Speech-to-text is now available offline."
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1.0, repeats: false)
        let request = UNNotificationRequest(identifier: "stt.setup.ready", content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
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

private struct SpeechToTextSheetModifier: ViewModifier {

    @Binding var isPresented: Bool
    let preferredLanguage: SpeechToTextManager.SupportedLanguage?
    let onLiveTranscriptChanged: (String) -> Void
    let onTextReady: (String) -> Void
    let onSetupReady: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    SpeechToTextFlowSheet(
                        preferredLanguage: preferredLanguage,
                        onLiveTranscriptChanged: { text in
                            onLiveTranscriptChanged(text)
                        },
                        onTextReady: { text in
                            onTextReady(text)
                        },
                        onSetupReady: {
                            onSetupReady()
                        },
                        onCloseRequested: {
                            isPresented = false
                        }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isPresented)
    }
}

extension View {
    func speechToTextSheet(
        isPresented: Binding<Bool>,
        preferredLanguage: SpeechToTextManager.SupportedLanguage? = nil,
        onLiveTranscriptChanged: @escaping (String) -> Void = { _ in },
        onTextReady: @escaping (String) -> Void,
        onSetupReady: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            SpeechToTextSheetModifier(
                isPresented: isPresented,
                preferredLanguage: preferredLanguage,
                onLiveTranscriptChanged: onLiveTranscriptChanged,
                onTextReady: onTextReady,
                onSetupReady: onSetupReady
            )
        )
    }
}
