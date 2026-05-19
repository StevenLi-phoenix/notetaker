import SwiftUI

struct GeneralSettingsTab: View {
    @AppStorage("appLanguageOverride") private var appLanguageOverride: String = ""
    @AppStorage("menuBarOnly") private var menuBarOnly = false
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("appearanceOverride") private var appearanceOverride: String = "system"
    @AppStorage("textZoomLevel") private var textZoomLevel: Int = 2
    @State private var showRestartPrompt = false

    private static let zoomLabels = ["S", "M", "L", "XL", "XXL"]

    private enum AppMode: String, CaseIterable {
        case windowOnly = "windowOnly"
        case both = "both"
        case menuBarOnly = "menuBarOnly"

        var label: String {
            switch self {
            case .windowOnly: String(localized: "Window Only")
            case .both: String(localized: "Both")
            case .menuBarOnly: String(localized: "Menu Bar Only")
            }
        }

        var icon: String {
            switch self {
            case .windowOnly: "macwindow"
            case .both: "macwindow.and.cursorarrow"
            case .menuBarOnly: "menubar.rectangle"
            }
        }
    }

    private var appMode: Binding<AppMode> {
        Binding(
            get: {
                if menuBarOnly { return .menuBarOnly }
                if !showMenuBarIcon { return .windowOnly }
                return .both
            },
            set: { newValue in
                switch newValue {
                case .windowOnly:
                    menuBarOnly = false
                    showMenuBarIcon = false
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                case .both:
                    menuBarOnly = false
                    showMenuBarIcon = true
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                case .menuBarOnly:
                    showMenuBarIcon = true
                    menuBarOnly = true
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        )
    }

    private static let languages: [(label: String, value: String)] = [
        ("System Default", ""),
        ("English", "en"),
        ("简体中文", "zh-Hans"),
        ("繁體中文", "zh-Hant"),
        ("日本語", "ja"),
        ("한국어", "ko"),
        ("Español", "es"),
        ("Français", "fr"),
        ("Deutsch", "de"),
        ("Português", "pt"),
        ("Русский", "ru"),
        ("Italiano", "it"),
        ("العربية", "ar"),
        ("हिन्दी", "hi"),
        ("Türkçe", "tr"),
        ("Tiếng Việt", "vi"),
        ("ไทย", "th"),
        ("Bahasa Indonesia", "id"),
        ("Polski", "pl"),
        ("Nederlands", "nl"),
        ("Svenska", "sv"),
    ]

    /// Resolve a localized string in the target language (not the current app language).
    private func localizedInTarget(_ key: String.LocalizationValue) -> String {
        let code = appLanguageOverride.isEmpty ? Locale.current.language.languageCode?.identifier ?? "en" : appLanguageOverride
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return String(localized: key, bundle: bundle)
        }
        return String(localized: key)
    }

    var body: some View {
        SettingsGrid {
            SettingsRow("App Mode") {
                Picker("", selection: appMode) {
                    ForEach(AppMode.allCases, id: \.self) { mode in
                        Label(mode.label, systemImage: mode.icon)
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SettingsRow("Appearance") {
                Picker("", selection: $appearanceOverride) {
                    Label("System", systemImage: "circle.lefthalf.filled").tag("system")
                    Label("Light", systemImage: "sun.max").tag("light")
                    Label("Dark", systemImage: "moon").tag("dark")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SettingsRow("Text Size") {
                Picker("", selection: $textZoomLevel) {
                    ForEach(0..<Self.zoomLabels.count, id: \.self) { i in
                        Text(Self.zoomLabels[i]).tag(i)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            SettingsRow("Language") {
                Picker("", selection: $appLanguageOverride) {
                    ForEach(Self.languages, id: \.value) { lang in
                        Text(lang.label).tag(lang.value)
                    }
                }
                .labelsHidden()
                .onChange(of: appLanguageOverride) { _, _ in
                    showRestartPrompt = true
                }
            }

            if showRestartPrompt {
                SettingsRow("") {
                    HStack(spacing: DS.Spacing.sm) {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.orange)
                        Text(localizedInTarget("Restart required to apply language change"))
                            .font(DS.Typography.caption)
                            .foregroundStyle(.secondary)
                        Button(localizedInTarget("Restart Now")) {
                            TranscribeNoteApp.relaunch()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }
}
