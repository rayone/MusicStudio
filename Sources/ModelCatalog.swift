import Foundation

public enum ModelFamily: String, Codable, CaseIterable, Identifiable {
    case minimax_music3 = "minimax_music3"
    case yue2 = "yue2"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .minimax_music3:
            return "MiniMax Music 3"
        case .yue2:
            return "YuE2-3B"
        }
    }

    public var shortDescription: String {
        switch self {
        case .minimax_music3:
            return "MLX DiT flow matching + Qwen3 AR language model"
        case .yue2:
            return "MLX AR/NAR Mixture-of-Transformers with symbolic CoT planning"
        }
    }

    public var iconName: String {
        switch self {
        case .minimax_music3:
            return "waveform.path.ecg"
        case .yue2:
            return "music.quarternote.3"
        }
    }
}

public struct ModelCapabilities: Codable, Hashable {
    public var lyrics: Bool
    public var instrumental: Bool
    public var cot: Bool
    public var abc_score: Bool
    public var max_duration: Double
    public var default_duration: Double
    public var steps_range: [Int]
    public var default_steps: Int
    public var guidance_range: [Double]
    public var default_guidance: Double
    public var prompt_format: String
    public var sample_rate: Int

    public init(
        lyrics: Bool = true,
        instrumental: Bool = true,
        cot: Bool = false,
        abc_score: Bool = false,
        max_duration: Double = 360,
        default_duration: Double = 60,
        steps_range: [Int] = [1, 30],
        default_steps: Int = 30,
        guidance_range: [Double] = [1.0, 3.0],
        default_guidance: Double = 1.7,
        prompt_format: String = "structured",
        sample_rate: Int = 44100
    ) {
        self.lyrics = lyrics
        self.instrumental = instrumental
        self.cot = cot
        self.abc_score = abc_score
        self.max_duration = max_duration
        self.default_duration = default_duration
        self.steps_range = steps_range
        self.default_steps = default_steps
        self.guidance_range = guidance_range
        self.default_guidance = default_guidance
        self.prompt_format = prompt_format
        self.sample_rate = sample_rate
    }
}

public struct ModelDefinition: Identifiable, Codable, Hashable {
    public var id: String
    public var name: String
    public var family: ModelFamily
    public var backend: String
    public var repo_id: String
    public var subfolder: String?
    public var weights_path: String
    public var quantization: String
    public var size_gb: Double
    public var recommended_min_ram_gb: Int
    public var recommended: Bool
    public var license: String
    public var capabilities: ModelCapabilities
    public var sort_order: Int

    public var isAvailableLocally: Bool {
        let fullPath = ModelCatalog.modelsDirectory.appendingPathComponent(weights_path)
        guard FileManager.default.fileExists(atPath: fullPath.appendingPathComponent("config.json").path) else {
            return false
        }
        if family == .yue2 {
            return FileManager.default.fileExists(
                atPath: fullPath.appendingPathComponent("ar-\(quantization).safetensors").path
            )
        }
        return true
    }

    public var localPathURL: URL {
        let baseDir = ModelCatalog.modelsDirectory
        return baseDir.appendingPathComponent(weights_path)
    }
}

public struct CatalogFile: Codable {
    public var version: Int
    public var models: [ModelDefinition]
}

public enum ModelCatalog {
    public static var modelsDirectory: URL {
        if let custom = UserDefaults.standard.string(forKey: "modelsDirectory"), !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".MusicStudio/models", isDirectory: true)
    }

    public static let bundledModels: [ModelDefinition] = {
        // Try loading from catalog.json in Bundle.main or local Resources/
        let pathsToTry: [URL?] = [
            Bundle.main.url(forResource: "catalog", withExtension: "json"),
            Bundle.main.resourceURL?.appendingPathComponent("catalog.json"),
            URL(fileURLWithPath: "Resources/catalog.json")
        ]
        for optUrl in pathsToTry {
            guard let url = optUrl, let data = try? Data(contentsOf: url) else { continue }
            if let decoded = try? JSONDecoder().decode(CatalogFile.self, from: data) {
                return decoded.models
            }
        }
        return hardcodedDefaults
    }()

    public static func models(for family: ModelFamily) -> [ModelDefinition] {
        bundledModels
            .filter { $0.family == family }
            .sorted { $0.sort_order < $1.sort_order }
    }

    public static func model(withId id: String) -> ModelDefinition? {
        bundledModels.first { $0.id == id }
    }

    public static func recommendedModel(for family: ModelFamily, profile: SystemProfile = .current) -> ModelDefinition? {
        let familyModels = models(for: family)
        switch family {
        case .minimax_music3:
            guard let variant = profile.recommendedMiniMaxVariant else {
                return familyModels.first { $0.quantization == "4bit" }
            }
            return familyModels.first { $0.quantization == variant } ?? familyModels.first
        case .yue2:
            let variant = profile.recommendedYuE2Variant
            return familyModels.first { $0.quantization == variant } ?? familyModels.first
        }
    }

    private static let hardcodedDefaults: [ModelDefinition] = [
        ModelDefinition(
            id: "minimax_music3:MiniMax-Music3-mxfp8",
            name: "MiniMax Music 3 (mxfp8)",
            family: .minimax_music3,
            backend: "mlx",
            repo_id: "mlx-community/MiniMax-Music3-mxfp8",
            subfolder: nil,
            weights_path: "mlx-community/MiniMax-Music3-mxfp8",
            quantization: "mxfp8",
            size_gb: 13.87,
            recommended_min_ram_gb: 32,
            recommended: true,
            license: "Apache-2.0",
            capabilities: ModelCapabilities(),
            sort_order: 10
        ),
        ModelDefinition(
            id: "yue2:YuE2-3B-8bit",
            name: "YuE2-3B (8-bit MLX)",
            family: .yue2,
            backend: "mlx-yue",
            repo_id: "vanch007/mlx-Yue2-3B",
            subfolder: nil,
            weights_path: "vanch007/mlx-Yue2-3B",
            quantization: "8bit",
            size_gb: 5.58,
            recommended_min_ram_gb: 24,
            recommended: true,
            license: "Apache-2.0",
            capabilities: ModelCapabilities(
                lyrics: true, instrumental: true, cot: true, abc_score: true,
                max_duration: 360, default_duration: 60, steps_range: [8, 64],
                default_steps: 32, guidance_range: [1.0, 3.0], default_guidance: 1.0,
                prompt_format: "tagline", sample_rate: 48000
            ),
            sort_order: 60
        )
    ]
}
