import SwiftUI
import AppKit

public struct SettingsView: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        HSplitView {
            // Left Navigation Sidebar
            sidebarView
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 240)

            // Right Detail Content
            contentPane
                .frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 780, idealWidth: 840, maxWidth: 1000, minHeight: 560, idealHeight: 620, maxHeight: 800)
        .background(Theme.bgDark)
        .preferredColorScheme(.dark)
    }

    // MARK: - Sidebar
    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 18))
                    .foregroundColor(Theme.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Settings")
                        .font(Theme.bodyBold)
                        .foregroundColor(Theme.fg)
                    Text("MusicStudio Preferences")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.comment)
                }
                Spacer()
            }
            .padding(14)
            .background(Theme.bgFloat)

            Divider().background(Theme.border)

            // Navigation List
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 4) {
                    ForEach(StudioViewModel.SettingsTab.allCases) { tab in
                        Button(action: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                vm.settingsTab = tab
                            }
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 13))
                                    .foregroundColor(vm.settingsTab == tab ? Theme.blue : tabColor(for: tab))
                                    .frame(width: 20)

                                Text(tab.title)
                                    .font(vm.settingsTab == tab ? Theme.bodyBold : Theme.body)
                                    .foregroundColor(vm.settingsTab == tab ? Theme.fg : Theme.fgDark)

                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(vm.settingsTab == tab ? Theme.bgHighlight : Color.clear)
                            .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
            }

            Spacer()

            // Footer
            VStack(spacing: 8) {
                Divider().background(Theme.border)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MusicStudio 2.0")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(Theme.fgDark)
                        Text("Apple Silicon MLX")
                            .font(.system(size: 9))
                            .foregroundColor(Theme.comment)
                    }

                    Spacer()

                    Circle()
                        .fill(Theme.green)
                        .frame(width: 6, height: 6)
                    Text("Ready")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.green)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .background(Theme.bgFloat)
        }
        .background(Theme.bgFloat.opacity(0.85))
    }

    private func tabColor(for tab: StudioViewModel.SettingsTab) -> Color {
        switch tab {
        case .api: return Theme.purple
        case .models: return Theme.blue
        case .defaults: return Theme.cyan
        case .layout: return Theme.yellow
        case .storage: return Theme.green
        }
    }

    // MARK: - Content Pane
    private var contentPane: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 10) {
                Image(systemName: vm.settingsTab.icon)
                    .font(.system(size: 16))
                    .foregroundColor(tabColor(for: vm.settingsTab))

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.settingsTab.title)
                        .font(Theme.bodyBold)
                        .foregroundColor(Theme.fg)
                    Text(tabDescription(for: vm.settingsTab))
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                }

                Spacer()

                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
                .controlSize(.small)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Theme.bgFloat)

            Divider().background(Theme.border)

            // Tab Content Body
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 18) {
                    switch vm.settingsTab {
                    case .api:
                        APISettingsSection(vm: vm)
                    case .models:
                        ModelsSettingsSection(vm: vm)
                    case .defaults:
                        DefaultsSettingsSection(vm: vm)
                    case .layout:
                        LayoutSettingsSection(vm: vm)
                    case .storage:
                        StorageSettingsSection(vm: vm)
                    }
                }
                .padding(20)
            }
        }
        .background(Theme.bg)
    }

    private func tabDescription(for tab: StudioViewModel.SettingsTab) -> String {
        switch tab {
        case .api:
            return "Configure Songwriter API endpoint, enable/disable integration, and authenticate"
        case .models:
            return "Manage installed weights, search HuggingFace Hub, and select default models"
        case .defaults:
            return "Set default duration, steps, guidance scale, audio format, and planning mode"
        case .layout:
            return "Modify workspace appearance, panel heights, console visibility, and header elements"
        case .storage:
            return "Storage locations, database management, and Apple Silicon hardware profile"
        }
    }
}

// MARK: - 1. API & Endpoint Settings
struct APISettingsSection: View {
    @ObservedObject var vm: StudioViewModel
    @State private var baseURL: String = SongwriterAPI.configuredBaseURL
    @State private var token: String = SongwriterAPI.configuredToken
    @State private var showToken: Bool = false
    @State private var isTesting: Bool = false
    @State private var testResultMessage: String? = nil
    @State private var testSucceeded: Bool = false
    @State private var saveSuccessBanner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Master Enable/Disable Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Songwriter Integration")
                                .font(Theme.bodyBold)
                                .foregroundColor(Theme.fg)

