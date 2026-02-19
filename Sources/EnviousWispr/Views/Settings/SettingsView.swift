import SwiftUI

/// Command Center settings with sidebar navigation.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedSection: SettingsSection = .speechEngine

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSection) {
                ForEach(SettingsGroup.allCases, id: \.self) { group in
                    Section(group.rawValue) {
                        ForEach(group.sections) { section in
                            Label(section.label, systemImage: section.icon)
                                .tag(section)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 200)
        } detail: {
            settingsDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 680, height: 520)
    }

    @ViewBuilder
    private var settingsDetail: some View {
        switch selectedSection {
        case .speechEngine:
            SpeechEngineSettingsView()
        case .voiceDetection:
            VoiceDetectionSettingsView()
        case .shortcuts:
            ShortcutsSettingsView()
        case .aiPolish:
            AIPolishSettingsView()
        case .wordCorrection:
            WordFixSettingsView()
        case .clipboard:
            ClipboardSettingsView()
        case .memory:
            MemorySettingsView()
        case .permissions:
            PermissionsSettingsView()
        case .diagnostics:
            DiagnosticsSettingsView()
        }
    }
}
