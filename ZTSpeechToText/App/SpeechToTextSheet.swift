//
//  SpeechToTextSheet.swift
//  Reusable presenter for opening STT flow and returning transcribed text.
//

import SwiftUI
import UserNotifications
import UIKit

struct SpeechToTextSheetConfiguration {
    var preferredLanguage: SpeechToTextManager.SupportedLanguage? = nil
    var operationMode: SpeechToTextManager.OperationMode = .liveStreaming
    var initialLiveTranscriptionEnabled: Bool? = nil
    var showsLiveTranscriptionToggle: Bool = false
    var livePartialMaxAudioSeconds: Double = 12.0
    var livePartialMinimumAudioSeconds: Double = 0.8
    var livePollingIntervalNanoseconds: UInt64 = 1_200_000_000
}

private struct SpeechToTextFlowSheet: View {

    @Environment(\.colorScheme) private var colorScheme

    @State private var modelState: SpeechToTextManager.ModelState = .notDownloaded
    @State private var didStartDownloadInThisSession = false
    @State private var isPreparingBundledModel = false
    @State private var wantsSetupCompletionNotification = false
    @State private var hasCollapsedToCompactDownloadingBar = false
    @State private var showNotifyInfoAlert = false
    @State private var notifyInfoTitle = ""
    @State private var notifyInfoMessage = ""
    @State private var shouldAutoStartRecording = false

    private let manager = SpeechToTextManager.shared
    let configuration: SpeechToTextSheetConfiguration
    let onLiveTranscriptChanged: (LiveTranscriptPartial) -> Void
    let onTextReady: (UUID, String) -> Void
    let onSetupReady: () -> Void
    let onCloseRequested: () -> Void

    var body: some View {
        panelView
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil,
                            from: nil,
                            for: nil
                        )
                    }
                }
            }
            .onAppear {
                manager.onModelStateChange = { state in
                    DispatchQueue.main.async { modelState = state }
                }
                applyModeSelection(configuration.operationMode, shouldKickoffSetup: true)
            }
            .onDisappear {
                manager.onModelStateChange = nil
            }
            .onChange(of: configuration.operationMode) { _, newMode in
                applyModeSelection(newMode, shouldKickoffSetup: true)
            }
            .onChange(of: modelState) { _, newState in
                if case .downloading = newState {
                    didStartDownloadInThisSession = true
                }
                if case .loadingModel = newState {
                    didStartDownloadInThisSession = true
                }

                guard didStartDownloadInThisSession else { return }
                if case .ready = newState {
                    UserDefaults.standard.set(false, forKey: compactDownloadBarPreferenceKey)
                    hasCollapsedToCompactDownloadingBar = false

                    if wantsSetupCompletionNotification {
                        scheduleSetupReadyNotification()
                        wantsSetupCompletionNotification = false
                    }
                    onSetupReady()
                }
            }
            .alert(notifyInfoTitle, isPresented: $showNotifyInfoAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(notifyInfoMessage)
            }
    }

    @ViewBuilder
    private var panelView: some View {
        if case .ready = modelState {
            RecordScreen(
                autoStartOnAppear: shouldAutoStartRecording,
                preferredLanguage: configuration.preferredLanguage,
                initialLiveTranscriptionEnabled: configuration.initialLiveTranscriptionEnabled,
                showsLiveTranscriptionToggle: configuration.showsLiveTranscriptionToggle,
                livePartialMaxAudioSeconds: configuration.livePartialMaxAudioSeconds,
                livePartialMinimumAudioSeconds: configuration.livePartialMinimumAudioSeconds,
                livePollingIntervalNanoseconds: configuration.livePollingIntervalNanoseconds,
                onLiveTranscriptChanged: { partial in
                    onLiveTranscriptChanged(partial)
                },
                onTranscriptReady: { sessionID, text in
                    onTextReady(sessionID, text)
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
                modeTitle: modeTitle,
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

                TimelineView(.periodic(from: .now, by: 0.6)) { context in
                    let step = Int(context.date.timeIntervalSinceReferenceDate * (1.0 / 0.6)) % 4
                    Text(bundledLoadingText + String(repeating: ".", count: step))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
        return "Loading model"
    }

    private var compactDownloadBarPreferenceKey: String {
        "SpeechToTextFlowSheet.prefersCompactDownloadBar.\(configuration.operationMode.rawValue)"
    }

    private var modeTitle: String {
        switch configuration.operationMode {
        case .liveStreaming:
            return "Live streaming"
        case .postRecording:
            return "Post recording"
        }
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

    private func applyModeSelection(_ mode: SpeechToTextManager.OperationMode, shouldKickoffSetup: Bool) {
        manager.setOperationMode(mode)
        hasCollapsedToCompactDownloadingBar = UserDefaults.standard.bool(forKey: compactDownloadBarPreferenceKey)
        modelState = manager.modelState(for: mode)
        shouldAutoStartRecording = false

        if case .downloading = modelState {
            didStartDownloadInThisSession = true
        } else if case .loadingModel = modelState {
            didStartDownloadInThisSession = true
        } else {
            didStartDownloadInThisSession = false
        }

        guard shouldKickoffSetup else { return }
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
    let configuration: SpeechToTextSheetConfiguration
    let onLiveTranscriptChanged: (LiveTranscriptPartial) -> Void
    let onTextReady: (UUID, String) -> Void
    let onSetupReady: () -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    SpeechToTextFlowSheet(
                        configuration: configuration,
                        onLiveTranscriptChanged: { partial in
                            onLiveTranscriptChanged(partial)
                        },
                        onTextReady: { sessionID, text in
                            onTextReady(sessionID, text)
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
        configuration: SpeechToTextSheetConfiguration = SpeechToTextSheetConfiguration(),
        onLiveTranscriptChanged: @escaping (LiveTranscriptPartial) -> Void = { _ in },
        onTextReady: @escaping (UUID, String) -> Void,
        onSetupReady: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            SpeechToTextSheetModifier(
                isPresented: isPresented,
                configuration: configuration,
                onLiveTranscriptChanged: onLiveTranscriptChanged,
                onTextReady: onTextReady,
                onSetupReady: onSetupReady
            )
        )
    }

    func speechToTextSheet(
        isPresented: Binding<Bool>,
        preferredLanguage: SpeechToTextManager.SupportedLanguage? = nil,
        onLiveTranscriptChanged: @escaping (LiveTranscriptPartial) -> Void = { _ in },
        onTextReady: @escaping (UUID, String) -> Void,
        onSetupReady: @escaping () -> Void = {}
    ) -> some View {
        var configuration = SpeechToTextSheetConfiguration()
        configuration.preferredLanguage = preferredLanguage
        return speechToTextSheet(
            isPresented: isPresented,
            configuration: configuration,
            onLiveTranscriptChanged: onLiveTranscriptChanged,
            onTextReady: onTextReady,
            onSetupReady: onSetupReady
        )
    }
}
