import Foundation
import SwiftUI
import AppKit

@MainActor
public final class SetupManager: ObservableObject {
    public static let shared = SetupManager()

    public enum State: Equatable {
        case checking
        case needsSetup
        case installing
        case ready
        case failed(String)
    }

    @Published public var state: State = .checking
    @Published public var statusMessage: String = "Checking system environment..."
    @Published public var progress: Double = 0.0
    @Published public var outputDirectory: String
    @Published public var modelsDirectory: String
    @Published public var hfToken: String
    @Published public var selectedModelId: String

    public let profile: SystemProfile = .current

    public static var defaultHomeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".MusicStudio", isDirectory: true)
    }

    public static var defaultOutputDirectory: URL {
        defaultHomeDirectory.appendingPathComponent("output", isDirectory: true)
    }

    public static var defaultModelsDirectory: URL {
        defaultHomeDirectory.appendingPathComponent("models", isDirectory: true)
    }

    public static var pythonBinURL: URL {
        defaultHomeDirectory.appendingPathComponent("venv/bin/python3")
    }

    public init() {
        let savedOut = UserDefaults.standard.string(forKey: "outputDirectory")
        self.outputDirectory = (savedOut?.isEmpty ?? true) ? Self.defaultOutputDirectory.path : savedOut!

        let savedModels = UserDefaults.standard.string(forKey: "modelsDirectory")
        self.modelsDirectory = (savedModels?.isEmpty ?? true) ? Self.defaultModelsDirectory.path : savedModels!

        self.hfToken = UserDefaults.standard.string(forKey: "hfToken") ?? ""

        let recMiniMax = ModelCatalog.recommendedModel(for: .minimax_music3, profile: profile)?.id
        self.selectedModelId = recMiniMax ?? "minimax_music3:MiniMax-Music3-mxfp8"

        self.checkStatus()
    }

    public func checkStatus() {
        let fm = FileManager.default
        let pythonPath = Self.pythonBinURL.path
        let dbPath = Self.defaultHomeDirectory.appendingPathComponent("studio.db").path

        let pythonExists = fm.fileExists(atPath: pythonPath)
        let dbExists = fm.fileExists(atPath: dbPath)

        if pythonExists && dbExists {
            self.state = .ready
            self.statusMessage = "Environment ready."
        } else {
            self.state = .needsSetup
            self.statusMessage = "First-time setup required."
        }
    }

    public func selectOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Output Folder"
        if panel.runModal() == .OK, let url = panel.url {
            self.outputDirectory = url.path
            UserDefaults.standard.set(url.path, forKey: "outputDirectory")
        }
    }

    public func selectModelsDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Models Folder"
        if panel.runModal() == .OK, let url = panel.url {
            self.modelsDirectory = url.path
            UserDefaults.standard.set(url.path, forKey: "modelsDirectory")
        }
    }

    public func savePreferences() {
        UserDefaults.standard.set(outputDirectory, forKey: "outputDirectory")
        UserDefaults.standard.set(modelsDirectory, forKey: "modelsDirectory")
        if !hfToken.trimmingCharacters(in: .whitespaces).isEmpty {
            UserDefaults.standard.set(hfToken.trimmingCharacters(in: .whitespaces), forKey: "hfToken")
        } else {
            UserDefaults.standard.removeObject(forKey: "hfToken")
        }
    }

    public func runBootstrap() async {
        self.state = .installing
        self.savePreferences()
        self.progress = 0.05
        self.statusMessage = "Creating directory structure..."

        let fm = FileManager.default
        let home = Self.defaultHomeDirectory
        let binDir = home.appendingPathComponent("bin")
        let enginesDir = home.appendingPathComponent("engines/yue2")
        let modelsDir = URL(fileURLWithPath: modelsDirectory)
        let outDir = URL(fileURLWithPath: outputDirectory)

        do {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: enginesDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: modelsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        } catch {
            self.state = .failed("Failed creating directories: \(error.localizedDescription)")
            return
        }

        // Copy seed database and embedding vectors
        self.progress = 0.15
        self.statusMessage = "Copying catalog database & vector search index..."
        let dbDest = home.appendingPathComponent("studio.db")
        let embDest = home.appendingPathComponent("embeddings.npy")
        let embIdsDest = home.appendingPathComponent("embedding_ids.npy")

        let bundleResourceURL = Bundle.main.resourceURL ?? URL(fileURLWithPath: "Resources")
        let seedDbURL = bundleResourceURL.appendingPathComponent("seed_studio.db")
        let embURL = bundleResourceURL.appendingPathComponent("embeddings.npy")
        let embIdsURL = bundleResourceURL.appendingPathComponent("embedding_ids.npy")

        if !fm.fileExists(atPath: dbDest.path) {
            guard fm.fileExists(atPath: seedDbURL.path) else {
                self.state = .failed("Bundled resource seed_studio.db not found")
                return
            }
            do { try fm.copyItem(at: seedDbURL, to: dbDest) }
            catch { self.state = .failed("Failed copying seed database: \(error.localizedDescription)"); return }
        }

        if !fm.fileExists(atPath: embDest.path) {
            guard fm.fileExists(atPath: embURL.path) else {
                self.state = .failed("Bundled resource embeddings.npy not found")
                return
            }
            do { try fm.copyItem(at: embURL, to: embDest) }
            catch { self.state = .failed("Failed copying embeddings.npy: \(error.localizedDescription)"); return }
        }

        if !fm.fileExists(atPath: embIdsDest.path) {
            guard fm.fileExists(atPath: embIdsURL.path) else {
                self.state = .failed("Bundled resource embedding_ids.npy not found")
                return
            }
            do { try fm.copyItem(at: embIdsURL, to: embIdsDest) }
            catch { self.state = .failed("Failed copying embedding_ids.npy: \(error.localizedDescription)"); return }
        }

        // Locate or install uv
        self.progress = 0.25
        self.statusMessage = "Locating uv packaging manager..."

        // Resolution order: bundled bin/uv (see build.command), ~/.MusicStudio/bin/uv, then PATH.
        let bundledUv = bundleResourceURL.appendingPathComponent("bin/uv").path
        var uvPath = bundledUv
        if !fm.fileExists(atPath: uvPath) {
            uvPath = binDir.appendingPathComponent("uv").path
        }
        if !fm.fileExists(atPath: uvPath) {
            let which = run("/usr/bin/which", ["uv"])
            let whichUv = which.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if which.status == 0, fm.fileExists(atPath: whichUv) {
                uvPath = whichUv
            }
        }

        guard fm.fileExists(atPath: uvPath) else {
            self.state = .failed("uv binary not found (looked in bundle bin/uv, ~/.MusicStudio/bin/uv, and PATH)")
            return
        }

        // Create venv
        self.progress = 0.35
        self.statusMessage = "Creating isolated Python 3.12 virtualenv..."
        let venvPath = home.appendingPathComponent("venv").path

        if !fm.fileExists(atPath: Self.pythonBinURL.path) {
            let venvOut = run(uvPath, ["venv", venvPath, "--python", "3.12"]).output
            if !fm.fileExists(atPath: Self.pythonBinURL.path) {
                self.state = .failed("Failed to create Python 3.12 virtualenv with uv: \(venvOut)")
                return
            }
        }

        guard fm.fileExists(atPath: Self.pythonBinURL.path) else {
            self.state = .failed("Failed to create Python virtual environment with uv.")
            return
        }

        // Install packages
        self.progress = 0.50
        self.statusMessage = "Installing MLX, audio processing, and model dependencies..."
        let reqURL = bundleResourceURL.appendingPathComponent("requirements.txt")
        guard fm.fileExists(atPath: reqURL.path) else {
            self.state = .failed("Bundled resource requirements.txt not found")
            return
        }
        let pipRes = run(uvPath, ["pip", "install", "--python", Self.pythonBinURL.path, "-r", reqURL.path])
        print("[Setup] Pip install result: \(pipRes.output)")
        guard pipRes.status == 0 else {
            self.state = .failed("Installing Python dependencies failed (check your network connection, then retry):\n\(Self.tail(pipRes.output))")
            return
        }

        // YuE2 engine (lyra). Installed without its own deps: they are pinned in
        // requirements.txt, and upstream's older pins would downgrade the shared stack.
        self.progress = 0.85
        self.statusMessage = "Installing YuE2 engine..."
        let engineReqURL = bundleResourceURL.appendingPathComponent("engine-requirements.txt")
        guard fm.fileExists(atPath: engineReqURL.path) else {
            self.state = .failed("Bundled resource engine-requirements.txt not found")
            return
        }
        let engineRes = run(uvPath, ["pip", "install", "--python", Self.pythonBinURL.path, "--no-deps", "-r", engineReqURL.path])
        print("[Setup] Engine install result: \(engineRes.output)")
        guard engineRes.status == 0 else {
            self.state = .failed("Installing the YuE2 engine failed (check your network connection, then retry):\n\(Self.tail(engineRes.output))")
            return
        }


        // Initialize SQLite database and model availability
        self.progress = 0.95
        self.statusMessage = "Initializing database catalog..."
        let studioScript = bundleResourceURL.appendingPathComponent("studio.py")
        guard fm.fileExists(atPath: studioScript.path) else {
            self.state = .failed("Bundled resource studio.py not found")
            return
        }

        let initRes = run(Self.pythonBinURL.path, [studioScript.path, "--db", dbDest.path, "init"])
        print("[Setup] Init db: \(initRes.output)")
        guard initRes.status == 0 else {
            self.state = .failed("Initializing the database failed:\n\(Self.tail(initRes.output))")
            return
        }

        self.progress = 1.0
        self.statusMessage = "Setup complete! Ready to launch studio."
        self.state = .ready
    }

    /// Runs an executable with an argument vector (no shell, so paths with spaces or
    /// quotes are passed through intact). Returns the exit status and merged stdout/stderr.
    private func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardInput = nil

        do {
            try task.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    /// Last lines of a command's output, for a readable failure message.
    private static func tail(_ output: String, lines: Int = 8) -> String {
        output.split(separator: "\n", omittingEmptySubsequences: true).suffix(lines).joined(separator: "\n")
    }
}