                            // Status Chip
                            if !vm.isSongwriterEnabled {
                                Text("DISABLED")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.comment)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.border)
                                    .cornerRadius(4)
                            } else if isTesting {
                                Text("TESTING…")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.yellow)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.yellow.opacity(0.15))
                                    .cornerRadius(4)
                            } else if testSucceeded {
                                Text("CONNECTED")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.green)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.green.opacity(0.15))
                                    .cornerRadius(4)
                            } else if testResultMessage != nil {
                                Text("ERROR")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.red)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.red.opacity(0.15))
                                    .cornerRadius(4)
                            } else {
                                Text("CONFIGURED")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(Theme.purple)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.purple.opacity(0.15))
                                    .cornerRadius(4)
                            }
                        }

                        Text("Connect MusicStudio to a local or remote Songwriter service to import lyrics, style tags, and song structures.")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                    }

                    Spacer()

                    Toggle("", isOn: $vm.isSongwriterEnabled)
                        .toggleStyle(.switch)
                        .onChange(of: vm.isSongwriterEnabled) { _, enabled in
                            if enabled {
                                vm.loadSongwriterSongs()
                            }
                        }
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Endpoint & Authentication Card
            VStack(alignment: .leading, spacing: 14) {
                Text("ENDPOINT CONFIGURATION")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)

                // API URL
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Server URL")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text(baseURL.starts(with: "https://") ? "HTTPS Secure" : (baseURL.starts(with: "http://") ? "HTTP" : "Invalid Scheme"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(baseURL.starts(with: "https://") ? Theme.green : (baseURL.starts(with: "http://") ? Theme.cyan : Theme.red))
                    }

                    TextField("http://127.0.0.1:8000", text: $baseURL)
                        .textFieldStyle(.plain)
                        .font(Theme.monoBody)
                        .foregroundColor(Theme.fg)
                        .padding(9)
                        .background(Theme.bgDark)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                        .disabled(!vm.isSongwriterEnabled)

                    Text("Standard port is 8000. Examples: http://127.0.0.1:8000 or https://songwriter.example.com")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.comment)
                }

                // Bearer Token
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Bearer Token")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Button(action: { showToken.toggle() }) {
                            HStack(spacing: 3) {
                                Image(systemName: showToken ? "eye.slash" : "eye")
                                Text(showToken ? "Hide" : "Show")
                            }
                            .font(.system(size: 10))
                            .foregroundColor(Theme.blue)
                        }
                        .buttonStyle(.plain)
                    }

                    Group {
                        if showToken {
                            TextField("API Token", text: $token)
                        } else {
                            SecureField("API Token", text: $token)
                        }
                    }
                    .textFieldStyle(.plain)
                    .font(Theme.monoBody)
                    .foregroundColor(Theme.fg)
                    .padding(9)
                    .background(Theme.bgDark)
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))
                    .disabled(!vm.isSongwriterEnabled)

                    Text("Stored locally in application preferences.")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.comment)
                }

                // Test Connection Feedback
                if let result = testResultMessage {
                    HStack(spacing: 8) {
                        Image(systemName: testSucceeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(testSucceeded ? Theme.green : Theme.red)
                        Text(result)
                            .font(Theme.small)
                            .foregroundColor(testSucceeded ? Theme.green : Theme.red)
                        Spacer()
                    }
                    .padding(10)
                    .background((testSucceeded ? Theme.green : Theme.red).opacity(0.1))
                    .cornerRadius(6)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke((testSucceeded ? Theme.green : Theme.red).opacity(0.3), lineWidth: 1))
                }

                if saveSuccessBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(Theme.green)
                        Text("Songwriter configuration saved successfully.")
                            .font(Theme.small)
                            .foregroundColor(Theme.green)
                        Spacer()
                    }
                    .padding(8)
                    .background(Theme.green.opacity(0.1))
                    .cornerRadius(6)
                }

                Divider().background(Theme.border)

                // Action Buttons
                HStack(spacing: 10) {
                    Button("Reset to Localhost") {
                        baseURL = SongwriterAPI.defaultBaseURL
                        token = SongwriterAPI.defaultLocalToken
                        testResultMessage = nil
                    }
                    .buttonStyle(.plain)
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)

                    Spacer()

                    Button(action: testConnection) {
                        HStack(spacing: 5) {
                            if isTesting {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "bolt.horizontal.circle")
                            }
                            Text(isTesting ? "Testing…" : "Test Connection")
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.purple)
                    .disabled(isTesting || !vm.isSongwriterEnabled)

                    Button("Save Configuration") {
                        saveConfiguration()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.purple)
                    .disabled(isTesting || !vm.isSongwriterEnabled)
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
            .opacity(vm.isSongwriterEnabled ? 1.0 : 0.6)

            // Integration Preferences Card
            VStack(alignment: .leading, spacing: 12) {
                Text("INTEGRATION PREFERENCES")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)

                Toggle(isOn: $vm.showSongwriterInHeader) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Songwriter Button in Header Bar")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fg)
                        Text("Quick-access popover button in the main top window bar.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.comment)
                    }
                }
                .toggleStyle(.checkbox)

                if let currentSong = vm.selectedSongwriterTitle {
                    Divider().background(Theme.border)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Linked Song: \(currentSong)")
                                .font(Theme.smallMedium)
                                .foregroundColor(Theme.purple)
                            if let rev = vm.selectedSongwriterRevision {
                                Text("Revision \(rev)")
                                    .font(.system(size: 10))
                                    .foregroundColor(Theme.comment)
                            }
                        }

                        Spacer()

                        Button("Clear Link") {
                            vm.clearSongwriterSelection()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))
        }
        .onAppear {
            baseURL = SongwriterAPI.configuredBaseURL
            token = SongwriterAPI.configuredToken
        }
    }

    private func testConnection() {
        guard !isTesting else { return }
        isTesting = true
        testResultMessage = nil
        testSucceeded = false
        saveSuccessBanner = false

        Task {
            do {
                let count = try await SongwriterAPI.shared.testConnection(baseURL: baseURL, token: token)
                testSucceeded = true
                testResultMessage = "Connected successfully. \(count) ready song\(count == 1 ? "" : "s") available on server."
            } catch {
                testSucceeded = false
                testResultMessage = error.localizedDescription
            }
            isTesting = false
        }
    }

    private func saveConfiguration() {
        do {
            try SongwriterAPI.saveConfiguration(baseURL: baseURL, token: token, isEnabled: vm.isSongwriterEnabled)
            vm.songwriterSongs = []
            vm.songwriterError = nil
            if vm.isSongwriterEnabled {
                vm.loadSongwriterSongs()
            }
            saveSuccessBanner = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                saveSuccessBanner = false
            }
        } catch {
            testSucceeded = false
            testResultMessage = error.localizedDescription
        }
    }
}

