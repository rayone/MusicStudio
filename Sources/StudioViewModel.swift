import Foundation
import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers
import IOKit
import IOKit.pwr_mgt

@MainActor
public class StudioViewModel: ObservableObject {
    public let homeDirectory: URL
    public let dbPath: String
    public let pythonBin: String
    public let studioScript: String

    // MARK: - Model Selection & Visibility Configuration
    @Published public var selectedModel: String = "minimax_music3:MiniMax-Music3-mxfp8"
    @Published public var selectedModelFamily: ModelFamily = .minimax_music3
    @Published public var availableModels: [String] = []
    @Published public var modelNames: [String: String] = [:]
    @Published public var unavailableModels: Set<String> = []
    @Published public var modelReasons: [String: String] = [:]

    /// Set of model IDs that the user chose to display in the main header model menu.
    @Published public var displayedModelIds: Set<String> = {
        if let saved = UserDefaults.standard.stringArray(forKey: "displayedModelIds"), !saved.isEmpty {
            return Set(saved)
        }
        return Set(ModelCatalog.bundledModels.map(\.id))
    }() {
        didSet {
            UserDefaults.standard.set(Array(displayedModelIds), forKey: "displayedModelIds")
        }
    }

    public func isModelDisplayed(id: String) -> Bool {
        displayedModelIds.contains(id)
    }

    public func toggleModelDisplay(id: String) {
        if displayedModelIds.contains(id) {
            if displayedModelIds.count > 1 {
                displayedModelIds.remove(id)
            }
        } else {
            displayedModelIds.insert(id)
        }
    }

    public func setModelDisplay(id: String, displayed: Bool) {
        if displayed {
            displayedModelIds.insert(id)
        } else if displayedModelIds.count > 1 {
            displayedModelIds.remove(id)
        }
    }

    public func enableAllModelsDisplay() {
        displayedModelIds = Set(ModelCatalog.bundledModels.map(\.id))
    }

    public func enableOnlyRecommendedModels() {
        let rec = Set(ModelCatalog.bundledModels.filter(\.recommended).map(\.id))
        displayedModelIds = rec.isEmpty ? Set(ModelCatalog.bundledModels.prefix(2).map(\.id)) : rec
    }
    // MARK: - Prompt & Lyrics Inputs
    @Published public var caption: String = "Dark trap beat, 140 BPM, heavy 808s, male vocal"
    @Published public var lyrics: String = """
[verse 1]
Neon lights reflecting on the wet pavement
Walking through the city where the dreams are made
Rhythm in the concrete, pulse inside the veins
Turn the sound up, let it wash away the pain

[chorus]
Echoes in the midnight, bass is running deep
Electric frequency that never falls asleep
Catch the melody, hold it in your hands
Sound of the future rolling through the land
"""
    @Published public var isInstrumental: Bool = false
    @Published public var abcScoreText: String = "" {
        didSet {
            // Any manual edit (not a programmatic engine load) marks the score as user-owned
            if !isLoadingEngineScore {
                abcScoreIsUserEdited = !abcScoreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        }
    }
    public var abcScoreIsUserEdited: Bool = false
    private var isLoadingEngineScore: Bool = false
    // Lyrics Library (FR-006)
    @Published public var availableLyricSets: [LyricSet] = []


    // MARK: - Parameters
    @Published public var duration: Double = 180.0 {
        didSet { if duration != oldValue { updatePreClickEta() } }
    }
    @Published public var steps: Int = 30 {
        didSet { if steps != oldValue { updatePreClickEta() } }
    }
    @Published public var guidance: Double = 1.7
    @Published public var cotMode: CoTMode = .full {
        didSet { if cotMode != oldValue { updatePreClickEta() } }
    }
    /// The ABC score is consumed only by YuE2's symbolic planning (CoT Full/Melody).
    public var usesAbcScore: Bool { selectedModelFamily == .yue2 && cotMode != .off }
    // Seed configuration (FR-010)
    @Published public var isSeedLocked: Bool = false
    @Published public var lockedSeedString: String = ""
    @Published public var seed: Int = 0
    @Published public var outputFormat: AudioFormat = .mp3
    @Published public var batchCount: Int = 1

    // Heights for resizable editors (persisted in UserDefaults)
    @Published public var promptEditorHeight: CGFloat = 240 {
        didSet { UserDefaults.standard.set(Double(promptEditorHeight), forKey: "layoutPromptEditorHeight") }
    }
    @Published public var lyricsEditorHeight: CGFloat = 140 {
        didSet { UserDefaults.standard.set(Double(lyricsEditorHeight), forKey: "layoutLyricsEditorHeight") }
    }
    @Published public var abcEditorHeight: CGFloat = 60 {
        didSet { UserDefaults.standard.set(Double(abcEditorHeight), forKey: "layoutAbcEditorHeight") }
    }
    // MARK: - Progress & Status
    @Published public var isGenerating: Bool = false
    /// Processing state is persisted so a deliberately-paused queue does not auto-run on relaunch.
    @Published public var isQueuePaused: Bool = UserDefaults.standard.bool(forKey: "queueProcessingPaused")
    @Published public var statusText: String = "Ready"
    @Published public var liveStage: String = ""
    @Published public var liveEtaString: String = ""
    @Published public var preClickEtaString: String = ""
    /// Estimated wall-clock seconds for a single song at current params (calibrated or formula).
    @Published public var estimatedSongSeconds: Double = 0
    /// "when the currently-running/next song will finish" — human string.
    @Published public var nextFinishEtaString: String = ""
    /// Total estimated remaining processing time for the active/paused queue.
    @Published public var queueRemainingSeconds: Double = 0
    /// "when everything in the queue will finish" — human string.
    @Published public var queueFinishEtaString: String = ""
    /// Live remaining seconds for the currently-running song (estimate minus elapsed).
    @Published public var liveRemainingSeconds: Double = 0
    /// Wall-clock start of the currently-running song, for live remaining computation.
    var generationStartTime: Date?
    /// 0..1 completion of the currently-running song, driven by the active stage
    /// (AR frames / NAR steps / Flow chunks). Used for the running-row progress bar.
    @Published public var liveProgressFraction: Double = 0
    /// True when wall-clock runtime has exceeded the historical estimate. At that point
    /// an exact countdown would be dishonest; UI shows “Finishing…” until completion.
    @Published public var isEtaOverrun: Bool = false
    /// Repeating 1s timer that keeps the countdown/clock ETAs live between engine events.
    private var etaTicker: Timer?
    @Published public var evaluatingGenerationId: Int? = nil
    @Published public var evalInstallStage: String = ""
    @Published public var evalInstallFraction: Double = 0.0
    public var isEvaluationRunning: Bool { evaluationProcess != nil }

    // MiniMax Progress metrics
    @Published public var currentArFrame: Int = 0
    @Published public var totalArFrames: Int = 0
    @Published public var currentArFps: Double = 0.0
    @Published public var currentFlowChunk: Int = 0
    @Published public var totalFlowChunks: Int = 0

    // YuE2 Progress metrics
    @Published public var currentNarStep: Int = 0
    @Published public var totalNarSteps: Int = 32

    // Console logs (FR-001)
    @Published public var logEntries: [LogEntry] = []
    @Published public var logs: [String] = []
    @Published public var showConsole: Bool = false
    // MARK: - Navigation Tabs (FR-002)
    public enum MainTab: String, CaseIterable, Identifiable {
        case create = "create"
        case studio = "studio"
        public var id: String { rawValue }
    }

    @Published public var selectedTab: MainTab = {
        let saved = UserDefaults.standard.string(forKey: "selectedMainTab") ?? "create"
        return MainTab(rawValue: saved) ?? .create
    }() {
        didSet {
            UserDefaults.standard.set(selectedTab.rawValue, forKey: "selectedMainTab")
            if selectedTab == .studio {
                hasUnviewedGenerations = false
            }
            appendLog(component: .ui, level: .info, message: "Switched main tab to \(selectedTab.rawValue.capitalized)", detail: "tab=\(selectedTab.rawValue)")
        }
    }

    @Published public var hasUnviewedGenerations: Bool = false
    @Published public var selectedLogComponents: Set<LogComponent> = Set(LogComponent.allCases)
    @Published public var selectedLogLevel: LogLevel = .trace
    // MARK: - Prompt Token Safety (FR-007)
    public var estimatedCaptionTokens: Int {
        Int(ceil(Double(caption.count) / 3.5)) + 12
    }

    public var estimatedLyricsTokens: Int {
        Int(ceil(Double(lyrics.count) / 3.5)) + 12
    }

    public var totalPromptTokens: Int {
        let textLen = caption.count + lyrics.count
        return Int(ceil(Double(textLen) / 3.5)) + 24
    }

    public var tokenColor: Color {
        if totalPromptTokens > 5000 {
            return Theme.red
        } else if totalPromptTokens > 4500 {
            return Theme.orange
        } else if totalPromptTokens > 3800 {
            return Theme.yellow
        } else {
            return Theme.comment
        }
    }

    @Published public var logSearchText: String = ""

    public var filteredLogEntries: [LogEntry] {
        logEntries.filter { entry in
            guard entry.level >= selectedLogLevel else { return false }
            guard selectedLogComponents.contains(entry.component) else { return false }
            if !logSearchText.isEmpty {
                return entry.plain.localizedCaseInsensitiveContains(logSearchText)
            }
            return true
        }
    }

    public func appendLog(component: LogComponent, level: LogLevel = .info, message: String, detail: String = "") {
        let entry = LogEntry(component: component, level: level, message: message, detail: detail)
        logEntries.append(entry)
        logs.append(entry.plain)
        if logEntries.count > 5000 {
            logEntries.removeFirst(1000)
            logs.removeFirst(1000)
        }
    }

    public func appendLog(_ rawText: String, component: LogComponent = .app, level: LogLevel = .info) {
        var comp = component
        var lvl = level
        var msg = rawText
        let det = ""

        if rawText.hasPrefix("["), let closingIdx = rawText.firstIndex(of: "]") {
            let tag = String(rawText[rawText.index(after: rawText.startIndex)..<closingIdx]).lowercased()
            let remainder = String(rawText[rawText.index(after: closingIdx)...]).trimmingCharacters(in: .whitespaces)
            msg = remainder
            switch tag {
            case "queue": comp = .queue
            case "worker": comp = .worker
            case "model": comp = .model
            case "power": comp = .power
            case "setup": comp = .setup
            case "hf": comp = .hf
            case "autoregressive", "ar": comp = .ar; lvl = .debug
            case "flowmatching", "flow", "dit": comp = .flow; lvl = .debug
            case "nar": comp = .nar; lvl = .debug
            case "vae": comp = .vae
            case "plan", "cot": comp = .cot
            case "convert": comp = .convert
            case "loudness": comp = .loudness
            case "tags": comp = .tags
            case "db": comp = .db
            case "search": comp = .search
            case "embed": comp = .embed
            case "timing": comp = .model; lvl = .debug
            case "error": comp = .worker; lvl = .error
            default: break
            }
        }

        appendLog(component: comp, level: lvl, message: msg, detail: det)
    }

    public func clearLogs() {
        logEntries.removeAll()
        logs.removeAll()
    }
    // History & Queue
    @Published public var history: [GenerationHistoryItem] = []
    @Published public var queueJobs: [QueueJobItem] = []
    @Published public var queuePending: Int = 0
    @Published public var songwriterSongs: [SongwriterSongSummary] = []
    @Published public var isLoadingSongwriter: Bool = false
    @Published public var songwriterError: String? = nil
    @Published public var showSongwriterPopover: Bool = false
    @Published public var selectedSongwriterId: String? = nil
    @Published public var selectedSongwriterRevision: Int? = nil
    @Published public var selectedSongwriterTitle: String? = nil
    @Published public var songwriterLastConnectedAt: Date? = nil

    // Presets & Templates
    @Published public var templates: [PromptTemplate] = []
    @Published public var filteredTemplates: [PromptTemplate] = []
    @Published public var selectedTemplate: PromptTemplate? = nil
    @Published public var templateLoadNote: String = ""
    @Published public var searchQuery: String = "" {
        didSet {
            scheduleTemplateSearch()
        }
    }
    @Published public var isSemanticSearch: Bool = true {
        didSet {
            scheduleTemplateSearch()
        }
    }
    private var searchWorkItem: DispatchWorkItem?
    @Published public var sortColumn: String = "title"
    @Published public var sortAscending: Bool = true
    @Published public var activeKeywords: [String] = []
    @Published public var keywordSuggestions: [Keyword] = []
    @Published public var allKeywords: [Keyword] = []
    @Published public var selectedKey: String = "All"
    @Published public var selectedScale: String = "All"
    @Published public var selectedVocal: String = "All"
    @Published public var selectedTimeSignature: String = "All"
    @Published public var selectedVocalRegister: String = "All"
    @Published public var selectedLanguage: String = "All"
    // Audio Playback
    @Published public var isPlayingAudio: Bool = false
    @Published public var currentPlayingFile: String? = nil
    @Published public var audioProgress: Double = 0.0
    @Published public var audioDuration: Double = 0.0

    // MARK: - Studio Tab (inspector + spectrogram)
    /// Track selected in the Studio library, driving the metadata inspector + spectrogram.
    @Published public var selectedTrack: GenerationHistoryItem? = nil
    /// Cached spectrogram PNG path keyed by audio file; nil value = render in flight.
    @Published public var spectrogramPaths: [String: String] = [:]
    private var spectrogramInFlight: Set<String> = []

    // MARK: - Studio Tab (VST/AU plugin)
    /// Currently loaded external effect plugin + its parameters (nil = none loaded).
    @Published public var loadedPlugin: VSTPlugin? = nil
    /// Editable parameter list, kept separate so SwiftUI can bind each row.
    @Published public var pluginParameters: [VSTParameter] = []
    /// True while loading a plugin's parameters or rendering through it.
    @Published public var pluginBusy: Bool = false
    /// Last plugin error/status message for the inspector.
    @Published public var pluginStatus: String = ""
    /// Path of the file produced by the last plugin render, for playback.
    @Published public var pluginOutputFile: String? = nil
    /// How the loaded plugin runs: real-time AU node, or offline re-render (VST3, or an AU
    /// that couldn't be hosted live).
    public enum PluginEngineMode: String { case realtimeAU, offline, none }
    @Published public var pluginEngineMode: PluginEngineMode = .none
    /// True once a live AU node is active in the playback graph.
    @Published public var pluginLiveActive: Bool = false
    /// Debounce handle for VST3 near-real-time re-render.
    private var vstRerenderWork: DispatchWorkItem?
    private let auWindow = AudioUnitWindowController()
    /// Description of the active live AU, reused for offline "Save Audio" renders.
    private var liveAUDescription: AudioComponentDescription?
    /// Temp WAV currently used for VST3 preview playback; replaced on each re-render.
    private var vstPreviewFile: URL?

    // MARK: - Unified Settings
    public enum SettingsTab: String, CaseIterable, Identifiable {
        case api = "api"
        case models = "models"
        case defaults = "defaults"
        case layout = "layout"
        case storage = "storage"

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .api: return "API & Endpoint"
            case .models: return "Models & Weights"
            case .defaults: return "Generation Defaults"
            case .layout: return "Layout & Interface"
            case .storage: return "Storage & System"
            }
        }

