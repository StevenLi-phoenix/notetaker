import SwiftUI
import SwiftData
import os

// MARK: - Playback Notification Names

extension Notification.Name {
    static let togglePlayback = Notification.Name("transcribenote.togglePlayback")
    static let seekForward = Notification.Name("transcribenote.seekForward")
    static let seekBackward = Notification.Name("transcribenote.seekBackward")
    static let seekForwardLong = Notification.Name("transcribenote.seekForwardLong")
    static let seekBackwardLong = Notification.Name("transcribenote.seekBackwardLong")
    static let toggleCommandPalette = Notification.Name("transcribenote.toggleCommandPalette")
    static let showWelcomeGuide = Notification.Name("transcribenote.showWelcomeGuide")
    static let showPrivacyDisclosure = Notification.Name("transcribenote.showPrivacyDisclosure")
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: RecordingViewModel?
    var schedulerViewModel: SchedulerViewModel?
    var modelContainer: ModelContainer?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        applyMenuBarOnlyPolicy()
        applyAppearancePreference()
        if UserDefaults.standard.bool(forKey: "menuBarOnly") {
            // Close the auto-opened main window so only the menu bar icon remains
            DispatchQueue.main.async {
                for window in NSApp.windows where window.canBecomeMain {
                    window.close()
                }
            }
        }
    }

    /// Apply the appearance preference (light/dark/system).
    func applyAppearancePreference() {
        let raw = UserDefaults.standard.string(forKey: "appearanceOverride") ?? "system"
        switch raw {
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default:      NSApp.appearance = nil
        }
    }

    /// Apply the activation policy based on the menuBarOnly preference.
    func applyMenuBarOnlyPolicy() {
        let menuBarOnly = UserDefaults.standard.bool(forKey: "menuBarOnly")
        NSApp.setActivationPolicy(menuBarOnly ? .accessory : .regular)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let hasRecording = viewModel?.isActive == true

        if hasRecording {
            // Force-persist immediately without waiting for ASR drain or in-flight summaries
            viewModel?.forceQuitPersist(modelContext: modelContainer?.mainContext)
        }

        // Cancel all background summaries — don't wait for LLM responses
        BackgroundSummaryService.shared.cancelAll()

        return .terminateNow
    }
}