// MARK: - 2. Models & Weights Settings
struct ModelsSettingsSection: View {
    @ObservedObject var vm: StudioViewModel
    @ObservedObject var hf = HuggingFaceClient.shared
    @State private var subTab: Int = 0 // 0 = Local Catalog, 1 = Hugging Face Hub
    @State private var hfToken: String = UserDefaults.standard.string(forKey: "hfToken") ?? ""
    @State private var hfTokenSaved: Bool = false
    @State private var searchQuery: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Sub-Tab Switcher
            Picker("", selection: $subTab) {
                Text("Standard Catalog").tag(0)
                Text("Hugging Face Hub").tag(1)
            }
            .pickerStyle(.segmented)

            // System Profile Banner
            HStack(spacing: 12) {
                Image(systemName: "cpu")
                    .foregroundColor(Theme.cyan)
                    .font(.system(size: 18))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(SystemProfile.current.chipName) • \(SystemProfile.current.memoryDisplay) Unified Memory")
                        .font(Theme.bodyBold)
                        .foregroundColor(Theme.fg)
                    Text(SystemProfile.current.tierNotes)
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                }

                Spacer()

                Button(action: {
                    NSWorkspace.shared.open(ModelCatalog.modelsDirectory)
                }) {
                    Label("Reveal Folder", systemImage: "folder")
                        .font(Theme.small)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(Theme.blue)
            }
            .padding(12)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            if subTab == 0 {
                localCatalogView
            } else {
                huggingFaceHubView
            }
        }
    }

    private var localCatalogView: some View {
        VStack(spacing: 14) {
            // Model Menu Visibility Quick Controls Card
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TOP BAR MODEL MENU VISIBILITY")
                            .font(Theme.smallBold)
                            .foregroundColor(Theme.comment)
                        Text("Specify which models appear in the top navigation bar's model picker menu.")
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                    }

                    Spacer()

                    Text("\(vm.displayedModelIds.count) of \(ModelCatalog.bundledModels.count) visible")
                        .font(Theme.mono)
                        .foregroundColor(Theme.cyan)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.bgDark)
                        .cornerRadius(5)
                }

                HStack(spacing: 8) {
                    Button("Show All in Menu") {
                        vm.enableAllModelsDisplay()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Recommended Only") {
                        vm.enableOnlyRecommendedModels()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Text("Active: \(vm.modelNames[vm.selectedModel] ?? vm.selectedModel)")
                        .font(Theme.smallMedium)
                        .foregroundColor(Theme.green)
                        .lineLimit(1)
                }
            }
            .padding(12)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // HuggingFace Token Config Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Hugging Face User Token (Optional)")
                        .font(Theme.smallMedium)
                        .foregroundColor(Theme.fgDark)
                    Spacer()
                    if hfTokenSaved {
                        Text("Saved")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.green)
                    }
                }

                HStack(spacing: 8) {
                    SecureField("hf_...", text: $hfToken)
                        .textFieldStyle(.plain)
                        .font(Theme.monoBody)
                        .padding(7)
                        .background(Theme.bgDark)
                        .cornerRadius(6)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                    Button("Save") {
                        let clean = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
                        if clean.isEmpty {
                            UserDefaults.standard.removeObject(forKey: "hfToken")
                        } else {
                            UserDefaults.standard.set(clean, forKey: "hfToken")
                        }
                        hfTokenSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { hfTokenSaved = false }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if !hfToken.isEmpty {
                        Button("Clear") {
                            hfToken = ""
                            UserDefaults.standard.removeObject(forKey: "hfToken")
                        }
                        .buttonStyle(.plain)
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                    }
                }

                Text("A HuggingFace Access Token provides higher rate limits and access to gated model weights.")
                    .font(.system(size: 10))
                    .foregroundColor(Theme.comment)
            }
            .padding(12)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Models by Family
            ForEach(ModelFamily.allCases) { family in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: family.iconName)
                            .foregroundColor(family == .minimax_music3 ? Theme.blue : Theme.purple)
                        Text(family.displayName.uppercased())
                            .font(Theme.smallBold)
                            .foregroundColor(Theme.fg)
                        Spacer()
                        Text(family.shortDescription)
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                    }

                    let models = ModelCatalog.models(for: family)
                    ForEach(models) { model in
                        modelCard(model: model)
                    }
                }
                .padding(12)
                .background(Theme.bgFloat.opacity(0.6))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border.opacity(0.6), lineWidth: 1))
            }
        }
    }

    private func modelCard(model: ModelDefinition) -> some View {
        let isLocal = model.isAvailableLocally
        let isSelected = vm.selectedModel == model.id
        let isDefault = vm.defaultModelId == model.id
        let isDisplayed = vm.isModelDisplayed(id: model.id)
        let downloadKey = "\(model.repo_id):\(model.subfolder ?? "root")"
        let downloadState = hf.activeDownloads[downloadKey]

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(model.name)
                            .font(Theme.bodyBold)
                            .foregroundColor(Theme.fg)

                        if model.recommended {
                            Text("RECOMMENDED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.yellow)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.yellow.opacity(0.15))
                                .cornerRadius(3)
                        }

                        if isLocal {
                            Text("READY ON DISK")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.green.opacity(0.15))
                                .cornerRadius(3)
                        } else {
                            Text("NOT DOWNLOADED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.comment)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.border)
                                .cornerRadius(3)
                        }

                        if isDefault {
                            Text("LAUNCH DEFAULT")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.cyan)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.cyan.opacity(0.15))
                                .cornerRadius(3)
                        }

                        if isSelected {
                            Text("ACTIVE")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Theme.green)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Theme.green.opacity(0.2))
                                .cornerRadius(3)
                        }
                    }

                    Text(model.repo_id + (model.subfolder != nil ? " (\(model.subfolder!))" : ""))
                        .font(Theme.mono)
                        .foregroundColor(Theme.comment)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f GB", model.size_gb))
                        .font(Theme.monoBody)
                        .foregroundColor(Theme.fg)
                    Text("Min RAM: \(model.recommended_min_ram_gb) GB")
                        .font(Theme.small)
                        .foregroundColor(SystemProfile.current.physicalMemoryGB >= Double(model.recommended_min_ram_gb) ? Theme.cyan : Theme.red)
                }
            }

            // Progress bar if downloading
            if let dl = downloadState, !dl.isComplete {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: dl.progressFraction)
                        .tint(Theme.blue)
                    HStack {
                        Text("Downloading \(dl.currentFile)... (\(dl.filesCompleted)/\(dl.totalFiles) files)")
                            .font(Theme.small)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text(String(format: "%.1f MB/s • %.0f%%", dl.speedBytesPerSec / (1024 * 1024), dl.progressFraction * 100))
                            .font(Theme.mono)
                            .foregroundColor(Theme.cyan)
                    }
                }
                .padding(8)
                .background(Theme.bgDark)
                .cornerRadius(6)
            }

            Divider().background(Theme.border.opacity(0.5))

            // Action & Configuration Row
            HStack(spacing: 10) {
                // Select as Active Model button - ALWAYS CLICKABLE
                Button(action: {
                    vm.selectModel(id: model.id)
                }) {
                    HStack(spacing: 4) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                        }
                        Text(isSelected ? "Active Model" : "Select Active")
                    }
                    .font(Theme.smallMedium)
                    .foregroundColor(isSelected ? Theme.green : Theme.fg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(isSelected ? Theme.green.opacity(0.18) : Theme.bgDark)
                    .cornerRadius(5)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(isSelected ? Theme.green : Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)

                // Set as Launch Default button - ALWAYS CLICKABLE
                Button(action: {
                    vm.defaultModelId = model.id
                }) {
                    HStack(spacing: 4) {
                        if isDefault {
                            Image(systemName: "star.fill")
                        }
                        Text(isDefault ? "Default on Launch" : "Set as Default")
                    }
                    .font(Theme.smallMedium)
                    .foregroundColor(isDefault ? Theme.cyan : Theme.comment)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isDefault ? Theme.cyan.opacity(0.12) : Theme.bgDark)
                    .cornerRadius(5)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(isDefault ? Theme.cyan : Theme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)

                // Show in Menu Toggle
                Toggle(isOn: Binding(
                    get: { vm.isModelDisplayed(id: model.id) },
                    set: { vm.setModelDisplay(id: model.id, displayed: $0) }
                )) {
                    Text("Show in Menu")
                        .font(Theme.small)
                        .foregroundColor(isDisplayed ? Theme.fg : Theme.comment)
                }
                .toggleStyle(.checkbox)

                Spacer()

                // Download or Reveal Folder
                if isLocal {
                    Button(action: {
                        NSWorkspace.shared.open(model.localPathURL)
                    }) {
                        Label("Folder", systemImage: "folder")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button(action: {
                        Task {
                            let dest = model.localPathURL
                            try? await hf.downloadModel(
                                repoId: model.repo_id,
                                subfolder: model.subfolder,
                                destinationDir: dest,
                                onProgress: { _ in }
                            )
                            vm.refreshModels()
                        }
                    }) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Download (\(String(format: "%.1f GB", model.size_gb)))")
                        }
                        .font(Theme.small)
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.blue)
                        .cornerRadius(5)
                    }
                    .buttonStyle(.plain)
                    .disabled(downloadState != nil && !(downloadState?.isComplete ?? true))
                }
            }
        }
        .padding(12)
        .background(Theme.bgDark)
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Theme.green.opacity(0.7) : (isDisplayed ? Theme.border : Theme.border.opacity(0.3)), lineWidth: 1))
    }

    private var huggingFaceHubView: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Theme.comment)
                TextField("Search Hugging Face models (e.g. minimax, yue2, mlx)...", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.body)
                    .foregroundColor(Theme.fg)
                    .onSubmit {
                        Task { try? await hf.searchModels(query: searchQuery) }
                    }

                if hf.isSearching {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Button("Search") {
                        Task { try? await hf.searchModels(query: searchQuery) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.blue)
                }
            }
            .padding(8)
            .background(Theme.bgFloat)
            .cornerRadius(6)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

            List(hf.searchResults) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.id)
                            .font(Theme.bodyBold)
                            .foregroundColor(Theme.fg)
                        Spacer()
                        if let dl = item.downloads {
                            Text("\(dl) downloads")
                                .font(Theme.small)
                                .foregroundColor(Theme.comment)
                        }
                        if let lk = item.likes {
                            Text("❤️ \(lk)")
                                .font(Theme.small)
                                .foregroundColor(Theme.comment)
                        }
                    }

                    if let tags = item.tags, !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(tags.prefix(6), id: \.self) { tag in
                                    Text(tag)
                                        .font(.system(size: 10))
                                        .foregroundColor(Theme.comment)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 2)
                                        .background(Theme.bgDark)
                                        .cornerRadius(3)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .listStyle(.plain)
            .frame(minHeight: 280)
        }
        .onAppear {
            if hf.searchResults.isEmpty {
                Task { try? await hf.searchModels(query: "mlx music") }
            }
        }
    }
}