        public var icon: String {
            switch self {
            case .api: return "network"
            case .models: return "cpu"
            case .defaults: return "slider.horizontal.3"
            case .layout: return "uiwindow.split.2x1"
            case .storage: return "internaldrive"
            }
        }
    }

    @Published public var settingsTab: SettingsTab = .api
    @Published public var isSongwriterEnabled: Bool = SongwriterAPI.isEnabled {
        didSet {
            SongwriterAPI.isEnabled = isSongwriterEnabled
            if !isSongwriterEnabled {
                songwriterSongs = []
                songwriterError = nil
            }
        }
    }

    // Layout Preferences
    @Published public var showEtaHeader: Bool = true {
        didSet { UserDefaults.standard.set(showEtaHeader, forKey: "layoutShowEtaHeader") }
    }
    @Published public var showSongwriterInHeader: Bool = true {
        didSet { UserDefaults.standard.set(showSongwriterInHeader, forKey: "layoutShowSongwriterInHeader") }
    }
    @Published public var showConsoleOnLaunch: Bool = false {
        didSet { UserDefaults.standard.set(showConsoleOnLaunch, forKey: "layoutShowConsoleOnLaunch") }
    }
    @Published public var consoleHeight: CGFloat = 180 {
        didSet { UserDefaults.standard.set(Double(consoleHeight), forKey: "layoutConsoleHeight") }
    }
    @Published public var defaultLaunchTab: MainTab = .create {
        didSet { UserDefaults.standard.set(defaultLaunchTab.rawValue, forKey: "defaultLaunchTab") }
    }

    // Generation Defaults Preferences
    @Published public var defaultModelId: String = "minimax_music3:MiniMax-Music3-mxfp8" {
        didSet { UserDefaults.standard.set(defaultModelId, forKey: "defaultModelId") }
    }
    @Published public var defaultDuration: Double = 180.0 {
        didSet { UserDefaults.standard.set(defaultDuration, forKey: "defaultDuration") }
    }
    @Published public var defaultSteps: Int = 30 {
        didSet { UserDefaults.standard.set(defaultSteps, forKey: "defaultSteps") }
    }
    @Published public var defaultGuidance: Double = 1.7 {
        didSet { UserDefaults.standard.set(defaultGuidance, forKey: "defaultGuidance") }
    }
    @Published public var defaultCotMode: CoTMode = .full {
        didSet { UserDefaults.standard.set(defaultCotMode.rawValue, forKey: "defaultCotMode") }
    }
    @Published public var defaultOutputFormat: AudioFormat = .mp3 {
        didSet { UserDefaults.standard.set(defaultOutputFormat.rawValue, forKey: "defaultOutputFormat") }
    }
    @Published public var defaultBatchCount: Int = 1 {
        didSet { UserDefaults.standard.set(defaultBatchCount, forKey: "defaultBatchCount") }
    }
    @Published public var defaultInstrumental: Bool = false {
        didSet { UserDefaults.standard.set(defaultInstrumental, forKey: "defaultInstrumental") }
    }

    // Sheets
    @Published public var showModelManagerSheet: Bool = false {
        didSet {
            if showModelManagerSheet {
                settingsTab = .models
                showSettingsSheet = true
                showModelManagerSheet = false
            }
        }
    }
    @Published public var showSettingsSheet: Bool = false
    @Published public var showQueuePopover: Bool = false
    @Published public var showNewTemplateSheet: Bool = false
    private let audioEngine = AudioEngine()
    private var playbackTimer: Timer?
    private var sleepAssertionId: IOPMAssertionID = 0
    @Published public var lastWorkerError: String? = nil
    private var workerProcess: Process?
    private var evaluationProcess: Process?
    private var isSeeking = false

    public init() {
        self.homeDirectory = SetupManager.defaultHomeDirectory
        self.dbPath = DB.defaultDatabasePath

        self.pythonBin = SetupManager.pythonBinURL.path

        let bundleResourceURL = Bundle.main.resourceURL ?? URL(fileURLWithPath: "Resources")
        self.studioScript = bundleResourceURL.appendingPathComponent("studio.py").path

        // Hook DB logging
        DB.logger = { [weak self] comp, lvl, msg, det in
            DispatchQueue.main.async {
                self?.appendLog(component: comp, level: lvl, message: msg, detail: det)
            }
        }

        // Initialize DB shared instance if needed
        if DB.shared == nil {
            DB.shared = DB(path: self.dbPath)
        }

        self.appendLog(component: .app, level: .info, message: "MusicStudio initialized", detail: "home=\(homeDirectory.path) db=\(dbPath)")

        self.refreshModels()
        self.loadHistory()
        self.loadTemplates()
        // A prior process cannot still own a live job during a new app launch. Return any
        // orphaned running row to the front of the queue before deciding whether to resume.
        DB.shared.requeueRunningJobs()
        self.refreshQueueDepth()
        self.updatePreClickEta()
        self.refreshLyrics()

        if queuePending > 0 {
            appendLog(component: .queue, level: .info, message: "\(queuePending) job(s) pending in database", detail: "pending=\(queuePending) paused=\(isQueuePaused)")
            if !isQueuePaused { startWorkerIfNeeded() }
        }
        // Load Layout Preferences
        let savedPromptHeight = UserDefaults.standard.double(forKey: "layoutPromptEditorHeight")
        if savedPromptHeight >= 80 { self.promptEditorHeight = CGFloat(savedPromptHeight) }

        let savedLyricsHeight = UserDefaults.standard.double(forKey: "layoutLyricsEditorHeight")
        if savedLyricsHeight >= 60 { self.lyricsEditorHeight = CGFloat(savedLyricsHeight) }

        let savedAbcHeight = UserDefaults.standard.double(forKey: "layoutAbcEditorHeight")
        if savedAbcHeight >= 30 { self.abcEditorHeight = CGFloat(savedAbcHeight) }

        let savedConsoleHeight = UserDefaults.standard.double(forKey: "layoutConsoleHeight")
        if savedConsoleHeight >= 80 { self.consoleHeight = CGFloat(savedConsoleHeight) }

        if UserDefaults.standard.object(forKey: "layoutShowEtaHeader") != nil {
            self.showEtaHeader = UserDefaults.standard.bool(forKey: "layoutShowEtaHeader")
        }
        if UserDefaults.standard.object(forKey: "layoutShowSongwriterInHeader") != nil {
            self.showSongwriterInHeader = UserDefaults.standard.bool(forKey: "layoutShowSongwriterInHeader")
        }
        self.showConsoleOnLaunch = UserDefaults.standard.bool(forKey: "layoutShowConsoleOnLaunch")
        self.showConsole = self.showConsoleOnLaunch

        if let savedLaunchTab = UserDefaults.standard.string(forKey: "defaultLaunchTab"),
           let tab = MainTab(rawValue: savedLaunchTab) {
            self.defaultLaunchTab = tab
            self.selectedTab = tab
        }

        // Load Generation Defaults
        // Load Generation Defaults & Last Selected Model
        if let lastModel = UserDefaults.standard.string(forKey: "lastSelectedModel"), !lastModel.isEmpty {
            self.selectedModel = lastModel
            if let def = ModelCatalog.model(withId: lastModel) {
                self.selectedModelFamily = def.family
            }
        } else if let savedModel = UserDefaults.standard.string(forKey: "defaultModelId"), !savedModel.isEmpty {
            self.defaultModelId = savedModel
            self.selectedModel = savedModel
            if let def = ModelCatalog.model(withId: savedModel) {
                self.selectedModelFamily = def.family
            }
        }
        if let savedModel = UserDefaults.standard.string(forKey: "defaultModelId"), !savedModel.isEmpty {
            self.defaultModelId = savedModel
        }
        let savedDuration = UserDefaults.standard.double(forKey: "defaultDuration")
        if savedDuration > 0 {
            self.defaultDuration = savedDuration
            self.duration = savedDuration
        }
        let savedSteps = UserDefaults.standard.integer(forKey: "defaultSteps")
        if savedSteps > 0 {
            self.defaultSteps = savedSteps
            self.steps = savedSteps
        }
        let savedGuidance = UserDefaults.standard.double(forKey: "defaultGuidance")
        if savedGuidance > 0 {
            self.defaultGuidance = savedGuidance
            self.guidance = savedGuidance
        }
        if let savedCot = UserDefaults.standard.string(forKey: "defaultCotMode"),
           let mode = CoTMode(rawValue: savedCot) {
            self.defaultCotMode = mode
            self.cotMode = mode
        }
        if let savedFmt = UserDefaults.standard.string(forKey: "defaultOutputFormat"),
           let fmt = AudioFormat(rawValue: savedFmt) {
            self.defaultOutputFormat = fmt
            self.outputFormat = fmt
        }
        let savedBatch = UserDefaults.standard.integer(forKey: "defaultBatchCount")
        if savedBatch > 0 {
            self.defaultBatchCount = savedBatch
            self.batchCount = savedBatch
        }
        if UserDefaults.standard.object(forKey: "defaultInstrumental") != nil {
            let savedInst = UserDefaults.standard.bool(forKey: "defaultInstrumental")
            self.defaultInstrumental = savedInst
            self.isInstrumental = savedInst
        }
    }

    public func loadSongwriterSongs() {
        guard isSongwriterEnabled else {
            songwriterSongs = []
            songwriterError = nil
            isLoadingSongwriter = false
            return
        }
        guard !isLoadingSongwriter else { return }
        isLoadingSongwriter = true
        songwriterError = nil
        Task {
            do {
                songwriterSongs = try await SongwriterAPI.shared.songs()
                songwriterError = nil
                songwriterLastConnectedAt = Date()
            } catch let error as URLError {
                songwriterError = error.code == .cannotConnectToHost
                    ? "Cannot connect to Songwriter at \(SongwriterAPI.configuredBaseURL). Check that Songwriter is running or open Settings."
                    : error.localizedDescription
            } catch {
                songwriterError = error.localizedDescription
            }
            isLoadingSongwriter = false
        }
    }

    public func importSongwriterSong(_ summary: SongwriterSongSummary) {
        guard !isLoadingSongwriter else { return }
        isLoadingSongwriter = true
        songwriterError = nil
        Task {
            do {
                let song = try await SongwriterAPI.shared.song(id: summary.id)
                let input = selectedModelFamily == .yue2 ? song.model_inputs?.yue2 : song.model_inputs?.minimax
                caption = input?.style ?? input?.caption ?? song.creative.caption
                lyrics = input?.lyrics ?? song.creative.lyrics
                isInstrumental = song.creative.instrumental
                if let suggestedDuration = song.creative.duration_hint_sec, suggestedDuration > 0 {
                    duration = suggestedDuration
                }
                if selectedModelFamily == .yue2 {
                    isLoadingEngineScore = true
                    abcScoreText = input?.abc_score ?? ""
                    isLoadingEngineScore = false
                }
                selectedSongwriterId = song.id
                selectedSongwriterRevision = song.revision
                selectedSongwriterTitle = song.title
                showSongwriterPopover = false
                statusText = "Imported from Songwriter: \(song.title)"
                appendLog(component: .ui, level: .info, message: "Imported Songwriter song", detail: "id=\(song.id) revision=\(song.revision)")
            } catch {
                songwriterError = error.localizedDescription
            }
            isLoadingSongwriter = false
        }
    }

    public func clearSongwriterSelection() {
        selectedSongwriterId = nil
        selectedSongwriterRevision = nil
        selectedSongwriterTitle = nil
        statusText = "Songwriter association cleared"
    }

    // MARK: - Defaults & Layout Actions
    public func applyGenerationDefaultsToCurrentSession() {
        if !defaultModelId.isEmpty && (availableModels.contains(defaultModelId) || ModelCatalog.model(withId: defaultModelId) != nil) {
            selectModel(id: defaultModelId)
        }
        self.duration = defaultDuration
        self.steps = defaultSteps
        self.guidance = defaultGuidance
        self.cotMode = defaultCotMode
        self.outputFormat = defaultOutputFormat
        self.batchCount = defaultBatchCount
        self.isInstrumental = defaultInstrumental
        self.updatePreClickEta()
        self.appendLog(component: .ui, level: .info, message: "Applied generation defaults to active session")
    }

    public func resetGenerationDefaultsToFactory() {
        let recMiniMax = ModelCatalog.recommendedModel(for: .minimax_music3)?.id ?? "minimax_music3:MiniMax-Music3-mxfp8"
        self.defaultModelId = recMiniMax
        self.defaultDuration = 180.0
        self.defaultSteps = 30
        self.defaultGuidance = 1.7
        self.defaultCotMode = .full
        self.defaultOutputFormat = .mp3
        self.defaultBatchCount = 1
        self.defaultInstrumental = false
        UserDefaults.standard.removeObject(forKey: "defaultModelId")
        UserDefaults.standard.removeObject(forKey: "defaultDuration")
        UserDefaults.standard.removeObject(forKey: "defaultSteps")
        UserDefaults.standard.removeObject(forKey: "defaultGuidance")
        UserDefaults.standard.removeObject(forKey: "defaultCotMode")
        UserDefaults.standard.removeObject(forKey: "defaultOutputFormat")
        UserDefaults.standard.removeObject(forKey: "defaultBatchCount")
        UserDefaults.standard.removeObject(forKey: "defaultInstrumental")
        self.appendLog(component: .ui, level: .info, message: "Reset generation defaults to factory")
    }

    public func resetLayoutDefaultsToFactory() {
        self.promptEditorHeight = 240
        self.lyricsEditorHeight = 140
        self.abcEditorHeight = 60
        self.consoleHeight = 180
        self.showEtaHeader = true
        self.showSongwriterInHeader = true
        self.showConsoleOnLaunch = false
        self.defaultLaunchTab = .create
        UserDefaults.standard.removeObject(forKey: "layoutPromptEditorHeight")
        UserDefaults.standard.removeObject(forKey: "layoutLyricsEditorHeight")
        UserDefaults.standard.removeObject(forKey: "layoutAbcEditorHeight")
        UserDefaults.standard.removeObject(forKey: "layoutConsoleHeight")
        UserDefaults.standard.removeObject(forKey: "layoutShowEtaHeader")
        UserDefaults.standard.removeObject(forKey: "layoutShowSongwriterInHeader")
        UserDefaults.standard.removeObject(forKey: "layoutShowConsoleOnLaunch")
        UserDefaults.standard.removeObject(forKey: "defaultLaunchTab")
        self.appendLog(component: .ui, level: .info, message: "Reset layout preferences to factory")
    }

    public func resetAllSettingsToFactory() {
        resetGenerationDefaultsToFactory()
        resetLayoutDefaultsToFactory()
        UserDefaults.standard.removeObject(forKey: "outputDirectory")
        UserDefaults.standard.removeObject(forKey: "modelsDirectory")
        UserDefaults.standard.removeObject(forKey: "hfToken")
        UserDefaults.standard.removeObject(forKey: "songwriterAPIBaseURL")
        UserDefaults.standard.removeObject(forKey: "songwriterAPIToken")
        UserDefaults.standard.removeObject(forKey: "songwriterAPIEnabled")
        self.isSongwriterEnabled = true
        self.appendLog(component: .ui, level: .warn, message: "Reset all application settings to factory")
    }

    deinit {
        if sleepAssertionId != 0 {
            IOPMAssertionRelease(sleepAssertionId)
        }
        playbackTimer?.invalidate()
    }

    // MARK: - Model Configuration
    public func selectModel(id: String) {
        self.selectedModel = id
        UserDefaults.standard.set(id, forKey: "lastSelectedModel")
        if let def = ModelCatalog.model(withId: id) {
            self.selectedModelFamily = def.family
            applyModelDefaults(for: def.family)
        } else if id.lowercased().contains("yue2") {
            self.selectedModelFamily = .yue2
            applyModelDefaults(for: .yue2)
        } else {
            self.selectedModelFamily = .minimax_music3
            applyModelDefaults(for: .minimax_music3)
        }
        self.rerenderCaptionForModelChange()
        self.updatePreClickEta()
        self.appendLog(component: .model, level: .info, message: "Selected active model: \(modelNames[id] ?? id)")
    }

    /// When the model family changes, re-render the currently selected template's prompt
    /// into the format the newly selected model expects (structured for MiniMax, tagline for YuE2).
    public func rerenderCaptionForModelChange() {
        if selectedModelFamily == .yue2 {
            // Prefer the structured template if one is selected; otherwise collapse the
            // current (possibly hand-typed or multi-line MiniMax) caption into a tagline.
            if let pt = selectedTemplate {
                self.caption = buildYuE2Tagline(from: pt)
            } else {
                self.caption = renderStyleTagline(from: caption)
            }
        } else {
            // Switching to MiniMax: restore the structured caption from the template when available.
            if let pt = selectedTemplate {
                self.caption = pt.caption
            }
            // No template: leave the user's caption as-is (a tagline is still valid MiniMax input).
        }
    }

    public func applyModelDefaults(for family: ModelFamily) {
        switch family {
        case .minimax_music3:
            // MiniMax: 30 flow steps is the quality sweet spot; DiT CFG 1.7 is the tuned default.
            self.steps = 30
            self.guidance = 1.7
            self.duration = min(max(self.duration, 10), 360)
        case .yue2:
            // YuE2: 32 NAR midpoint steps (engine default); CFG 1.0 (native), full CoT planning.
            self.steps = 32
            self.guidance = 1.0
            self.cotMode = .full
            self.duration = min(max(self.duration, 10), 360)
        }
        updatePreClickEta()
    }

    public func refreshModels() {
        let bundled = ModelCatalog.bundledModels
        let locallyMissing = Set(bundled.compactMap { $0.isAvailableLocally ? nil : $0.id })
        self.availableModels = bundled.map(\.id)
        self.modelNames = Dictionary(uniqueKeysWithValues: bundled.map { ($0.id, $0.name) })
        self.unavailableModels = []
        self.modelReasons = Dictionary(uniqueKeysWithValues: locallyMissing.map { ($0, "Weights not yet downloaded to disk") })

        if selectedModel.isEmpty {
            if let last = UserDefaults.standard.string(forKey: "lastSelectedModel"), !last.isEmpty {
                self.selectedModel = last
            } else if let def = UserDefaults.standard.string(forKey: "defaultModelId"), !def.isEmpty {
                self.selectedModel = def
            } else {
                let recommended = ModelCatalog.recommendedModel(for: selectedModelFamily)?.id
                self.selectedModel = recommended ?? "minimax_music3:MiniMax-Music3-mxfp8"
            }
        }
        if let selected = ModelCatalog.model(withId: self.selectedModel) {
            self.selectedModelFamily = selected.family
        }
        updatePreClickEta()
    }

    /// Formula-based per-song estimate (fallback when no historical data exists).
    private func formulaSongSeconds() -> Double {
        let mid = selectedModel.lowercased()
        if selectedModelFamily == .minimax_music3 {
            let isBf16 = mid.contains("bf16")
            let is4bit = mid.contains("4bit")
            let load = isBf16 ? 2.7 : (is4bit ? 1.8 : 2.2)
            let arFps = isBf16 ? 15.0 : (is4bit ? 31.0 : 26.5)
            let chunkStepCost = isBf16 ? (0.44 / 30.0) : (is4bit ? (0.18 / 30.0) : (0.22 / 30.0))
            let frames = Int(duration * 25.0)
            let chunks = frames <= 200 ? 1 : ((frames - 100) / 100)
            return load + Double(frames) / arFps + Double(chunks * steps) * chunkStepCost + 2.0
        } else {
            let isBf16 = mid.contains("bf16")
            let is4bit = mid.contains("4bit")
            let load = isBf16 ? 3.0 : (is4bit ? 1.6 : 2.2)
            let cotCost = cotMode == .off ? 0.0 : (cotMode == .melody ? 1.5 : (isBf16 ? 4.0 : 3.0))
            let semRate = isBf16 ? 18.0 : (is4bit ? 28.0 : 24.0)
            let semSecs = (duration * 25.0) / semRate
            let narStepCost = isBf16 ? 0.75 : (is4bit ? 0.35 : 0.45)
            let narSecs = Double(steps) * narStepCost
            let vaeSecs = isBf16 ? 2.5 : (is4bit ? 1.5 : 1.8)
            return load + cotCost + semSecs + narSecs + vaeSecs + 0.6
        }
    }

    /// Estimate wall-clock seconds for one song at the current model + params.
    /// Prefers calibrated history (median sec-of-compute per sec-of-audio, scaled by duration);
    /// blends in the formula's fixed load/step overhead; falls back to pure formula.
    public func estimateSongSeconds() -> Double {
        let formula = formulaSongSeconds()
        if let ratio = DB.shared.calibratedSecondsPerAudioSecond(modelId: selectedModel), ratio > 0 {
            // Calibrated model runs mostly scale with audio duration; use recorded ratio.
            let calibrated = ratio * duration
            // Guard against a single anomalous sample by clamping to a sane band around the formula.
            let lo = formula * 0.35
            let hi = formula * 4.0
            return min(max(calibrated, lo), hi)
        }
        return formula
    }

    public func updatePreClickEta() {
        let per = estimateSongSeconds()
        self.estimatedSongSeconds = per
        self.preClickEtaString = Self.humanDuration(per)
        recomputeQueueEta()
    }

    /// Compute next-song and full-queue ETA from each queued item's actual model/duration.
    public func recomputeQueueEta() {
        let activeJobs = queueJobs.filter { $0.status != "error" }
        guard !activeJobs.isEmpty else {
            self.nextFinishEtaString = ""
            self.queueFinishEtaString = ""
            self.queueRemainingSeconds = 0
            return
        }

        var estimates = activeJobs.map { job in
            estimateSongSeconds(modelId: job.modelId, audioDuration: job.duration)
        }
        if let runningIndex = activeJobs.firstIndex(where: { $0.status == "running" }) {
            estimates[runningIndex] = isEtaOverrun ? 0 : liveRemainingSeconds
        }

        let nextRemaining = estimates[0]
        let allRemaining = estimates.reduce(0, +)
        self.queueRemainingSeconds = allRemaining
        if isQueuePaused && !isGenerating {
            self.nextFinishEtaString = "Paused • ~\(Self.humanDuration(nextRemaining)) remaining"
            self.queueFinishEtaString = "Paused • ~\(Self.humanDuration(allRemaining)) remaining"
            return
        }

        let now = Date()
        let df = DateFormatter()
        df.dateFormat = "h:mm a"
        self.nextFinishEtaString = "\(df.string(from: now.addingTimeInterval(nextRemaining))) (\(Self.humanDuration(nextRemaining)))"
        self.queueFinishEtaString = "\(df.string(from: now.addingTimeInterval(allRemaining))) (\(Self.humanDuration(allRemaining)))"
    }

    static func humanDuration(_ total: Double) -> String {
        let t = max(0, Int(total.rounded()))
        let mins = t / 60
        let secs = t % 60
        if mins >= 60 {
            let h = mins / 60
            let m = mins % 60
            return "\(h)h \(m)m"
        }
        return mins > 0 ? "\(mins)m \(secs)s" : "\(secs)s"
    }

    /// Per-song wall-clock estimate for an arbitrary model + audio duration, using the
    /// same DB-history calibration as the live song. Used for queued-row and total ETAs
    /// so each row reflects its own model/duration rather than the create-tab defaults.
    public func estimateSongSeconds(modelId: String, audioDuration: Double) -> Double {
        if let ratio = DB.shared?.calibratedSecondsPerAudioSecond(modelId: modelId), ratio > 0 {
            return ratio * audioDuration
        }
        // No history for this model: fall back to the create-tab formula scaled to duration.
        let base = formulaSongSeconds()
        let baseDur = max(duration, 1)
        return base * (audioDuration / baseDur)
    }

    /// Engine progress events describe the current stage only. ETA and percentage are owned
    /// exclusively by the monotonic wall-clock ticker so sparse stage events cannot make them jump.
    func updateLiveProgress(fraction: Double, rateRemaining: Double? = nil) {
        recomputeQueueEta()
    }

    /// One monotonic clock owns both remaining time and percentage. The runtime estimate is
    /// captured once when the job starts and never rewritten by stage/frame events.
    func startEtaTicker() {
        etaTicker?.invalidate()
        etaTicker = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                guard self.isGenerating, let start = self.generationStartTime else { return }
                let estimate = max(self.estimatedSongSeconds, 1)
                let elapsed = max(Date().timeIntervalSince(start), 0)
                self.isEtaOverrun = elapsed >= estimate
                self.liveRemainingSeconds = max(estimate - elapsed, 0)
                self.liveProgressFraction = min(elapsed / estimate, 0.99)
                self.recomputeQueueEta()
            }
        }
    }

    func stopEtaTicker() {
        etaTicker?.invalidate()
        etaTicker = nil
    }

    // MARK: - Template & Style Library
    public func loadTemplates() {
        templateLoadNote = "Loading presets..."
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let items = DB.shared.fetchTemplates()
            let kws = DB.shared.fetchKeywords()

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.templates = items
                self.filteredTemplates = items
                self.allKeywords = kws
                self.templateLoadNote = ""
                self.filterTemplates()
            }
        }
    }

    public func selectTemplate(_ pt: PromptTemplate) {
        self.selectedTemplate = pt
        if selectedModelFamily == .yue2 {
            self.caption = buildYuE2Tagline(from: pt)
        } else {
            self.caption = pt.caption
        }
        self.statusText = "Selected style: \(pt.title)"
    }
    public func createTemplate(
        title: String,
        genre: String,
        subgenre: String = "",
        bpm: Int? = nil,
        key: String? = nil,
        scale: String? = nil,
        vocal: String = "unknown",
        time_signature: String = "4/4",
        vocal_register: String? = nil,
        language: String = "english",
        pro_tip: String = "",
        caption: String = "",
        moods: [String] = [],
        instruments: [String] = [],
        tags: [String] = []
    ) -> PromptTemplate? {
        let newId = DB.shared.saveTemplate(
            title: title,
            genre: genre,
            subgenre: subgenre,
            bpm: bpm,
            key: key,
            scale: scale,
            vocal: vocal,
            time_signature: time_signature,
            vocal_register: vocal_register,
            language: language,
            pro_tip: pro_tip,
            caption: caption,
            moods: moods,
            instruments: instruments,
            tags: tags
        )
        guard newId > 0 else {
            statusText = "Failed to create preset '\(title)'"
            return nil
        }

        let newTemplate = PromptTemplate(
            id: String(newId),
            title: title,
            genre: genre,
            subgenre: subgenre,
            source: "User",
            format: "adapted",
            bpm: bpm,
            key: key,
            scale: scale,
            vocal: vocal,
            time_signature: time_signature,
            vocal_register: vocal_register,
            language: language,
            moods: moods,
            instruments: instruments,
            tags: tags,
            caption: caption,
            caption_flat: caption,
            pro_tip: pro_tip,
            is_user: true
        )
        self.selectedTemplate = newTemplate
        self.statusText = "Created preset '\(title)'"
        appendLog(component: .template, level: .info, message: "Created preset '\(title)' #\(newId)", detail: "genre=\(genre) bpm=\(bpm.map { "\($0)" } ?? "—")")
        loadTemplates()
        return newTemplate
    }

    public func deleteTemplate(id: String) {
        guard let intId = Int(id) else { return }
        let title = templates.first(where: { $0.id == id })?.title ?? id
        DB.shared.deleteTemplate(id: intId)
        appendLog(component: .template, level: .info, message: "Deleted preset '\(title)' #\(id)", detail: "id=\(id)")
        if selectedTemplate?.id == id {
            selectedTemplate = nil
        }
        self.statusText = "Deleted preset '\(title)'"
        loadTemplates()
    }

    /// Build the authoritative YuE2 comma-separated style tagline from a template's
    /// structured fields (language -> genre -> vocal character -> instruments -> mood -> BPM).
    /// This uses the discrete DB columns/keywords rather than parsing the prose caption,
    /// so section headers like "Global Metadata" never leak into the output.
    public func buildYuE2Tagline(from pt: PromptTemplate) -> String {
        var bits: [String] = []

        // 1. Language
        let lang = pt.language.lowercased()
        if lang == "instrumental" {
            // handled by instruments/vocal below
        } else if !lang.isEmpty {
            bits.append(lang.capitalized)
        }

        // 2. Genre / subgenre
        var genres: [String] = []
        if !pt.genre.isEmpty { genres.append(pt.genre.lowercased()) }
        if !pt.subgenre.isEmpty && pt.subgenre.lowercased() != pt.genre.lowercased() {
            genres.append(pt.subgenre.lowercased())
        }
        if !genres.isEmpty { bits.append(genres.joined(separator: " / ")) }

        // 3. Vocal character
        if pt.vocal.lowercased() == "instrumental" {
            bits.append("instrumental, no vocals")
        } else {
            var voc: [String] = []
            if let reg = pt.vocal_register, reg != "none", !reg.isEmpty { voc.append(reg.lowercased()) }
            if !pt.vocal.isEmpty && pt.vocal.lowercased() != "unknown" { voc.append(pt.vocal.lowercased()) }
            if !voc.isEmpty { bits.append(voc.joined(separator: " ") + " vocal") }
        }

        // 4. Instruments (core palette + keyword instruments)
        if let palette = pt.core_palette, !palette.isEmpty, palette.count < 60 {
            bits.append(palette.lowercased())
        }
        let instr = pt.instruments.prefix(4).map { $0.lowercased() }
        for i in instr where !bits.joined(separator: " ").contains(i) {
            bits.append(i)
        }

        // 5. Mood / groove
        let moods = pt.moods.prefix(3).map { $0.lowercased() }
        for m in moods where !bits.joined(separator: " ").contains(m) {
            bits.append(m)
        }

        // 6. BPM & meter
        if let bpm = pt.bpm { bits.append("\(bpm) BPM") }
        if pt.time_signature != "4/4" { bits.append("\(pt.time_signature) time") }

        let line = bits.filter { !$0.isEmpty }.joined(separator: ", ")
        return line.isEmpty ? renderStyleTagline(from: pt.caption_flat.isEmpty ? pt.caption : pt.caption_flat) : line
    }

    /// Fallback tagline extractor for raw text with no structured fields (e.g. hand-typed captions).
    public func renderStyleTagline(from raw: String) -> String {
        let sectionHeaders: Set<String> = ["global metadata", "vocal details", "arrangement", "lyrics"]
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var bits = [String]()
        for ln in lines {
            let lower = ln.lowercased()
            // Skip pure section headers ("Global Metadata", "Arrangement", etc.)
            if sectionHeaders.contains(lower.replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)) { continue }
            if lower.hasSuffix(":") { continue }
            if let colon = ln.firstIndex(of: ":") {
                let val = String(ln[ln.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !val.isEmpty && val.count < 90 {
                    bits.append(val)
                }
            } else if ln.count < 90 && !ln.hasPrefix("[") {
                bits.append(ln)
            }
        }
        if !bits.isEmpty {
            return bits.prefix(6).joined(separator: ", ")
        }
        return raw
    }
    public func scheduleTemplateSearch() {
        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let trimmed = self.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if self.isSemanticSearch && trimmed.count >= 3 {
                self.performAiSearch()
            } else {
                self.filterTemplates()
            }
        }
        searchWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    public func filterTemplates() {
        var results = templates
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terms = q.split(separator: " ").map(String.init).filter { !$0.isEmpty }

        // Keyword search via FTS5 (BM25). Intersect matched prompt ids with loaded
        // templates, preserving FTS rank order. Falls back to substring scan on error.
        if !terms.isEmpty {
            if let ids = DB.shared?.searchTemplateIDs(q) {
                let byId = Dictionary(uniqueKeysWithValues: results.map { ($0.id, $0) })
                results = ids.compactMap { byId[String($0)] }
            } else {
                results = results.filter { t in
                    for term in terms where !t.searchBlob.contains(term) { return false }
                    return true
                }
            }
        }

        if selectedKey != "All" {
            results = results.filter { $0.key == selectedKey }
        }
        if selectedScale != "All" {
            results = results.filter { $0.scale?.lowercased() == selectedScale.lowercased() }
        }
        if selectedVocal != "All" {
            results = results.filter { $0.vocal.lowercased() == selectedVocal.lowercased() }
        }
        if selectedTimeSignature != "All" {
            results = results.filter { $0.time_signature == selectedTimeSignature }
        }
        if selectedVocalRegister != "All" {
            results = results.filter { ($0.vocal_register ?? "").lowercased() == selectedVocalRegister.lowercased() }
        }
        if selectedLanguage != "All" {
            results = results.filter { $0.language.lowercased() == selectedLanguage.lowercased() }
        }
        for kw in activeKeywords {
            let k = kw.lowercased()
            results = results.filter { $0.searchBlob.contains(k) }
        }

        self.filteredTemplates = results
        self.sortTemplates()
    }

    public func sortTemplates() {
        switch sortColumn {
        case "title":
            filteredTemplates.sort { sortAscending ? $0.title < $1.title : $0.title > $1.title }
        case "genre":
            filteredTemplates.sort { sortAscending ? $0.genre < $1.genre : $0.genre > $1.genre }
        case "bpm":
            filteredTemplates.sort { sortAscending ? ($0.bpm ?? 0) < ($1.bpm ?? 0) : ($0.bpm ?? 0) > ($1.bpm ?? 0) }
        default:
            break
        }
    }

    public func performAiSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            filterTemplates()
            return
        }

        self.statusText = "Searching semantic vector index..."
        let query = trimmed
        let py = self.pythonBin
        let script = self.studioScript
        let db = self.dbPath
        let allTemplates = self.templates

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: py)
            task.arguments = [script, "--db", db, "search", query, "--limit", "60"]
            var env = ProcessInfo.processInfo.environment
            env["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
            env["TQDM_DISABLE"] = "1"
            env["TRANSFORMERS_VERBOSITY"] = "error"
            env["MUSICSTUDIO_MODELS_DIR"] = ModelCatalog.modelsDirectory.path
            task.environment = env
            task.standardOutput = pipe
            task.standardError = pipe

            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()

                let rawStr = String(data: data, encoding: .utf8) ?? ""
                var parsedItems: [[String: Any]]? = nil

                if let startIdx = rawStr.firstIndex(of: "["),
                   let endIdx = rawStr.lastIndex(of: "]"),
                   startIdx <= endIdx {
                    let jsonSlice = String(rawStr[startIdx...endIdx])
                    if let d = jsonSlice.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: d) as? [[String: Any]] {
                        parsedItems = arr
                    }
                }

                if let items = parsedItems, !items.isEmpty {
                    var matches: [PromptTemplate] = []
                    for item in items {
                        let dbId = String(item["db_id"] as? Int ?? -1)
                        let slug = item["id"] as? String ?? ""
                        let itemTitle = (item["title"] as? String ?? "").lowercased()
                        if let match = allTemplates.first(where: {
                            $0.id == dbId || $0.id == slug || (!itemTitle.isEmpty && $0.title.lowercased() == itemTitle)
                        }) {
                            var m = match
                            m.similarity = item["score"] as? Double
                            matches.append(m)
                        }
                    }

                    DispatchQueue.main.async {
                        self?.filteredTemplates = matches
                        self?.statusText = "Found \(matches.count) semantic matches for '\(query)'"
                        self?.appendLog(component: .search, level: .info, message: "Semantic AI search complete", detail: "query='\(query)' matches=\(matches.count)")
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.filterTemplates()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.filterTemplates()
                }
            }
        }
    }

    public func toggleKeyword(_ term: String) {
        if activeKeywords.contains(term) {
            removeKeyword(term)
        } else {
            addKeyword(term)
        }
    }

    public func addKeyword(_ term: String) {
        if !activeKeywords.contains(term) {
            activeKeywords.append(term)
            filterTemplates()
        }
    }

    public func removeKeyword(_ term: String) {
        activeKeywords.removeAll { $0 == term }
        filterTemplates()
    }
    public func toggleInstrumental() {
        self.isInstrumental.toggle()
        if isInstrumental {
            if selectedModelFamily == .minimax_music3 {
                if !lyrics.contains("[instrumental]") {
                    lyrics = "[instrumental]"
                }
            } else {
                if !caption.contains("instrumental") {
                    caption += ", instrumental, no vocals"
                }
            }
        } else {
            if lyrics.trimmingCharacters(in: .whitespacesAndNewlines) == "[instrumental]" {
                lyrics = ""
            }
        }
    }

    public func refreshLyrics() {
        let sets = DB.shared.fetchLyrics(forPromptId: selectedTemplate?.id)
        self.availableLyricSets = sets
    }

    public func insertLyricsTag(_ tag: String) {
        if isInstrumental {
            isInstrumental = false
            lyrics = ""
        }
        if lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lyrics = tag + "\n"
        } else {
            lyrics += "\n\n" + tag + "\n"
        }
    }

    public func randomizeSeed() {
        self.seed = Int.random(in: 100_000...999_999_999)
    }

    // MARK: - Queue & Generation Execution
    private func setQueuePaused(_ paused: Bool) {
        self.isQueuePaused = paused
        UserDefaults.standard.set(paused, forKey: "queueProcessingPaused")
        recomputeQueueEta()
    }

    /// Resume the preserved queue without adding another item.
    public func resumeQueue() {
        guard queuePending > 0 else { return }
        setQueuePaused(false)
        statusText = "Resuming queue..."
        startWorkerIfNeeded()
    }

    /// Every request enters the managed queue. Green means go: when idle or paused this
    /// resumes processing after enqueue; while active it appends behind the running item.
    public func addToQueue() {
        let shouldStart = !isGenerating
        if isQueuePaused { setQueuePaused(false) }
        enqueueCurrentParams(startWorker: shouldStart)
    }

    private func enqueueCurrentParams(startWorker: Bool) {
        let runCaption = caption
        let runLyrics = lyrics
        let runDuration = duration
        let runSteps = steps
        let runGuidance = guidance
        let runFormat = outputFormat.rawValue
        let runModel = selectedModel
        // The ABC score only feeds YuE2's symbolic CoT planning; with CoT Off (or any
        // other family) the editor is hidden and the score is not sent.
        let runAbc = (!usesAbcScore || abcScoreText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? nil : abcScoreText
        let runCot = cotMode.rawValue

        var paramsObj: [String: Any] = [
            "duration": runDuration,
            "steps": runSteps,
            "guidance": runGuidance,
            "format": runFormat,
            "cot": runCot
        ]
        if let songwriterId = selectedSongwriterId, let songwriterRevision = selectedSongwriterRevision {
            paramsObj["songwriter_id"] = songwriterId
            paramsObj["songwriter_revision"] = songwriterRevision
            if let title = selectedSongwriterTitle, !title.isEmpty {
                paramsObj["songwriter_title"] = title
            }
        }
        if let abc = runAbc {
            // Durable per-job snapshot: paused queues may survive app relaunch or reboot,
            // so do not use NSTemporaryDirectory (macOS may purge it before Resume).
            let abcDir = homeDirectory.appendingPathComponent("queue-abc", isDirectory: true)
            let queuedAbc = abcDir.appendingPathComponent("score_\(UUID().uuidString).abc")
            do {
                try FileManager.default.createDirectory(at: abcDir, withIntermediateDirectories: true)
                try abc.write(to: queuedAbc, atomically: true, encoding: .utf8)
            } catch {
                statusText = "Could not queue ABC score: \(error.localizedDescription)"
                appendLog(component: .abc, level: .error, message: "ABC snapshot failed; item not queued", detail: "error=\(error)")
                return
            }
            paramsObj["abc_file"] = queuedAbc.path
        }

        let paramsJson = (try? String(data: JSONSerialization.data(withJSONObject: paramsObj), encoding: .utf8)) ?? "{}"
        let batchId = UUID().uuidString

        let count = self.batchCount
        let isLocked = self.isSeedLocked
        let lockedVal = Int(self.lockedSeedString.trimmingCharacters(in: .whitespaces))

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var position = DB.shared?.nextQueuedPosition() ?? 1
            for i in 0..<count {
                let jobSeed: Int
                let seedMode: String
                if isLocked, let locked = lockedVal {
                    jobSeed = (i == 0) ? locked : ((locked + i * 7919) % 1_000_000_000)
                    seedMode = "locked"
                } else {
                    jobSeed = Int.random(in: 100_000...999_999_999)
                    seedMode = "random"
                }

                let jobId = DB.shared?.enqueueJob(
                    batchId: batchId,
                    modelId: runModel,
                    caption: runCaption,
                    lyrics: runLyrics,
                    seed: jobSeed,
                    params: paramsJson,
                    position: position
                ) ?? -1
                position += 1

                DispatchQueue.main.async {
                    self?.appendLog(component: .queue, level: jobId > 0 ? .info : .error,
                                    message: "Queued job #\(i+1)/\(count)",
                                    detail: "mode=\(seedMode) seed=\(jobSeed) id=\(jobId)")
                }
            }
            DispatchQueue.main.async {
                self?.refreshQueueDepth()
                if startWorker { self?.startWorkerIfNeeded() }
            }
        }
    }


    public func startWorkerIfNeeded() {
        guard !isGenerating, !isQueuePaused, queuePending > 0 else { return }

        self.lastWorkerError = nil
        self.isGenerating = true
        self.statusText = "Worker active..."
        self.appendLog(component: .worker, level: .info, message: "Launching backend worker", detail: "python=\(pythonBin)")
        self.preventSleep(reason: "MusicStudio generating audio tracks")

        let outDir = UserDefaults.standard.string(forKey: "outputDirectory") ?? SetupManager.defaultOutputDirectory.path

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonBin)
        task.arguments = [studioScript, "--db", dbPath, "--output-dir", outDir, "worker"]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["MUSICSTUDIO_HOME"] = homeDirectory.path
        env["MUSICSTUDIO_DB"] = dbPath
        env["MUSICSTUDIO_OUTPUT_DIR"] = outDir
        env["MUSICSTUDIO_MODELS_DIR"] = ModelCatalog.modelsDirectory.path
        env["SONGWRITER_API_URL"] = SongwriterAPI.configuredBaseURL
        env["SONGWRITER_API_TOKEN"] = SongwriterAPI.configuredToken
        task.environment = env

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let outHandle = pipe.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty, let line = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self?.parseWorkerOutput(line)
                }
            }
        }

        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                outHandle.readabilityHandler = nil
                self.workerProcess = nil
                self.isGenerating = false
                self.allowSleep()
                DB.shared.requeueRunningJobs()
                self.loadHistory()
                self.refreshQueueDepth()
                self.liveStage = ""
                self.liveEtaString = ""
                self.liveProgressFraction = 0
                self.liveRemainingSeconds = 0
                self.generationStartTime = nil
                self.stopEtaTicker()
                self.clearEvaluationProgress()

                if self.queuePending > 0 {
                    if self.isQueuePaused {
                        self.statusText = "Queue paused"
                        self.appendLog(component: .queue, level: .info, message: "Queue paused", detail: "pending=\(self.queuePending)")
                    } else {
                        self.appendLog(component: .queue, level: .info, message: "\(self.queuePending) job(s) pending — restarting worker", detail: "pending=\(self.queuePending)")
                        self.startWorkerIfNeeded()
                    }
                } else if self.lastWorkerError != nil || self.queueJobs.contains(where: { $0.status == "error" }) {
                    self.statusText = "Queue finished with errors — open Queue for details"
                } else {
                    self.setQueuePaused(false)
                    self.statusText = "Ready"
                }
                self.recomputeQueueEta()
            }
        }

        self.workerProcess = task
        do {
            try task.run()
        } catch {
            self.workerProcess = nil
            self.isGenerating = false
            self.setQueuePaused(true)
            self.refreshQueueDepth()
            self.statusText = "Worker failed to launch — queue paused: \(error.localizedDescription)"
            self.appendLog(component: .worker, level: .error, message: "Worker spawn failed; queue preserved", detail: "error=\(error)")
            self.allowSleep()
        }
    }

    private func clearEvaluationProgress() {
        evaluatingGenerationId = nil
        evalInstallStage = ""
        evalInstallFraction = 0.0
    }

    private func parseWorkerOutput(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        for l in lines where !l.trimmingCharacters(in: .whitespaces).isEmpty {
            if let data = l.data(using: .utf8),
               let msg = try? JSONDecoder().decode(EventMessage.self, from: data) {

                let comp = msg.component.flatMap { LogComponent.fromString($0) } ?? .worker
                let lvl = msg.level.flatMap { LogLevel.fromString($0) } ?? .info

                if msg.event == "log", let txt = msg.message {
                    self.appendLog(component: comp, level: lvl, message: txt)
                    if !txt.starts(with: "[AutoRegressive]") && !txt.starts(with: "[FlowMatching]") && !txt.starts(with: "[nar]") {
                        statusText = txt
                    }
                } else if msg.event == "start" {
                    liveStage = "Initializing"
                    currentArFrame = 0
                    currentFlowChunk = 0
                    currentNarStep = 0
                    let runningDuration = msg.duration ?? duration
                    let runningModel = msg.model ?? selectedModel
                    totalArFrames = Int(runningDuration * 25.0)
                    self.generationStartTime = Date()
                    self.estimatedSongSeconds = self.estimateSongSeconds(modelId: runningModel, audioDuration: runningDuration)
                    self.isEtaOverrun = false
                    self.liveProgressFraction = 0
                    self.liveRemainingSeconds = self.estimatedSongSeconds
                    self.refreshQueueDepth()
                    self.startEtaTicker()
                    self.recomputeQueueEta()
                    self.appendLog(component: .worker, level: .info, message: "Started generation for song \(msg.index ?? 1)/\(msg.total ?? 1)", detail: "steps=\(msg.steps ?? steps) seed=\(msg.seed ?? 0) model=\(runningModel)")
                } else if msg.event == "progress" {
                    if msg.stage == "ar" {
                        liveStage = "AR"
                        currentArFrame = msg.frame ?? currentArFrame
                        totalArFrames = msg.max_frames ?? totalArFrames
                        currentArFps = msg.fps ?? currentArFps
                        liveEtaString = String(format: "%.1f f/s", currentArFps)
                        // Stage telemetry is informational; the monotonic ticker owns ETA/progress.
                        let detailStr = "\(currentArFrame)/\(totalArFrames) frames · \(String(format: "%.1f", currentArFps)) f/s"
                        self.appendLog(component: .ar, level: .debug, message: "Autoregressive synthesis frame \(currentArFrame)/\(totalArFrames)", detail: detailStr)
                    } else if msg.stage == "dit" || msg.stage == "flow" {
                        liveStage = "Flow"
                        currentFlowChunk = msg.chunk ?? currentFlowChunk
                        let flowStep = msg.step ?? 0
                        let flowSteps = msg.steps ?? 30
                        liveEtaString = "Chunk \(currentFlowChunk)"
                        // Stage telemetry is informational; the monotonic ticker owns ETA/progress.
                        self.appendLog(component: .flow, level: .debug, message: "Flow matching chunk \(currentFlowChunk)", detail: "step=\(flowStep)/\(flowSteps)")
                    } else if msg.stage == "plan" {
                        liveStage = "Plan"
                        statusText = "Composing symbolic ABC score..."
                        self.appendLog(component: .cot, level: .info, message: msg.message ?? "Generating symbolic ABC plan", detail: "")
                    } else if msg.stage == "semantic" {
                        liveStage = "Semantic"
                        statusText = "Generating acoustic tokens..."
                        self.appendLog(component: .ar, level: .debug, message: msg.message ?? "Generating acoustic semantic tokens", detail: "")
                    } else if msg.stage == "nar" {
                        liveStage = "NAR"
                        currentNarStep = msg.step ?? currentNarStep
                        totalNarSteps = msg.total_steps ?? totalNarSteps
                        liveEtaString = "Step \(currentNarStep)/\(totalNarSteps)"
                        // Stage telemetry is informational; the monotonic ticker owns ETA/progress.
                        self.appendLog(component: .nar, level: .debug, message: msg.message ?? "Midpoint ODE flow step \(currentNarStep)/\(totalNarSteps)", detail: "step=\(currentNarStep)/\(totalNarSteps)")
                    } else if msg.stage == "vae" {
                        liveStage = "VAE"
                        statusText = "Decoding waveform audio..."
                        self.appendLog(component: .vae, level: .info, message: msg.message ?? "Decoding latents to final waveform", detail: "")
                    }
                } else if msg.event == "eval_install_start" || msg.event == "eval_install_progress" {
                    evaluatingGenerationId = msg.generation_id
                    evalInstallStage = msg.stage ?? "Installing"
                    evalInstallFraction = msg.fraction ?? evalInstallFraction
                    statusText = "SongBench: \(evalInstallStage) \(Int(evalInstallFraction * 100))%"
                    self.loadHistory()
                    self.appendLog(component: .eval, level: lvl, message: "SongBench \(evalInstallStage)", detail: "progress=\(Int(evalInstallFraction * 100))%")
                } else if msg.event == "eval_start" {
                    evaluatingGenerationId = msg.generation_id
                    evalInstallStage = ""
                    evalInstallFraction = 0.0
                    statusText = "Scoring completed track…"
                    self.loadHistory()
                    self.appendLog(component: .eval, level: .info, message: "SongBench scoring started", detail: "generation=\(msg.generation_id ?? 0)")
                } else if msg.event == "eval_complete" {
                    clearEvaluationProgress()
                    self.loadHistory()
                    statusText = "SongBench evaluation complete"
                    self.appendLog(component: .eval, level: .info, message: "SongBench evaluation completed", detail: "generation=\(msg.generation_id ?? 0)")
                } else if msg.event == "eval_failed" {
                    clearEvaluationProgress()
                    self.loadHistory()
                    let warning = msg.error ?? msg.message ?? "SongBench evaluation failed"
                    statusText = "Evaluation failed — track preserved"
                    self.appendLog(component: .eval, level: .warn, message: warning, detail: "generation=\(msg.generation_id ?? 0)")
                } else if msg.event == "complete", let item = msg.item {
                    DB.shared.invalidateCalibrationCache()
                    self.loadHistory()
                    self.refreshQueueDepth()
                    self.generationStartTime = nil
                    self.liveRemainingSeconds = 0
                    self.liveProgressFraction = 0
                    self.isEtaOverrun = false
                    self.stopEtaTicker()
                    self.recomputeQueueEta()
                    self.appendLog(component: .worker, level: .info, message: "Generation completed: \(URL(fileURLWithPath: item.output_file).lastPathComponent)", detail: "size=\(String(format: "%.2f", item.size_mb))MB elapsed=\(String(format: "%.1f", item.elapsed_sec))s")
                    self.statusText = "Finished: \(URL(fileURLWithPath: item.output_file).lastPathComponent)"
                    if self.selectedTab != .studio {
                        self.hasUnviewedGenerations = true
                    }

                    // Load generated ABC sidecar ONLY if the user has not supplied their own score
                    if let sidecar = item.sidecar_file, FileManager.default.fileExists(atPath: sidecar),
                       let abcContent = try? String(contentsOfFile: sidecar, encoding: .utf8) {
                        if self.abcScoreIsUserEdited {
                            self.appendLog(component: .abc, level: .info, message: "Kept your edited ABC score (engine used it as the plan)", detail: "user_score_preserved")
                        } else {
                            self.isLoadingEngineScore = true
                            self.abcScoreText = abcContent
                            self.isLoadingEngineScore = false
                            self.appendLog(component: .abc, level: .info, message: "Loaded generated ABC score into score editor", detail: "\(abcContent.count) chars")
                        }
                    }

                    // Autoplay if single job finished
                    if self.queuePending == 0 {
                        self.playAudio(path: item.output_file)
                    }
                } else if msg.event == "error", let err = msg.message {
                    self.lastWorkerError = err
                    self.appendLog(component: .worker, level: .error, message: err, detail: "")
                    self.statusText = "Error: \(err)"
                    self.refreshQueueDepth()
                }
            } else {
                self.appendLog(l, component: .worker, level: .info)
            }
        }
    }
    /// Pause processing without losing work. The running song is interrupted and returned
    /// to the front of the queue by the worker termination handler, then Resume restarts it.
    public func pauseQueue() {
        setQueuePaused(true)
        statusText = "Pausing queue..."
        if let proc = workerProcess, proc.isRunning {
            proc.terminate()
        } else {
            DB.shared.requeueRunningJobs()
            refreshQueueDepth()
            statusText = "Queue paused"
        }
    }

    /// Explicit destructive operation: stop processing and remove every pending item.
    public func clearQueue() {
        DB.shared.clearQueue()
        setQueuePaused(false)
        if let proc = workerProcess, proc.isRunning { proc.terminate() }
        refreshQueueDepth()
        statusText = "Queue cleared"
    }

    public func cancelJob(id: Int) {
        DB.shared.cancelJob(id: id)
        refreshQueueDepth()
    }

    /// Remove only this item. Removing the running item kills its worker; remaining queued
    /// items continue automatically. Removing a queued item does not affect processing.
    public func stopJob(id: Int, isRunning: Bool) {
        DB.shared.cancelJob(id: id)
        if isRunning {
            setQueuePaused(false)
            if let proc = workerProcess, proc.isRunning { proc.terminate() }
            liveStage = ""
            liveEtaString = ""
            liveProgressFraction = 0
            liveRemainingSeconds = 0
            generationStartTime = nil
            stopEtaTicker()
        }
        refreshQueueDepth()
    }

    public func dismissFailedJobs() {
        DB.shared.dismissFailedJobs()
        lastWorkerError = nil
        refreshQueueDepth()
        if queuePending == 0 { statusText = "Ready" }
    }

    public func refreshQueueDepth() {
        self.queuePending = DB.shared.pendingJobCount()
        self.queueJobs = DB.shared.fetchQueueJobs()
        self.recomputeQueueEta()
    }

    public func loadHistory() {
        self.history = DB.shared.fetchGenerations()
    }

    public func evaluateGeneration(_ item: GenerationHistoryItem) {
        guard evaluationProcess == nil else { return }
        guard let generationId = Int(item.id), FileManager.default.fileExists(atPath: item.output_file) else {
            appendLog(component: .eval, level: .warn, message: "Generation audio is unavailable", detail: item.output_file)
            return
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: pythonBin)
        process.arguments = [studioScript, "--db", dbPath, "songbench", item.output_file, "--generation-id", String(generationId)]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["MUSICSTUDIO_HOME"] = homeDirectory.path
        environment["MUSICSTUDIO_MODELS_DIR"] = ModelCatalog.modelsDirectory.path
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] output in
            let data = output.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { self?.parseWorkerOutput(text) }
            }
        }
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                handle.readabilityHandler = nil
                self?.evaluationProcess = nil
                self?.clearEvaluationProgress()
                self?.loadHistory()
            }
        }
        evaluationProcess = process
        evaluatingGenerationId = generationId
        do {
            try process.run()
        } catch {
            evaluationProcess = nil
            clearEvaluationProgress()
            appendLog(component: .eval, level: .warn, message: "Could not start SongBench evaluation", detail: error.localizedDescription)
        }
    }


    /// Repopulate the entire Create tab from a rendered track's stored metadata + sidecar files.
    /// Selecting a song in the media player restores its caption, lyrics, seed, model, params, and ABC score.
    public func loadFromHistory(_ item: GenerationHistoryItem) {
        // Model family + selection
        if !item.model.isEmpty, ModelCatalog.model(withId: item.model) != nil {
            selectModel(id: item.model)
        } else if item.model.lowercased().contains("yue2") {
            selectedModelFamily = .yue2
        } else {
            selectedModelFamily = .minimax_music3
        }

        // Caption + lyrics from the recorded generation
        if !item.caption.isEmpty { self.caption = item.caption }
        self.lyrics = item.lyrics
        self.isInstrumental = item.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "[instrumental]"
            || item.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // Params
        self.duration = item.duration
        self.steps = item.steps
        self.guidance = item.guidance

        // Seed (lock to reproduce)
        self.lockedSeedString = String(item.seed)
        self.isSeedLocked = true

        // Output format
        if let fmt = AudioFormat(rawValue: item.format) { self.outputFormat = fmt }

        // ABC sidecar score (YuE2)
        if let sidecar = item.sidecar_file, FileManager.default.fileExists(atPath: sidecar),
           let score = try? String(contentsOfFile: sidecar, encoding: .utf8) {
            self.isLoadingEngineScore = true
            self.abcScoreText = score
            self.isLoadingEngineScore = false
        }

        self.selectedTab = .create
        self.appendLog(component: .ui, level: .info, message: "Loaded settings from \(URL(fileURLWithPath: item.output_file).lastPathComponent)", detail: "seed=\(item.seed) model=\(item.model)")
    }

    public func deleteGeneration(_ item: GenerationHistoryItem) {
        if currentPlayingFile == item.output_file {
            stopAudio()
        }
        DB.shared.deleteGeneration(id: item.id)
        if FileManager.default.fileExists(atPath: item.output_file) {
            try? FileManager.default.removeItem(atPath: item.output_file)
        }
        if let sidecar = item.sidecar_file, FileManager.default.fileExists(atPath: sidecar) {
            try? FileManager.default.removeItem(atPath: sidecar)
        }
        loadHistory()
    }

    // MARK: - Audio Playback
    public func playAudio(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        stopAudio()
        do {
            try audioEngine.load(path: path)
            self.isPlayingAudio = true
            self.currentPlayingFile = path
            self.audioDuration = audioEngine.durationSeconds
            startPlaybackTimer()
        } catch {
            self.statusText = "Playback error: \(error.localizedDescription)"
        }
    }

    public func togglePlayPause() {
        guard currentPlayingFile != nil else {
            if let first = history.first {
                playAudio(path: first.output_file)
            }
            return
        }
        if audioEngine.isPlaying {
            audioEngine.pause()
            self.isPlayingAudio = false
        } else {
            audioEngine.resume()
            self.isPlayingAudio = true
        }
    }

    public func stopAudio() {
        audioEngine.stop()
        self.isPlayingAudio = false
        self.currentPlayingFile = nil
        self.audioProgress = 0.0
        playbackTimer?.invalidate()
        playbackTimer = nil
    }

    // MARK: - Studio Inspector
    /// Select a track for the Studio inspector and kick off its spectrogram render.
    public func selectTrack(_ item: GenerationHistoryItem) {
        self.selectedTrack = item
        requestSpectrogram(for: item.output_file)
        // With a live AU loaded, preview the track you selected so what you hear
        // is exactly what "Save Audio…" writes. The AU node stays in the graph.
        if pluginLiveActive, currentPlayingFile != item.output_file {
            playAudio(path: item.output_file)
        }
    }

    /// Lazily render + cache a mel-spectrogram PNG for a file via the Python engine.
    /// Idempotent: skips if cached or already in flight.
    public func requestSpectrogram(for path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        if spectrogramPaths[path] != nil || spectrogramInFlight.contains(path) { return }
        spectrogramInFlight.insert(path)
        let py = pythonBin
        let script = studioScript
        let home = homeDirectory.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: py)
            task.arguments = [script, "spectrogram", path]
            task.standardOutput = pipe
            task.standardError = Pipe()
            var env = ProcessInfo.processInfo.environment
            env["MUSICSTUDIO_HOME"] = home
            task.environment = env
            var pngPath: String? = nil
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let p = obj["path"] as? String {
                    pngPath = p
                }
            } catch {
                pngPath = nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.spectrogramInFlight.remove(path)
                if let pngPath { self.spectrogramPaths[path] = pngPath }
            }
        }
    }

    // MARK: - VST / AU Plugin
    /// Open a file picker, let the user choose a .vst3/.component, and load its parameters.
    public func chooseAndLoadPlugin() {
        let panel = NSOpenPanel()
        panel.title = "Choose a VST3 or Audio Unit plugin"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true   // .vst3/.component are bundle directories
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3")
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPlugin(path: url.path)
    }

    /// Load a plugin. For an Audio Unit, labels/units come from its VST3 build when one is
    /// installed (the AU itself only reports raw 0..1 values); audio still runs live via the AU.
    public func loadPlugin(path: String) {
        clearPlugin()
        pluginBusy = true
        pluginStatus = "Loading \(URL(fileURLWithPath: path).lastPathComponent)…"
        let isAU = AudioUnitHost.isAudioUnit(path: path)
        let renderPath = isAU ? (AudioUnitHost.sibling(of: path, ext: "vst3") ?? path) : path
        let py = pythonBin, script = studioScript, home = homeDirectory.path
        // --list-params requires an input arg; use the selected track or any placeholder.
        let inputArg = selectedTrack?.output_file ?? "/dev/null"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process(); let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: py)
            task.arguments = [script, "effect", inputArg, "--plugin", renderPath, "--list-params"]
            task.standardOutput = pipe; task.standardError = Pipe()
            var env = ProcessInfo.processInfo.environment
            env["MUSICSTUDIO_HOME"] = home; task.environment = env
            var plugin: VSTPlugin? = nil
            var errMsg: String? = nil
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                if let p = VSTPlugin.parse(data, path: path, renderPath: renderPath) {
                    plugin = p
                } else if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let e = obj["error"] as? String {
                    errMsg = e
                } else {
                    errMsg = "Could not read plugin parameters."
                }
            } catch {
                errMsg = error.localizedDescription
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pluginBusy = false
                guard let plugin else {
                    self.pluginStatus = errMsg ?? "Failed to load plugin."
                    return
                }
                self.loadedPlugin = plugin
                self.pluginParameters = plugin.parameters
                if !plugin.isEffect {
                    self.pluginEngineMode = .none
                    self.pluginStatus = "\(plugin.name) is an instrument, not an effect."
                } else if isAU {
                    self.pluginEngineMode = .realtimeAU
                    self.activateLiveAU(path: path, name: plugin.name)
                } else {
                    self.pluginEngineMode = .offline
                    self.pluginStatus = "Loaded \(plugin.name). Preview updates shortly after you change a value."
                }
            }
        }
    }

    /// VST3 preview: render to a temp WAV and play it (no files left in the output folder).
    public func applyPluginToSelectedTrack() {
        guard let plugin = loadedPlugin else { return }
        let resumeAt = audioProgress
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicstudio_preview_\(UUID().uuidString).wav")
        pluginStatus = "Updating preview through \(plugin.name)…"
        renderVST(to: tmp) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                if let old = self.vstPreviewFile, old != url { try? FileManager.default.removeItem(at: old) }
                self.vstPreviewFile = url
                self.playAudio(path: url.path)
                if resumeAt > 0 { self.audioEngine.seek(to: resumeAt) }
                self.pluginStatus = "Previewing \(plugin.name). Change a value to update."
            case .failure(let err):
                self.pluginStatus = err.localizedDescription
            }
        }
    }

    /// VST3 save: ask for name + format, render, then encode with the source track's tags.
    public func saveVSTToFile() {
        guard let track = selectedTrack, let plugin = loadedPlugin else { return }
        let src = URL(fileURLWithPath: track.output_file)
        let baseName = src.deletingPathExtension().lastPathComponent
            + "_" + plugin.name.replacingOccurrences(of: " ", with: "")
        let initial = AudioFormat(rawValue: src.pathExtension.lowercased()) ?? outputFormat
        let panel = NSSavePanel()
        panel.title = "Save audio with \(plugin.name) applied"
        panel.directoryURL = src.deletingLastPathComponent()
        let picker = SaveFormatPicker(panel: panel, baseName: baseName, initial: initial)
        panel.accessoryView = picker.view
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let format = picker.selected
        let out = chosen.deletingPathExtension().appendingPathExtension(format.rawValue)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicstudio_fx_\(UUID().uuidString).wav")
        pluginStatus = "Saving \(out.lastPathComponent)…"
        renderVST(to: tmp) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.pluginBusy = true
                self.encodeRender(tmpWav: url, to: out, format: format, tagsFrom: src)
            case .failure(let err):
                self.pluginStatus = "Save failed: \(err.localizedDescription)"
            }
        }
    }

    /// Render the selected track through the loaded VST3 (pedalboard) at the current values.
    private func renderVST(to outURL: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let plugin = loadedPlugin, let track = selectedTrack else { return }
        pluginBusy = true
        let py = pythonBin, script = studioScript, home = homeDirectory.path
        var args = [script, "effect", track.output_file, "--plugin", plugin.renderPath, "--output", outURL.path]
        // Send every control the user moved, as normalized positions (same scale as the AU).
        let defaults = Dictionary(uniqueKeysWithValues: plugin.parameters.map { ($0.name, $0.raw) })
        for p in pluginParameters where abs(p.raw - (defaults[p.name] ?? -1)) > 1e-6 {
            args += ["--raw", "\(p.name)=\(p.raw)"]
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process(); let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: py)
            task.arguments = args
            task.standardOutput = pipe; task.standardError = Pipe()
            var env = ProcessInfo.processInfo.environment
            env["MUSICSTUDIO_HOME"] = home; task.environment = env
            var ok = false; var errMsg: String? = nil
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                // Engine prints log lines then a final JSON object; take the last JSON line.
                let lines = String(data: data, encoding: .utf8)?
                    .split(separator: "\n").map(String.init) ?? []
                for line in lines.reversed() {
                    if let d = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        if obj["status"] as? String == "ok" { ok = true; break }
                        if let e = obj["error"] as? String { errMsg = e; break }
                    }
                }
            } catch { errMsg = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pluginBusy = false
                if ok {
                    completion(.success(outURL))
                } else {
                    completion(.failure(NSError(domain: "VST3", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: errMsg ?? "Processing failed."])))
                }
            }
        }
    }

    // MARK: - Live AU hosting / parameter changes

    /// Insert a .component Audio Unit as a live node on the playback graph and start
    /// playing the selected track through it (real-time preview).
    private func activateLiveAU(path: String, name: String) {
        guard let desc = AudioUnitHost.description(forPath: path) else {
            fallBackToOffline(name: name, reason: "couldn't read its Audio Unit info")
            return
        }
        liveAUDescription = desc
        // Ensure the track is playing so the inserted node is immediately audible.
        if let track = selectedTrack, currentPlayingFile != track.output_file {
            playAudio(path: track.output_file)
        }
        pluginStatus = "Starting live preview through \(name)…"
        audioEngine.insertAudioUnit(description: desc) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.pluginLiveActive = true
                self.bindLiveAUParameters()
                self.audioEngine.observeEffectParameters { [weak self] address, value in
                    self?.liveParameterDidChange(address: address, value: value)
                }
                // Open the plugin's own interface; its knobs drive this same live node, so
                // the audio still runs through the app and Save captures the result.
                if let au = self.audioEngine.currentEffect {
                    self.auWindow.show(for: au, title: name, alertIfNoEditor: false)
                }
                self.pluginStatus = "Live: \(name). Use its window or the controls here; changes are heard instantly."
            case .failure(let err):
                self.liveAUDescription = nil
                self.fallBackToOffline(name: name, reason: err.localizedDescription)
            }
        }
    }

    /// Attach each control row to the live AU parameter it drives. Rows are matched by name
    /// to the plugin's VST3 descriptions; AU-only parameters get raw rows.
    private func bindLiveAUParameters() {
        let au = audioEngine.effectParameters()
        guard !au.isEmpty else { return }
        var used = Set<UInt64>()
        var match: [Int: Int] = [:]   // row index -> AU index
        let rowKeys = pluginParameters.map { VSTParameter.matchKey($0.name) }
        let auKeys = au.map { (VSTParameter.matchKey($0.name), VSTParameter.matchKey($0.identifier)) }
        // Pass 1: exact name ("delay_ms" ~ "Delay_Ms"). Pass 2: AU name starts the VST3 name
        // ("amount_wider" ~ "Amount", "lowbypass_frequency" ~ "LowBypass").
        for exact in [true, false] {
            for (i, key) in rowKeys.enumerated() where match[i] == nil {
                if let j = au.indices.first(where: { j in
                    guard !used.contains(au[j].address) else { return false }
                    let (n, id) = auKeys[j]
                    if exact { return n == key || id == key }
                    return n.count >= 3 && key.hasPrefix(n)
                }) {
                    match[i] = j
                    used.insert(au[j].address)
                }
            }
        }
        var rows: [VSTParameter] = []
        for (i, var row) in pluginParameters.enumerated() {
            guard let j = match[i] else { continue }   // VST3-only control (e.g. host bypass)
            let ap = au[j]
            row.auAddress = ap.address
            row.auMin = ap.min; row.auMax = ap.max
            row.label = VSTParameter.prettyName(ap.name)   // "LowCut" -> "Low Cut"
            row.raw = row.normalized(fromAU: ap.value)
            rows.append(row)
        }
        for ap in au where !used.contains(ap.address) {
            var row = VSTParameter(name: ap.name, label: VSTParameter.prettyName(ap.name), raw: 0,
                                   isHidden: VSTParameter.looksHidden(ap.name), auAddress: ap.address,
                                   auMin: ap.min, auMax: ap.max)
            row.raw = row.normalized(fromAU: ap.value)
            rows.append(row)
        }
        pluginParameters = rows
    }

    /// A parameter changed inside the plugin (its own window); mirror it in our controls.
    private func liveParameterDidChange(address: UInt64, value: Double) {
        guard let i = pluginParameters.firstIndex(where: { $0.auAddress == address }) else { return }
        let norm = pluginParameters[i].normalized(fromAU: value)
        if abs(pluginParameters[i].raw - norm) > 1e-6 { pluginParameters[i].raw = norm }
    }

    /// Live hosting isn't possible; keep the plugin usable through offline re-render
    /// (pedalboard can load the same plugin) so preview and Save still work.
    private func fallBackToOffline(name: String, reason: String) {
        pluginLiveActive = false
        pluginEngineMode = .offline
        pluginStatus = "Couldn't run \(name) live (\(reason)). Using offline preview instead."
    }

    /// A control in the inspector changed. Live AU: set that parameter now. Offline: re-render.
    public func pluginParameterChanged(_ name: String) {
        switch pluginEngineMode {
        case .realtimeAU:
            guard let p = pluginParameters.first(where: { $0.name == name }),
                  let addr = p.auAddress else { return }
            audioEngine.setEffectParameter(address: addr, value: p.auValue)
        case .offline:
            scheduleVSTRerender()
        case .none:
            break
        }
    }

    /// Open (or bring forward) the AU's own interface.
    public func showPluginWindow() {
        guard let au = audioEngine.currentEffect, let plugin = loadedPlugin else { return }
        auWindow.show(for: au, title: plugin.name, alertIfNoEditor: true)
    }

    /// Debounced background re-render for VST3 (near-real-time preview).
    private func scheduleVSTRerender() {
        vstRerenderWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applyPluginToSelectedTrack()
        }
        vstRerenderWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Tear down any loaded plugin and return to dry playback.
    public func clearPlugin() {
        vstRerenderWork?.cancel()
        audioEngine.removeEffect()
        auWindow.close()
        loadedPlugin = nil
        pluginParameters = []
        pluginEngineMode = .none
        pluginLiveActive = false
        liveAUDescription = nil
        if let tmp = vstPreviewFile { try? FileManager.default.removeItem(at: tmp) }
        vstPreviewFile = nil
        pluginStatus = ""
    }

    /// Save the selected track processed through the live AU at the current control values.
    /// The save dialog offers WAV/MP3/M4A/FLAC; non-WAV formats are encoded by the engine's
    /// converter, which also carries over the original track's tags.
    public func saveAUToFile() {
        guard let desc = liveAUDescription, let track = selectedTrack,
              let plugin = loadedPlugin else { return }
        let src = URL(fileURLWithPath: track.output_file)
        let baseName = src.deletingPathExtension().lastPathComponent
            + "_" + plugin.name.replacingOccurrences(of: " ", with: "")

        // Default to the source track's format so a saved MP3 stays an MP3.
        let initial = AudioFormat(rawValue: src.pathExtension.lowercased()) ?? outputFormat
        let panel = NSSavePanel()
        panel.title = "Save audio with \(plugin.name) applied"
        panel.directoryURL = src.deletingLastPathComponent()
        let picker = SaveFormatPicker(panel: panel, baseName: baseName, initial: initial)
        panel.accessoryView = picker.view
        guard panel.runModal() == .OK, let chosen = panel.url else { return }
        let format = picker.selected
        let out = chosen.deletingPathExtension().appendingPathExtension(format.rawValue)

        // Read from the live node so edits made in the plugin's own window are captured too.
        var params: [UInt64: Double] = [:]
        for ap in audioEngine.effectParameters() {
            params[ap.address] = ap.value
        }
        let tmpWav = FileManager.default.temporaryDirectory
            .appendingPathComponent("musicstudio_fx_\(UUID().uuidString).wav")
        pluginBusy = true
        pluginStatus = "Saving \(out.lastPathComponent)…"
        AudioEngine.renderOffline(inputPath: src.path, outputPath: tmpWav.path,
                                  description: desc, parameters: params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                self.pluginBusy = false
                self.pluginStatus = "Save failed: \(err.localizedDescription)"
                try? FileManager.default.removeItem(at: tmpWav)
            case .success:
                self.encodeRender(tmpWav: tmpWav, to: out, format: format, tagsFrom: src)
            }
        }
    }

    /// Encode a rendered temp WAV into the chosen format (tags copied from the source),
    /// then reveal the file. Runs the engine's `convert` off the main thread.
    private func encodeRender(tmpWav: URL, to out: URL, format: AudioFormat, tagsFrom src: URL) {
        let py = pythonBin, script = studioScript, home = homeDirectory.path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: py)
            task.arguments = [script, "convert", tmpWav.path, format.rawValue,
                              "--output", out.path, "--tags-from", src.path]
            task.standardOutput = pipe
            task.standardError = Pipe()
            var env = ProcessInfo.processInfo.environment
            env["MUSICSTUDIO_HOME"] = home
            task.environment = env
            var errMsg: String? = nil
            do {
                try task.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let lines = String(data: data, encoding: .utf8)?
                    .split(separator: "\n").map(String.init) ?? []
                for line in lines.reversed() {
                    if let d = line.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       obj["event"] == nil {
                        errMsg = obj["error"] as? String
                        break
                    }
                }
                if task.terminationStatus != 0 && errMsg == nil { errMsg = "Encoding failed." }
            } catch {
                errMsg = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: tmpWav)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pluginBusy = false
                if let errMsg {
                    self.pluginStatus = "Save failed: \(errMsg)"
                } else {
                    self.pluginOutputFile = out.path
                    self.pluginStatus = "Saved \(out.lastPathComponent)"
                    NSWorkspace.shared.activateFileViewerSelecting([out])
                }
            }
        }
    }

    public func beginSeek() {
        isSeeking = true
    }

    public func endSeek(to time: Double) {
        audioEngine.seek(to: time)
        isSeeking = false
    }

    private func startPlaybackTimer() {
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.currentPlayingFile != nil else { return }
                if !self.isSeeking {
                    self.audioProgress = self.audioEngine.currentTime
                    if !self.audioEngine.isPlaying
                        && self.audioEngine.currentTime >= self.audioEngine.durationSeconds - 0.2 {
                        self.isPlayingAudio = false
                    }
                }
            }
        }
    }

    // MARK: - Sleep Management (IOKit Power Management)
    private func preventSleep(reason: String) {
        if sleepAssertionId == 0 {
            let res = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &sleepAssertionId
            )
            if res == kIOReturnSuccess {
                appendLog(component: .power, level: .info, message: "System sleep prevented while generating", detail: "assertion_id=\(sleepAssertionId) reason='\(reason)'")
            }
        }
    }

    private func allowSleep() {
        if sleepAssertionId != 0 {
            IOPMAssertionRelease(sleepAssertionId)
            appendLog(component: .power, level: .info, message: "System sleep re-enabled", detail: "released_assertion_id=\(sleepAssertionId)")
            sleepAssertionId = 0
        }
    }
}
