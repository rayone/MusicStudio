import SwiftUI
import AppKit

@main
struct MusicStudioApp: App {
    @StateObject private var setupManager = SetupManager.shared
    @StateObject private var vm = StudioViewModel()
    @State private var hasCompletedSetup = false

    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if setupManager.state == .ready || hasCompletedSetup {
                    ContentView(vm: vm)
                        .frame(minWidth: 920, minHeight: 640)
                } else {
                    SetupView(setupManager: setupManager) {
                        hasCompletedSetup = true
                        vm.refreshModels()
                        vm.loadHistory()
                    }
                    .frame(minWidth: 800, minHeight: 620)
                }
            }
            .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    vm.showSettingsSheet = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }

            CommandGroup(replacing: .newItem) {
                Button("Reveal Output Folder") {
                    let outDir = UserDefaults.standard.string(forKey: "outputDirectory") ?? SetupManager.defaultOutputDirectory.path
                    NSWorkspace.shared.open(URL(fileURLWithPath: outDir))
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Reveal Models Folder") {
                    NSWorkspace.shared.open(ModelCatalog.modelsDirectory)
                }
            }

            CommandMenu("View") {
                Button("Create") {
                    vm.selectedTab = .create
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Studio Library") {
                    vm.selectedTab = .studio
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button(vm.showConsole ? "Hide Console" : "Show Console") {
                    withAnimation {
                        vm.showConsole.toggle()
                    }
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Clear Console Logs") {
                    vm.clearLogs()
                }
                .disabled(vm.logEntries.isEmpty)
            }

            CommandMenu("Queue") {
                Button("Add to Queue") {
                    vm.addToQueue()
                }
                .keyboardShortcut(.return, modifiers: .command)

                Button(vm.isQueuePaused ? "Resume Queue" : "Pause Queue") {
                    if vm.isQueuePaused { vm.resumeQueue() }
                    else { vm.pauseQueue() }
                }
                .disabled(vm.queuePending == 0)
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Divider()

                Button("Clear Queue") {
                    vm.clearQueue()
                }
                .disabled(vm.queuePending == 0)
            }

            CommandGroup(replacing: .help) {
                Button("MusicStudio Help") {
                    if let url = URL(string: "https://github.com/rayone/MusicStudio#readme") {
                        NSWorkspace.shared.open(url)
                    }
                }

                Button("Model Catalog & Downloads…") {
                    vm.settingsTab = .models
                    vm.showSettingsSheet = true
                }

                Divider()

                Button("Hardware & System Profile…") {
                    vm.settingsTab = .storage
                    vm.showSettingsSheet = true
                }
            }
        }
    }
}