// MARK: - 3. Generation Defaults Settings
struct DefaultsSettingsSection: View {
    @ObservedObject var vm: StudioViewModel
    @State private var applyBanner: Bool = false
    @State private var resetBanner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Notifications
            if applyBanner {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Defaults applied to active session.")
                }
                .font(Theme.small)
                .foregroundColor(Theme.green)
                .padding(8)
                .background(Theme.green.opacity(0.12))
                .cornerRadius(6)
            }

            if resetBanner {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                    Text("Generation defaults restored to factory settings.")
                }
                .font(Theme.small)
                .foregroundColor(Theme.cyan)
                .padding(8)
                .background(Theme.cyan.opacity(0.12))
                .cornerRadius(6)
            }

            // Card 1: Default Model & Audio Output
            VStack(alignment: .leading, spacing: 14) {
                Text("DEFAULT MODEL & FORMAT")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Startup Default Model")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)

                        Picker("", selection: $vm.defaultModelId) {
                            ForEach(ModelCatalog.bundledModels) { model in
                                Text("\(model.name) (\(model.quantization))").tag(model.id)
                            }
                        }
                        .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default Audio Format")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)

                        Picker("", selection: $vm.defaultOutputFormat) {
                            ForEach(AudioFormat.allCases) { fmt in
                                Text(fmt.displayName).tag(fmt)
                            }
                        }
                        .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle(isOn: $vm.defaultInstrumental) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instrumental Default")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fg)
                        Text("Default new sessions to instrumental music generation without vocal stems.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.comment)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Card 2: Duration & Generation Steps
            VStack(alignment: .leading, spacing: 14) {
                Text("DURATION & INFERENCE STEPS")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)

                // Duration
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Default Duration")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text("\(Int(vm.defaultDuration))s (\(StudioViewModel.humanDuration(vm.defaultDuration)))")
                            .font(Theme.monoBody)
                            .foregroundColor(Theme.cyan)
                    }

                    Slider(value: $vm.defaultDuration, in: 10...360, step: 5)
                        .tint(Theme.cyan)

                    HStack(spacing: 6) {
                        ForEach([30, 60, 90, 120, 180, 240, 300], id: \.self) { sec in
                            Button("\(sec)s") { vm.defaultDuration = Double(sec) }
                                .buttonStyle(.plain)
                                .font(Theme.small)
                                .foregroundColor(Int(vm.defaultDuration) == sec ? Theme.cyan : Theme.comment)
                        }
                    }
                }

                Divider().background(Theme.border)

                // Steps
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("MiniMax Flow Steps")
                                .font(Theme.smallMedium)
                                .foregroundColor(Theme.fgDark)
                            Spacer()
                            Text("\(vm.defaultSteps)")
                                .font(Theme.monoBody)
                                .foregroundColor(Theme.purple)
                        }

                        Slider(value: Binding(
                            get: { Double(vm.defaultSteps) },
                            set: { vm.defaultSteps = Int($0) }
                        ), in: 1...30, step: 1)
                        .tint(Theme.purple)

                        HStack(spacing: 6) {
                            ForEach([10, 20, 25, 30], id: \.self) { st in
                                Button("\(st)") { vm.defaultSteps = st }
                                    .buttonStyle(.plain)
                                    .font(Theme.small)
                                    .foregroundColor(vm.defaultSteps == st ? Theme.purple : Theme.comment)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Guidance Scale (CFG)")
                                .font(Theme.smallMedium)
                                .foregroundColor(Theme.fgDark)
                            Spacer()
                            Text(String(format: "%.1f", vm.defaultGuidance))
                                .font(Theme.monoBody)
                                .foregroundColor(Theme.yellow)
                        }

                        Slider(value: $vm.defaultGuidance, in: 1.0...4.0, step: 0.1)
                            .tint(Theme.yellow)

                        HStack(spacing: 6) {
                            ForEach([1.0, 1.4, 1.7, 2.0, 2.5], id: \.self) { g in
                                Button(String(format: "%.1f", g)) { vm.defaultGuidance = g }
                                    .buttonStyle(.plain)
                                    .font(Theme.small)
                                    .foregroundColor(abs(vm.defaultGuidance - g) < 0.05 ? Theme.yellow : Theme.comment)
                            }
                        }
                    }
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Card 3: Planning & Batch
            VStack(alignment: .leading, spacing: 14) {
                Text("AI PLANNING & BATCH SIZE")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("YuE2 CoT Planning Mode")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)

                        Picker("", selection: $vm.defaultCotMode) {
                            ForEach(CoTMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default Batch Count")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)

                        Picker("", selection: $vm.defaultBatchCount) {
                            Text("1 track").tag(1)
                            Text("2 tracks").tag(2)
                            Text("4 tracks").tag(4)
                        }
                        .pickerStyle(.segmented)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Action Buttons
            HStack {
                Button("Reset Defaults to Factory") {
                    vm.resetGenerationDefaultsToFactory()
                    resetBanner = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { resetBanner = false }
                }
                .buttonStyle(.plain)
                .font(Theme.small)
                .foregroundColor(Theme.comment)

                Spacer()

                Button("Apply Defaults to Current Session") {
                    vm.applyGenerationDefaultsToCurrentSession()
                    applyBanner = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { applyBanner = false }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.cyan)
            }
        }
    }
}

