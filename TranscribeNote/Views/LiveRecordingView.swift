import SwiftUI
import os

struct LiveRecordingView: View {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TranscribeNote", category: "LiveRecordingView")

    @Bindable var viewModel: RecordingViewModel
    let onStop: () -> Void
    var onPause: (() -> Void)?
    var onResume: (() -> Void)?

    @State private var scrollToTime: TimeInterval?
    @State private var chatViewModel: ChatViewModel?
    @State private var isChatOpen = false
    @AppStorage("liveChatPanelWidth") private var chatPanelWidth: Double = 320

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                RecordingControlView(
                    state: viewModel.state,
                    elapsedTime: viewModel.clock.formatted,
                    audioLevel: viewModel.audioMeter.level,
                    stoppingStatus: viewModel.stoppingStatus,
                    onStart: {
                        Task {
                            await viewModel.startRecording()
                        }
                    },
                    onStop: onStop,
                    onPause: onPause,
                    onResume: onResume
                )

                Divider()

                if let error = viewModel.errorMessage {
                    Text(error)
                        .foregroundStyle(DS.Colors.recording)
                        .font(DS.Typography.caption)
                        .padding(.horizontal)
                        .padding(.vertical, DS.Spacing.xs)
                }

                // Summary error — shown independently of summary section
                if let error = viewModel.summaryError {
                    HStack(alignment: .top, spacing: DS.Spacing.xs) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(DS.Colors.error)
                        Text(error)
                            .foregroundStyle(DS.Colors.error)
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            viewModel.clearSummaryError()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(String(localized: "Dismiss error"))
                    }
                    .font(DS.Typography.caption)
                    .padding(DS.Spacing.sm)
                    .padding(.horizontal)
                    .background(DS.Colors.error.opacity(0.08), in: RoundedRectangle(cornerRadius: DS.Radius.sm))
                    .transition(.opacity)
                }

                if viewModel.segments.isEmpty && viewModel.partialText.isEmpty {
                    if !viewModel.isActive {
                        ContentUnavailableView(
                            "No Transcript",
                            systemImage: "mic.badge.plus",
                            description: Text("Press \(Image(systemName: "record.circle")) or ⌘R to start recording")
                        )
                    } else {
                        TranscriptView(
                            segments: viewModel.segments,
                            partialText: viewModel.partialText,
                            summaries: viewModel.summaries
                        )
                    }
                } else {
                    TranscriptView(
                        segments: viewModel.segments,
                        partialText: viewModel.partialText,
                        summaries: viewModel.summaries,
                        scrollToTime: $scrollToTime
                    )
                }
            }
            .frame(maxWidth: .infinity)

            if isChatOpen, let vm = chatViewModel {
                VerticalResizeHandle(width: $chatPanelWidth, minWidth: 250, maxWidth: 500)
                ChatViewContent(viewModel: vm)
                    .frame(width: chatPanelWidth)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    toggleChat()
                } label: {
                    Label("Chat", systemImage: isChatOpen ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                }
                .disabled(viewModel.segments.isEmpty)
                .help(String(localized: "Ask questions about the live transcript"))
            }
        }
        .onChange(of: viewModel.segments.count) {
            chatViewModel?.configure(sessionID: liveChatSessionID, segments: viewModel.segments)
        }
        // 2c: Duration-end prompt
        .alert("Scheduled event ended", isPresented: $viewModel.showDurationEndPrompt) {
            Button("Stop Recording", role: .destructive) {
                onStop()
            }
            Button("Continue Recording", role: .cancel) { }
        } message: {
            Text("\"\(viewModel.scheduledInfo?.title ?? "Event")\" has reached its scheduled duration.")
        }
    }

    /// Stable session ID for live chat — uses current session if available, otherwise a fixed UUID.
    private var liveChatSessionID: UUID {
        viewModel.currentSession?.id ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }

    private func toggleChat() {
        if isChatOpen {
            isChatOpen = false
        } else {
            if chatViewModel == nil {
                chatViewModel = ChatViewModel()
            }
            chatViewModel?.configure(sessionID: liveChatSessionID, segments: viewModel.segments)
            isChatOpen = true
            Self.logger.info("Live chat opened")
        }
    }
}
