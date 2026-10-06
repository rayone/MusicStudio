import SwiftUI
import AppKit

public struct ContentView: View {
    @ObservedObject var vm: StudioViewModel

    public init(vm: StudioViewModel) {
        self.vm = vm
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerBar
                .zIndex(1)

            Divider().background(Theme.border)

            // Main Tab Content
            Group {
                switch vm.selectedTab {
                case .create:
                    createTabView
                case .studio:
                    studioTabView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            // Global Console (FR-001 / FR-002) - visible across both tabs
            if vm.showConsole {
                Divider().background(Theme.border)
                ConsoleView(vm: vm)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.bgDark)
                    .frame(height: vm.consoleHeight)
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $vm.showSettingsSheet) {
            SettingsView(vm: vm)
        }
    }

    // MARK: - Create Tab
    private var createTabView: some View {
        HSplitView {
            // Left Column: Presets Library & Parameters (Fills window height)
            VStack(alignment: .leading, spacing: 10) {
                StyleLibraryView(vm: vm)
                Divider().background(Theme.border)
                ParameterView(vm: vm)
            }
            .padding(12)
            .frame(minWidth: 440, idealWidth: 540, maxWidth: .infinity, maxHeight: .infinity)

            // Right Column: Lyrics, ABC Score (YuE2 with CoT planning), Media Player
            VStack(alignment: .leading, spacing: 10) {
                LyricsEditorView(vm: vm)
                if vm.usesAbcScore {
                    Divider().background(Theme.border)
                    AbcEditorView(vm: vm)
                }

                Divider().background(Theme.border)
                OutputAndHistoryView(vm: vm)
                    .frame(maxHeight: .infinity)
            }
            .padding(12)
            .frame(minWidth: 400, idealWidth: 500, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Studio Tab (FR-002)
    private var studioTabView: some View {
        HSplitView {
            OutputAndHistoryView(vm: vm)
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            StudioInspectorView(vm: vm)
                .frame(minWidth: 360, idealWidth: 440, maxHeight: .infinity)
        }
        .padding(12)
    }

    // MARK: - Header Bar (Global Chrome)
    private var headerBar: some View {
        HStack(spacing: 8) {
            // macOS Traffic Light leading gutter (~78pt)
            Spacer().frame(width: 78)

            // Logo & Title
            HStack(spacing: 6) {
                Image(systemName: "music.note.house.fill")
                    .font(Theme.small)
                    .foregroundColor(Theme.blue)
                Text("MusicStudio")
                    .font(Theme.smallBold)
                    .foregroundColor(Theme.fg)
                    .lineLimit(1)
                    .fixedSize()
            }
            .layoutPriority(1)

            Divider().frame(height: 14)

            // Tab Switcher (Create ⌘1 / Studio ⌘2)
            HStack(spacing: 2) {
                Button(action: { vm.selectedTab = .create }) {
                    HStack(spacing: 4) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11))
                        Text("Create")
                            .font(Theme.smallMedium)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(vm.selectedTab == .create ? Theme.bgHighlight : Color.clear)
                    .foregroundColor(vm.selectedTab == .create ? Theme.fg : Theme.comment)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("1", modifiers: .command)
                .help("Create Tab (⌘1)")

                Button(action: { vm.selectedTab = .studio }) {
                    HStack(spacing: 4) {
                        Image(systemName: "play.square.stack.fill")
                            .font(.system(size: 11))
                        Text("Studio")
                            .font(Theme.smallMedium)

                        if vm.hasUnviewedGenerations {
                            Circle()
                                .fill(Theme.green)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(vm.selectedTab == .studio ? Theme.bgHighlight : Color.clear)
                    .foregroundColor(vm.selectedTab == .studio ? Theme.fg : (vm.hasUnviewedGenerations ? Theme.green : Theme.comment))
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("2", modifiers: .command)
                .help("Studio Library & Player Tab (⌘2)")
            }
            .padding(2)
            .background(Theme.bgDark)
            .cornerRadius(6)

            Divider().frame(height: 14)

            // Model Selection Menu
            Menu {
                let minimaxModels = ModelCatalog.models(for: .minimax_music3).filter { vm.isModelDisplayed(id: $0.id) }
                if !minimaxModels.isEmpty {
                    Section(header: Text("MiniMax Music 3")) {
                        ForEach(minimaxModels) { m in
                            Button(action: {
                                vm.selectModel(id: m.id)
                            }) {
                                HStack {
                                    if vm.selectedModel == m.id {
                                        Text("✓")
                                    }
                                    Text(m.name)
                                    if m.recommended { Text("★") }
                                    if m.isAvailableLocally {
                                        Text("(Ready)")
                                    }
                                }
                            }
                        }
                    }
                }

                let yueModels = ModelCatalog.models(for: .yue2).filter { vm.isModelDisplayed(id: $0.id) }
                if !yueModels.isEmpty {
                    Section(header: Text("YuE2-3B")) {
                        ForEach(yueModels) { m in
                            Button(action: {
                                vm.selectModel(id: m.id)
                            }) {
                                HStack {
                                    if vm.selectedModel == m.id {
                                        Text("✓")
                                    }
                                    Text(m.name)
                                    if m.recommended { Text("★") }
                                    if m.isAvailableLocally {
                                        Text("(Ready)")
                                    }
                                }
                            }
                        }
                    }
                }

                Divider()

                Button("Manage Models in Settings…") {
                    vm.settingsTab = .models
                    vm.showSettingsSheet = true
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                        .foregroundColor(vm.selectedModelFamily == .yue2 ? Theme.yellow : Theme.blue)
                    Text(vm.modelNames[vm.selectedModel] ?? vm.selectedModel.components(separatedBy: ":").last ?? vm.selectedModel)
                        .font(Theme.smallMedium)
                        .foregroundColor(Theme.fg)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.comment)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.bgDark)
                .cornerRadius(4)
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 130, idealWidth: 160, maxWidth: 190)
            .layoutPriority(1)

            if vm.isSongwriterEnabled && vm.showSongwriterInHeader {
                Button(action: { vm.showSongwriterPopover.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 10))
                        Text(vm.selectedSongwriterTitle ?? "Songwriter")
                            .font(Theme.smallMedium)
                            .lineLimit(1)
                    }
                    .foregroundColor(vm.selectedSongwriterId == nil ? Theme.comment : Theme.purple)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.bgDark)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: 130)
                .help("Import a ready song from Songwriter")
                .popover(isPresented: $vm.showSongwriterPopover, arrowEdge: .bottom) {
                    SongwriterPopoverView(vm: vm)
                }
            }
            Spacer()


            if vm.showEtaHeader {
                // Stable ETA display. Fixed dimensions prevent countdown text from shifting controls.
                HStack(spacing: 5) {
                Image(systemName: vm.isGenerating ? "clock.fill" : "clock")
                    .font(.system(size: 11))
                    .foregroundColor(vm.isGenerating ? Theme.green : Theme.comment)
                VStack(alignment: .leading, spacing: 1) {
                    if vm.isGenerating {
                        Text(vm.isEtaOverrun
                             ? "\(vm.liveStage.isEmpty ? "Working" : vm.liveStage) • Finishing…"
                             : "\(vm.liveStage.isEmpty ? "Working" : vm.liveStage) \(Int(vm.liveProgressFraction * 100))% • \(StudioViewModel.humanDuration(vm.liveRemainingSeconds)) left")
                            .font(Theme.smallBold)
                            .foregroundColor(Theme.green)
                            .lineLimit(1)
                        Text(vm.isEtaOverrun
                             ? (vm.queuePending > 1 ? "Current over estimate • queued work follows" : "Current job exceeded historical estimate")
                             : (vm.queuePending > 1 ? "Next \(vm.nextFinishEtaString) • All \(vm.queueFinishEtaString)" : "Done \(vm.nextFinishEtaString)"))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.fgDark)
                            .lineLimit(1)
                    } else if vm.isQueuePaused && vm.queuePending > 0 {
                        Text("Queue paused")
                            .font(Theme.smallBold)
                            .foregroundColor(Theme.yellow)
                        Text("~\(StudioViewModel.humanDuration(vm.queueRemainingSeconds)) remaining")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.comment)
                            .lineLimit(1)
                    } else {
                        Text("ETA ~\(vm.preClickEtaString)")
                            .font(Theme.smallBold)
                            .foregroundColor(Theme.fgDark)
                        if vm.queuePending > 0 && !vm.queueFinishEtaString.isEmpty {
                            Text("Queue done \(vm.queueFinishEtaString)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(Theme.comment)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(width: 300, alignment: .leading)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.bgDark)
            .cornerRadius(4)
            }
            // Open Output Folder Button
            Button(action: {
                let outDir = UserDefaults.standard.string(forKey: "outputDirectory") ?? SetupManager.defaultOutputDirectory.path
                NSWorkspace.shared.open(URL(fileURLWithPath: outDir))
            }) {
                Image(systemName: "folder")
                    .font(Theme.small)
                    .foregroundColor(Theme.fgDark)
            }
            .buttonStyle(.plain)
            .help("Open Output Folder in Finder")

            // Settings Button
            Button(action: {
                vm.showSettingsSheet = true
            }) {
                Image(systemName: "gearshape")
                    .font(Theme.small)
                    .foregroundColor(Theme.fgDark)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
            // Console Toggle Button (FR-001)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    vm.showConsole.toggle()
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "terminal")
                        .font(.system(size: 10))
                    Text("Console")
                        .font(Theme.small)
                    if !vm.logEntries.isEmpty {
                        Text("\(vm.logEntries.count)")
                            .font(.system(size: 9, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.bgHighlight)
                            .cornerRadius(3)
                    }
                }
                .foregroundColor(vm.showConsole ? Theme.blue : Theme.comment)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(vm.showConsole ? Theme.bgHighlight : Theme.bgDark)
                .cornerRadius(4)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .help("Toggle Live Console (⌘K)")

            // Single primary action at the far right. Tokyo Night green = enqueue/go.
            Button(action: { vm.addToQueue() }) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.rectangle.fill")
                        .font(.system(size: 10))
                    Text("Queue")
                        .font(Theme.smallBold)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.green)
                .foregroundColor(Theme.bgDark)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Add current settings to the queue and process them (⌘↩)")

            // Queue management lives directly beside + Queue. Tokyo Night blue = navigation/info.
            Button(action: { vm.showQueuePopover.toggle() }) {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle.fill")
                        .font(.system(size: 10))
                    if vm.queuePending > 0 {
                        Text("\(vm.queuePending)")
                            .font(Theme.smallBold)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.blue)
                .foregroundColor(Theme.bgDark)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .help("Manage queue: pause, resume, remove, or clear jobs")
            .popover(isPresented: $vm.showQueuePopover, arrowEdge: .bottom) {
                QueuePopoverView(vm: vm)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.bgFloat)
    }
}