// MARK: - 4. Layout & Interface Settings
struct LayoutSettingsSection: View {
    @ObservedObject var vm: StudioViewModel
    @State private var resetBanner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if resetBanner {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("Workspace layout reset to factory settings.")
                }
                .font(Theme.small)
                .foregroundColor(Theme.green)
                .padding(8)
                .background(Theme.green.opacity(0.12))
                .cornerRadius(6)
            }

            // Card 1: Startup & Header Chrome
            VStack(alignment: .leading, spacing: 14) {
                Text("STARTUP & CHROME")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)

                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default Launch Tab")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)

                        Picker("", selection: $vm.defaultLaunchTab) {
                            Text("Create (Editor & Generator)").tag(StudioViewModel.MainTab.create)
                            Text("Studio (Library & Player)").tag(StudioViewModel.MainTab.studio)
                        }
                        .labelsHidden()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider().background(Theme.border)

                Toggle(isOn: $vm.showEtaHeader) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show Live ETA Widget in Header Bar")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fg)
                        Text("Displays live countdown, current stage, and queue completion estimation in the top chrome.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.comment)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Card 2: Live Console Configuration
            VStack(alignment: .leading, spacing: 14) {
                Text("LIVE CONSOLE")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)

                Toggle(isOn: $vm.showConsoleOnLaunch) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Console Automatically on Launch")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fg)
                        Text("Show the live log streamer at the bottom of the window when starting MusicStudio.")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.comment)
                    }
                }
                .toggleStyle(.checkbox)

                Divider().background(Theme.border)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Console Panel Height")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text("\(Int(vm.consoleHeight)) pt")
                            .font(Theme.monoBody)
                            .foregroundColor(Theme.blue)
                    }

                    Slider(value: $vm.consoleHeight, in: 100...320, step: 10)
                        .tint(Theme.blue)

                    HStack(spacing: 8) {
                        Button("Compact (120pt)") { vm.consoleHeight = 120 }
                            .buttonStyle(.plain)
                            .font(Theme.small)
                            .foregroundColor(Int(vm.consoleHeight) == 120 ? Theme.blue : Theme.comment)

                        Button("Default (180pt)") { vm.consoleHeight = 180 }
                            .buttonStyle(.plain)
                            .font(Theme.small)
                            .foregroundColor(Int(vm.consoleHeight) == 180 ? Theme.blue : Theme.comment)

                        Button("Expanded (240pt)") { vm.consoleHeight = 240 }
                            .buttonStyle(.plain)
                            .font(Theme.small)
                            .foregroundColor(Int(vm.consoleHeight) == 240 ? Theme.blue : Theme.comment)
                    }
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Card 3: Resizable Editor Heights
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("WORKSPACE EDITOR HEIGHTS")
                        .font(Theme.smallBold)
                        .foregroundColor(Theme.comment)
                    Spacer()
                    Text("Changes take effect immediately")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.comment)
                }

                // Prompt Editor Height
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Style / Prompt Editor Height")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text("\(Int(vm.promptEditorHeight)) pt")
                            .font(Theme.mono)
                            .foregroundColor(Theme.fg)
                    }
                    Slider(value: $vm.promptEditorHeight, in: 120...450, step: 10)
                        .tint(Theme.blue)
                }

                // Lyrics Editor Height
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Lyrics Editor Height")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text("\(Int(vm.lyricsEditorHeight)) pt")
                            .font(Theme.mono)
                            .foregroundColor(Theme.fg)
                    }
                    Slider(value: $vm.lyricsEditorHeight, in: 80...360, step: 10)
                        .tint(Theme.purple)
                }

                // ABC Editor Height
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("ABC Score Editor Height (YuE2)")
                            .font(Theme.smallMedium)
                            .foregroundColor(Theme.fgDark)
                        Spacer()
                        Text("\(Int(vm.abcEditorHeight)) pt")
                            .font(Theme.mono)
                            .foregroundColor(Theme.fg)
                    }
                    Slider(value: $vm.abcEditorHeight, in: 40...240, step: 5)
                        .tint(Theme.yellow)
                }

                Divider().background(Theme.border)

                HStack(spacing: 10) {
                    Text("Layout Presets:")
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)

                    Button("Compact") {
                        vm.promptEditorHeight = 180
                        vm.lyricsEditorHeight = 100
                        vm.abcEditorHeight = 45
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Standard") {
                        vm.promptEditorHeight = 240
                        vm.lyricsEditorHeight = 140
                        vm.abcEditorHeight = 60
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Spacious") {
                        vm.promptEditorHeight = 320
                        vm.lyricsEditorHeight = 200
                        vm.abcEditorHeight = 90
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    Button("Reset Heights") {
                        vm.promptEditorHeight = 240
                        vm.lyricsEditorHeight = 140
                        vm.abcEditorHeight = 60
                    }
                    .buttonStyle(.plain)
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Action
            HStack {
                Spacer()
                Button("Reset All Layout Preferences") {
                    vm.resetLayoutDefaultsToFactory()
                    resetBanner = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { resetBanner = false }
                }
                .buttonStyle(.plain)
                .font(Theme.small)
                .foregroundColor(Theme.comment)
            }
        }
    }
}