@main
struct TranscribeNoteApp: App {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "TranscribeNote", category: "App")

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var viewModel: RecordingViewModel
    @State private var schedulerViewModel: SchedulerViewModel
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("textZoomLevel") private var textZoomLevel: Int = 2
    @AppStorage("appearanceOverride") private var appearanceOverride: String = "system"

    // macOS default sizeCategory is .large (index 2)
    private static let zoomCategories: [ContentSizeCategory] = [
        .small, .medium, .large, .extraLarge, .extraExtraLarge,
    ]

    private var currentSizeCategory: ContentSizeCategory {
        let clamped = min(max(textZoomLevel, 0), Self.zoomCategories.count - 1)
        return Self.zoomCategories[clamped]
    }

    private let sharedModelContainer: ModelContainer?
    private let containerError: String?

    /// The real system locale captured before any AppleLanguages override.
    /// Used by ASR so speech recognition isn't affected by the UI language choice.
    nonisolated(unsafe) static var systemLocale = Locale.current

    init() {
        // Capture the real system locale BEFORE overriding AppleLanguages,
        // so ASR keeps using the system speech language, not the UI language.
        TranscribeNoteApp.systemLocale = Locale.current

        // Language override — apply before any UI loads.
        // NOTE: This changes Locale.current for the process. ASR uses systemLocale instead.
        if let override = UserDefaults.standard.string(forKey: "appLanguageOverride"), !override.isEmpty {
            UserDefaults.standard.set([override], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }

        UserDefaults.standard.register(defaults: ["soundEffectsEnabled": true])

        CrashLogService.install()
        KeychainMigration.migrateIfNeeded()
        SchedulerService.install()

        let llmConfig = LLMProfileStore.resolveConfig(for: .live)
        let summarizerConfig = SummarizerConfig.fromUserDefaults()
        let vadConfig = VADConfig.fromUserDefaults()
        let vm = RecordingViewModel(llmConfig: llmConfig, summarizerConfig: summarizerConfig, vadConfig: vadConfig)
        _viewModel = State(initialValue: vm)
        let schedulerVM = SchedulerViewModel()
        schedulerVM.recordingViewModel = vm
        _schedulerViewModel = State(initialValue: schedulerVM)

        let configuration = ModelConfiguration()
        do {
            sharedModelContainer = try ModelContainer(
                for: RecordingSession.self, TranscriptSegment.self, SummaryBlock.self,
                ScheduledRecording.self, ActionItem.self,
                migrationPlan: TranscribeNoteMigrationPlan.self,
                configurations: configuration
            )
            containerError = nil
        } catch {
            Self.logger.error("Failed to create ModelContainer: \(error.localizedDescription)")
            sharedModelContainer = nil
            containerError = error.localizedDescription
        }

        // Wire AppDelegate refs eagerly so applicationShouldTerminate works
        // even if the main window never appeared (e.g. MenuBarExtra-only usage).
        appDelegate.viewModel = vm
        appDelegate.schedulerViewModel = schedulerVM
        appDelegate.modelContainer = sharedModelContainer

        // 3c: Auto-start is now handled directly by SchedulerViewModel.handleFire()
        // via direct callback to RecordingViewModel (no notification relay needed).
    }

    static func relaunch() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        NSApp.terminate(nil)
    }

    @ViewBuilder
    private var menuBarIcon: some View {
        if viewModel.state == .paused {
            Image(systemName: "pause.circle.fill")
                .symbolRenderingMode(.multicolor)
        } else if viewModel.isRecording {
            Image(systemName: "record.circle.fill")
                .symbolRenderingMode(.multicolor)
        } else if schedulerViewModel.nextScheduled != nil {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "mic")
                Image(systemName: "clock.fill")
                    .font(.system(size: 7, weight: .bold))
                    .offset(x: 3, y: 3)
            }
        } else {
            Image(systemName: "mic")
        }
    }

    var body: some Scene {

        WindowGroup(id: "main") {
            if let sharedModelContainer {
                ContentView(viewModel: viewModel, schedulerViewModel: schedulerViewModel)
                    .modelContainer(sharedModelContainer)
                    .environment(\.sizeCategory, currentSizeCategory)
                    .onChange(of: appearanceOverride) { _, newValue in
                        switch newValue {
                        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
                        case "light": NSApp.appearance = NSAppearance(named: .aqua)
                        default:      NSApp.appearance = nil
                        }
                    }
                    .onAppear {
                        schedulerViewModel.load(context: sharedModelContainer.mainContext)
                    }
                    .task {
                        await LLMProvider.refreshStorefrontStatus()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
                        guard UserDefaults.standard.bool(forKey: "menuBarOnly") else { return }
                        // Delay so the window finishes closing before checking
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            let hasContentWindows = NSApp.windows.contains {
                                $0.isVisible && $0.canBecomeMain
                            }
                            if !hasContentWindows {
                                NSApp.setActivationPolicy(.accessory)
                            }
                        }
                    }
            } else {
                VStack(spacing: DS.Spacing.md) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text("Failed to initialize database")
                        .font(DS.Typography.sectionHeader)
                    Text(containerError ?? "The app's data store could not be created. Try relaunching the app.")
                        .font(DS.Typography.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            if let sharedModelContainer {
                MenuBarView(viewModel: viewModel, schedulerViewModel: schedulerViewModel, modelContainer: sharedModelContainer)
            } else {
                Text("Database unavailable")
            }
        } label: {
            menuBarIcon
        }

        Window("Models", id: "models") {
            ModelsSettingsTab()
                .frame(width: 600, height: 600)
                .environment(\.sizeCategory, currentSizeCategory)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
                .environment(\.sizeCategory, currentSizeCategory)
        }
        .commands {
            #if DEBUG
            CommandMenu("Debug") {
                Button("Import Sample Sessions") {
                    guard let container = sharedModelContainer else { return }
                    Task { @MainActor in
                        Self.importSampleSessions(container: container)
                    }
                }
            }
            #endif
        }
        .commands {
            CommandGroup(replacing: .help) {
                Button("Privacy Policy") {
                    NSWorkspace.shared.open(PrivacyDisclosureView.privacyPolicyURL)
                }

                Button("Data Usage Information") {
                    NotificationCenter.default.post(name: .showPrivacyDisclosure, object: nil)
                }

                Button("Welcome Guide") {
                    NotificationCenter.default.post(name: .showWelcomeGuide, object: nil)
                }
            }

            CommandMenu("Playback") {
                Button("Play/Pause") {
                    NotificationCenter.default.post(name: .togglePlayback, object: nil)
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Skip Forward 5s") {
                    NotificationCenter.default.post(name: .seekForward, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])

                Button("Skip Back 5s") {
                    NotificationCenter.default.post(name: .seekBackward, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])

                Button("Skip Forward 15s") {
                    NotificationCenter.default.post(name: .seekForwardLong, object: nil)
                }
                .keyboardShortcut(.rightArrow, modifiers: .shift)

                Button("Skip Back 15s") {
                    NotificationCenter.default.post(name: .seekBackwardLong, object: nil)
                }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            }

            CommandGroup(after: .toolbar) {
                Button("Command Palette") {
                    NotificationCenter.default.post(name: .toggleCommandPalette, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }

            CommandMenu("View") {
                Button("Increase Text Size") {
                    textZoomLevel = min(textZoomLevel + 1, Self.zoomCategories.count - 1)
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("Decrease Text Size") {
                    textZoomLevel = max(textZoomLevel - 1, 0)
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("Reset Text Size") {
                    textZoomLevel = 2
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    #if DEBUG
    @MainActor
    private static func importSampleSessions(container: ModelContainer) {
        let context = container.mainContext
        let sampleTexts = [
            ("Team standup meeting", [
                (0.0, "Good morning everyone, let's go through our updates."),
                (5.0, "I finished the authentication module yesterday."),
                (12.0, "Today I'm working on the dashboard API endpoints."),
                (20.0, "The deployment pipeline needs some fixes too."),
                (28.0, "Let's sync up after lunch about the database migration."),
            ]),
            ("Product review session", [
                (0.0, "Welcome to the product review for Q1."),
                (8.0, "Our user engagement increased by fifteen percent."),
                (15.0, "The new onboarding flow is performing well."),
                (22.0, "We need to address the loading time issues."),
                (30.0, "Next quarter we'll focus on mobile optimization."),
            ]),
            ("Architecture discussion", [
                (0.0, "Let's discuss the microservices migration plan."),
                (7.0, "The current monolith is hitting scalability limits."),
                (14.0, "We should start with the user service extraction."),
                (21.0, "Event sourcing could help with data consistency."),
                (28.0, "We need a proper API gateway before splitting services."),
            ]),
        ]

        // Copy sample audio if available
        let sampleAudioURL = URL(fileURLWithPath: "/tmp/test-audio.mp3")
        let hasAudio = FileManager.default.fileExists(atPath: sampleAudioURL.path)

        for (title, segments) in sampleTexts {
            let session = RecordingSession()
            session.title = title
            session.startedAt = Date().addingTimeInterval(-Double.random(in: 3600...86400))
            session.endedAt = session.startedAt.addingTimeInterval(35.0)

            if hasAudio {
                do {
                    let recordingsDir = try AudioCaptureService.recordingsDirectory()
                    try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
                    let destURL = recordingsDir.appendingPathComponent("\(UUID().uuidString).mp3")
                    try FileManager.default.copyItem(at: sampleAudioURL, to: destURL)
                    session.audioFilePath = destURL.lastPathComponent
                    logger.info("Copied sample audio to \(destURL.lastPathComponent)")
                } catch {
                    logger.warning("Could not copy sample audio: \(error.localizedDescription)")
                }
            }

            context.insert(session)

            for (time, text) in segments {
                let segment = TranscriptSegment(startTime: time, endTime: time + 5.0, text: text)
                segment.session = session
                context.insert(segment)
            }

            let summary = SummaryBlock(
                coveringFrom: 0, coveringTo: 35,
                content: "This session covered key discussion points about \(title.lowercased()). Participants discussed progress, challenges, and next steps."
            )
            summary.session = session
            context.insert(summary)
        }

        do {
            try context.save()
            logger.info("Imported 3 sample sessions")
        } catch {
            logger.error("Failed to save sample sessions: \(error.localizedDescription)")
        }
    }
    #endif
}

struct MenuBarView: View {
    @Bindable var viewModel: RecordingViewModel
    var schedulerViewModel: SchedulerViewModel
    @Environment(\.openWindow) private var openWindow
    let modelContainer: ModelContainer
    @State private var pulsing = false

    var body: some View {
        if viewModel.isRecording {
            HStack(spacing: DS.Spacing.xs) {
                Circle()
                    .fill(DS.Colors.recording)
                    .frame(width: 7, height: 7)
                    .opacity(pulsing ? 0.35 : 1.0)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                    .onAppear { pulsing = true }
                    .onDisappear { pulsing = false }
                Text("Recording")
                    .fontWeight(.medium)
                Spacer()
                Text(viewModel.clock.formatted)
                    .font(DS.Typography.timer)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.top, DS.Spacing.xs)
            .frame(minWidth: 280)

            AudioLevelBar(level: viewModel.audioMeter.level)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.bottom, DS.Spacing.xs)
                .frame(minWidth: 280)

            if !viewModel.latestKeyPoints.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: DS.Spacing.xxs) {
                    ForEach(viewModel.latestKeyPoints, id: \.self) { point in
                        HStack(alignment: .top, spacing: DS.Spacing.xs) {
                            Text("•")
                            Text(point)
                                .lineLimit(2)
                        }
                    }
                }
                .font(DS.Typography.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .frame(minWidth: 280, alignment: .leading)
            } else if let summary = viewModel.latestSummary {
                Divider()
                Text(summary)
                    .font(DS.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, DS.Spacing.md)
                    .padding(.vertical, DS.Spacing.xs)
                    .frame(minWidth: 280, alignment: .leading)
            }

            Divider()

            Button {
                Task { await viewModel.pauseRecording() }
            } label: {
                Label("Pause Recording", systemImage: "pause.fill")
            }

            Button(role: .destructive) {
                viewModel.stopRecording(modelContext: modelContainer.mainContext)
            } label: {
                Label("Stop Recording", systemImage: "stop.fill")
            }
        } else if viewModel.state == .paused {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: "pause.circle.fill")
                    .foregroundStyle(DS.Colors.paused)
                Text("Paused")
                    .fontWeight(.medium)
                Spacer()
                Text(viewModel.clock.formatted)
                    .font(DS.Typography.timer)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.xs)
            .frame(minWidth: 280)

            Divider()

            Button {
                Task { await viewModel.resumeRecording() }
            } label: {
                Label("Resume Recording", systemImage: "play.fill")
            }

            Button(role: .destructive) {
                viewModel.stopRecording(modelContext: modelContainer.mainContext)
            } label: {
                Label("Stop Recording", systemImage: "stop.fill")
            }
        } else {
            Label("Not Recording", systemImage: "mic.slash")
                .foregroundStyle(.secondary)
            if let next = schedulerViewModel.nextScheduled, let fireTime = next.nextFireTime {
                HStack {
                    Image(systemName: "clock")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.title.isEmpty ? "Scheduled" : next.title)
                            .font(DS.Typography.caption)
                            .fontWeight(.medium)
                        Text(fireTime, style: .relative)
                            .font(DS.Typography.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, DS.Spacing.xs)
                .frame(minWidth: 200, alignment: .leading)
            }
            Divider()
            Button {
                Task {
                    await viewModel.startRecording(modelContext: modelContainer.mainContext)
                }
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
        }

        Divider()

        Button("Open Main Window") {
            NSApp.setActivationPolicy(.regular)
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

        SettingsLink()

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