// MARK: - 5. Storage & System Settings
struct StorageSettingsSection: View {
    @ObservedObject var vm: StudioViewModel
    @State private var outputDir: String = UserDefaults.standard.string(forKey: "outputDirectory") ?? SetupManager.defaultOutputDirectory.path
    @State private var modelsDir: String = UserDefaults.standard.string(forKey: "modelsDirectory") ?? SetupManager.defaultModelsDirectory.path
    @State private var showResetConfirm: Bool = false
    @State private var resetCompleteBanner: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if resetCompleteBanner {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                    Text("All settings and layout preferences reset to factory state.")
                }
                .font(Theme.small)
                .foregroundColor(Theme.green)
                .padding(8)
                .background(Theme.green.opacity(0.12))
                .cornerRadius(6)
            }

            // Card 1: Directories
            VStack(alignment: .leading, spacing: 14) {
                Text("FILE LOCATIONS")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.comment)

                // Output Folder
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio Output Folder")
                        .font(Theme.smallMedium)
                        .foregroundColor(Theme.fgDark)

                    HStack(spacing: 8) {
                        Text(outputDir)
                            .font(Theme.mono)
                            .foregroundColor(Theme.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bgDark)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                        Button("Choose…") {
                            chooseOutputDirectory()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(action: {
                            NSWorkspace.shared.open(URL(fileURLWithPath: outputDir))
                        }) {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reveal output folder in Finder")

                        Button("Default") {
                            outputDir = SetupManager.defaultOutputDirectory.path
                            UserDefaults.standard.set(outputDir, forKey: "outputDirectory")
                        }
                        .buttonStyle(.plain)
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                    }
                }

                Divider().background(Theme.border)

                // Models Folder
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model Weights Folder")
                        .font(Theme.smallMedium)
                        .foregroundColor(Theme.fgDark)

                    HStack(spacing: 8) {
                        Text(modelsDir)
                            .font(Theme.mono)
                            .foregroundColor(Theme.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.bgDark)
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border, lineWidth: 1))

                        Button("Choose…") {
                            chooseModelsDirectory()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(action: {
                            NSWorkspace.shared.open(URL(fileURLWithPath: modelsDir))
                        }) {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reveal models folder in Finder")

                        Button("Default") {
                            modelsDir = SetupManager.defaultModelsDirectory.path
                            UserDefaults.standard.set(modelsDir, forKey: "modelsDirectory")
                        }
                        .buttonStyle(.plain)
                        .font(Theme.small)
                        .foregroundColor(Theme.comment)
                    }
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Card 2: Database & Diagnostics
            let counts = DB.shared?.tableCounts() ?? DB.DatabaseTableCounts(generations: 0, templates: 0, lyrics: 0)
            let dbSize = (try? FileManager.default.attributesOfItem(atPath: vm.dbPath)[.size] as? UInt64) ?? 0

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("STUDIO DATABASE & ENGINE")
                        .font(Theme.smallBold)
                        .foregroundColor(Theme.comment)
                    Spacer()
                    Button("Reveal Database in Finder") {
                        NSWorkspace.shared.selectFile(vm.dbPath, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.plain)
                    .font(Theme.small)
                    .foregroundColor(Theme.blue)
                }

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generations")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                        Text("\(counts.generations)")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.fg)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Style Presets")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                        Text("\(counts.templates)")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.blue)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Lyric Sets")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                        Text("\(counts.lyrics)")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.purple)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Database File Size")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                        Text(String(format: "%.1f MB", Double(dbSize) / (1024 * 1024)))
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.green)
                    }
                }
                .padding(10)
                .background(Theme.bgDark)
                .cornerRadius(6)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Python Binary: \(vm.pythonBin)")
                        .font(Theme.mono)
                        .foregroundColor(Theme.comment)
                    Text("Database File: \(vm.dbPath)")
                        .font(Theme.mono)
                        .foregroundColor(Theme.comment)
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Card 3: Apple Silicon Profile
            let profile = SystemProfile.current
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "applelogo")
                        .foregroundColor(Theme.fg)
                    Text("HARDWARE SPECIFICATIONS")
                        .font(Theme.smallBold)
                        .foregroundColor(Theme.comment)
                    Spacer()
                    Text(profile.chipName)
                        .font(Theme.bodyBold)
                        .foregroundColor(Theme.fg)
                }

                HStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Unified Memory")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                        Text(profile.memoryDisplay)
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.fg)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("GPU Budget")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                        Text(String(format: "%.1f GB", profile.usableGPUBudgetGB))
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.green)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Performance Cores")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                        Text("\(profile.performanceCores) cores")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.cyan)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MiniMax Tier")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                        Text(profile.recommendedMiniMaxVariant ?? "Unknown")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.yellow)
                    }
                }
                .padding(10)
                .background(Theme.bgDark)
                .cornerRadius(6)

                Text(profile.tierNotes)
                    .font(Theme.small)
                    .foregroundColor(Theme.comment)
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 1))

            // Card 4: Factory Reset
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Factory Reset Settings")
                            .font(Theme.bodyBold)
                            .foregroundColor(Theme.red)
                        Text("Reset all generation defaults, layout configurations, and endpoint settings back to original clean defaults. This will not delete your audio files or database.")
                            .font(Theme.small)
                            .foregroundColor(Theme.comment)
                    }

                    Spacer()

                    Button("Reset All Preferences…") {
                        showResetConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.red)
                }
            }
            .padding(14)
            .background(Theme.bgFloat)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.red.opacity(0.3), lineWidth: 1))
            .alert("Reset All Preferences?", isPresented: $showResetConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Reset to Factory Defaults", role: .destructive) {
                    vm.resetAllSettingsToFactory()
                    outputDir = SetupManager.defaultOutputDirectory.path
                    modelsDir = SetupManager.defaultModelsDirectory.path
                    resetCompleteBanner = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        resetCompleteBanner = false
                    }
                }
            } message: {
                Text("This resets all default generation parameters, workspace panel sizes, API endpoint preferences, and layout options back to clean defaults.")
            }
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Output Folder"
        if panel.runModal() == .OK, let url = panel.url {
            outputDir = url.path
            UserDefaults.standard.set(url.path, forKey: "outputDirectory")
        }
    }

    private func chooseModelsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Models Folder"
        if panel.runModal() == .OK, let url = panel.url {
            modelsDir = url.path
            UserDefaults.standard.set(url.path, forKey: "modelsDirectory")
        }
    }
}
