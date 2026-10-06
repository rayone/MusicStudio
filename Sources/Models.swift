import Foundation

// MARK: - CoT Mode for YuE2
public enum CoTMode: String, CaseIterable, Identifiable, Codable {
    case full = "full"
    case melody = "melody"
    case off = "off"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .full:
            return "Full (Chords + Melody)"
        case .melody:
            return "Melody Only"
        case .off:
            return "Off (Direct Codec)"
        }
    }

    public var description: String {
        switch self {
        case .full:
            return "Generates complete symbolic ABC musical score with chord progressions."
        case .melody:
            return "Outlines primary melodic line without harmonic chord annotations."
        case .off:
            return "Skips symbolic planning stage and directly generates acoustic codec frames."
        }
    }
}

// MARK: - Audio Formats
public enum AudioFormat: String, CaseIterable, Identifiable, Codable {
    case wav = "wav"
    case mp3 = "mp3"
    case m4a = "m4a"
    case flac = "flac"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .wav: return "WAV (Uncompressed)"
        case .mp3: return "MP3 (320 kbps)"
        case .m4a: return "M4A (AAC 256 kbps)"
        case .flac: return "FLAC (Lossless)"
        }
    }
}

// MARK: - Structured Logging Models (FR-001)
public enum LogComponent: String, CaseIterable, Codable, Sendable {
    // Orchestration
    case app, ui, queue, worker, power, setup, hf
    // Generation pipeline
    case model, tokenizer, ar, nar, flow, vae, cot
    // Post-processing
    case loudness, convert, tags, stems, sfx, eq, eval
    // Data
    case db, search, embed, template, lyrics, abc, fs

    public var displayName: String {
        rawValue.uppercased()
    }

    public static func fromString(_ str: String) -> LogComponent {
        let lower = str.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return LogComponent(rawValue: lower) ?? .app
    }
}

public enum LogLevel: Int, Comparable, Codable, Sendable {
    case trace = 0, debug, info, warn, error

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .trace: return "trace"
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warn"
        case .error: return "error"
        }
    }

    public static func fromString(_ str: String) -> LogLevel {
        switch str.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "trace": return .trace
        case "debug": return .debug
        case "warn", "warning": return .warn
        case "error", "err": return .error
        default: return .info
        }
    }
}

public struct LogEntry: Identifiable, Sendable {
    public let id: UUID
    public let at: Date
    public let component: LogComponent
    public let level: LogLevel
    public let message: String
    public let detail: String

    public init(id: UUID = UUID(), at: Date = Date(), component: LogComponent, level: LogLevel = .info, message: String, detail: String = "") {
        self.id = id
        self.at = at
        self.component = component
        self.level = level
        self.message = message
        self.detail = detail
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public var formattedTimestamp: String {
        Self.timeFormatter.string(from: at)
    }

    public var plain: String {
        let compPadded = component.displayName.padding(toLength: 9, withPad: " ", startingAt: 0)
        let lvlPadded = level.displayName.padding(toLength: 5, withPad: " ", startingAt: 0)
        if detail.isEmpty {
            return "\(formattedTimestamp)  \(compPadded)  \(lvlPadded)  \(message)"
        } else {
            return "\(formattedTimestamp)  \(compPadded)  \(lvlPadded)  \(message)          \(detail)"
        }
    }
}

// MARK: - Prompt & Style Catalog
public struct PromptTemplate: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var genre: String
    public var subgenre: String
    public var source: String
    public var format: String
    public var bpm: Int?
    public var key: String?
    public var scale: String?
    public var vocal: String
    public var time_signature: String = "4/4"
    public var vocal_register: String? = nil
    public var mood_arc: String? = nil
    public var core_palette: String? = nil
    public var language: String = "english"
    public var moods: [String]
    public var instruments: [String]
    public var tags: [String]
    public var caption: String
    public var caption_flat: String
    public var key_elements: [String]
    public var variations: [String]
    public var pro_tip: String
    public var searchBlob: String = ""
    public var similarity: Double? = nil
    public var is_user: Bool = false
    public init(
        id: String,
        title: String,
        genre: String = "",
        subgenre: String = "",
        source: String = "",
        format: String = "structured",
        bpm: Int? = nil,
        key: String? = nil,
        scale: String? = nil,
        vocal: String = "",
        time_signature: String = "4/4",
        vocal_register: String? = nil,
        mood_arc: String? = nil,
        core_palette: String? = nil,
        language: String = "english",
        moods: [String] = [],
        instruments: [String] = [],
        tags: [String] = [],
        caption: String = "",
        caption_flat: String = "",
        key_elements: [String] = [],
        variations: [String] = [],
        pro_tip: String = "",
        searchBlob: String = "",
        similarity: Double? = nil,
        is_user: Bool = false
    ) {
        self.id = id
        self.title = title
        self.genre = genre
        self.subgenre = subgenre
        self.source = source
        self.format = format
        self.bpm = bpm
        self.key = key
        self.scale = scale
        self.vocal = vocal
        self.time_signature = time_signature
        self.vocal_register = vocal_register
        self.mood_arc = mood_arc
        self.core_palette = core_palette
        self.language = language
        self.moods = moods
        self.instruments = instruments
        self.tags = tags
        self.caption = caption
        self.caption_flat = caption_flat
        self.key_elements = key_elements
        self.variations = variations
        self.pro_tip = pro_tip
        self.searchBlob = searchBlob
        self.similarity = similarity
        self.is_user = is_user
    }
}

public struct Keyword: Codable, Hashable, Identifiable {
    public var term: String
    public var count: Int
    public var kind: String
    public var id: String { term }

    public init(term: String, count: Int, kind: String) {
        self.term = term
        self.count = count
        self.kind = kind
    }
}

// MARK: - Lyrics Library Model (FR-006)
public struct LyricSet: Identifiable, Codable, Hashable, Sendable {
    public var id: Int
    public var title: String
    public var structure: String
    public var body: String
    public var language: String
    public var genre_affinity: String
    public var is_user: Bool

    public init(id: Int, title: String, structure: String, body: String, language: String = "english", genre_affinity: String = "", is_user: Bool = false) {
        self.id = id
        self.title = title
        self.structure = structure
        self.body = body
        self.language = language
        self.genre_affinity = genre_affinity
        self.is_user = is_user
    }
}

public struct SongwriterSongSummary: Codable, Identifiable, Hashable {
    public let id: String
    public let revision: Int
    public let title: String
    public let summary: String
    public let genre: String
    public let subgenre: String
    public let language: String
    public let instrumental: Bool
    public let duration_hint_sec: Double?
    public let bpm: Int?
    public let key: String?
    public let scale: String?
    public let time_signature: String?
    public let has_abc: Bool?
    public var created_at: String?
    public let updated_at: String
}

public struct SongwriterSongList: Codable {
    public let songs: [SongwriterSongSummary]
    public let next_cursor: String?
}

public struct SongwriterCreative: Codable, Hashable {
    public let caption: String
    public let lyrics: String
    public let instrumental: Bool
    public let language: String?
    public let genre: String?
    public let subgenre: String?
    public let moods: [String]?
    public let instruments: [String]?
    public let bpm: Int?
    public let key: String?
    public let scale: String?
    public let time_signature: String?
    public let vocal_style: String?
    public let duration_hint_sec: Double?
}

public struct SongwriterModelInput: Codable, Hashable {
    public let caption: String?
    public let style: String?
    public let lyrics: String
    public let abc_score: String?
}

public struct SongwriterModelInputs: Codable, Hashable {
    public let minimax: SongwriterModelInput?
    public let yue2: SongwriterModelInput?
}

public struct SongwriterSongDetail: Codable, Hashable {
    public let id: String
    public let revision: Int
    public let title: String
    public let summary: String
    public let status: String
    public let creative: SongwriterCreative
    public let model_inputs: SongwriterModelInputs?
    public let created_at: String?
    public let updated_at: String
}

public struct ModelRow: Identifiable, Hashable {
    public var id: String
    public var name: String
    public var family: String
    public var backend: String
    public var weightsPath: String
    public var available: Bool
    public var reason: String

    public init(id: String, name: String, family: String, backend: String, weightsPath: String, available: Bool, reason: String) {
        self.id = id
        self.name = name
        self.family = family
        self.backend = backend
        self.weightsPath = weightsPath
        self.available = available
        self.reason = reason
    }
}

public struct SongBenchEvaluation: Codable, Hashable, Sendable {
    public var generationId: Int
    public var status: String
    public var melody: Double?
    public var arrangement: Double?
    public var musicality: Double?
    public var vocal: Double?
    public var instrumental: Double?
    public var mixing: Double?
    public var structure: Double?
    public var overall: Double?
    public var device: String?
    public var evaluatorVersion: String
    public var elapsedSec: Double
    public var error: String?
    public var createdAt: Double
    public var updatedAt: Double
}

/// Flattened metadata read from a track's tags or the generations.analysis column.
/// Keys mirror read_audio_tags() output: top-level standard fields plus nested
/// gen/target/dsp/norm/sb groups. Stored as string pairs for display.
public struct TrackAnalysis: Codable, Hashable, Sendable {
    public var standard: [String: String]   // title, artist, bpm, key, duration_ms, ...
    public var gen: [String: String]        // seed, steps, guidance, model, ...
    public var target: [String: String]     // target_bpm, target_key
    public var dsp: [String: String]        // camelot, onset_rate_hz, mood_descriptor, ...
    public var norm: [String: String]       // lufs, lra_lu, pre_peak_db, ...
    public var sb: [String: String]         // score_overall, melody, ...

    public init(standard: [String: String] = [:], gen: [String: String] = [:],
                target: [String: String] = [:], dsp: [String: String] = [:],
                norm: [String: String] = [:], sb: [String: String] = [:]) {
        self.standard = standard; self.gen = gen; self.target = target
        self.dsp = dsp; self.norm = norm; self.sb = sb
    }

    /// Parse the JSON stored in generations.analysis (or `studio.py tags` output).
    public static func parse(_ json: String) -> TrackAnalysis? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let groupKeys: Set<String> = ["gen", "target", "dsp", "norm", "sb"]
        func strMap(_ any: Any?) -> [String: String] {
            guard let d = any as? [String: Any] else { return [:] }
            var out = [String: String]()
            for (k, v) in d {
                if v is [String: Any] { continue }
                out[k] = String(describing: v)
            }
            return out
        }
        var std = [String: String]()
        for (k, v) in obj where !groupKeys.contains(k) && !(v is [String: Any]) {
            std[k] = String(describing: v)
        }
        return TrackAnalysis(
            standard: std, gen: strMap(obj["gen"]), target: strMap(obj["target"]),
            dsp: strMap(obj["dsp"]), norm: strMap(obj["norm"]), sb: strMap(obj["sb"])
        )
    }

    public var isEmpty: Bool {
        standard.isEmpty && gen.isEmpty && target.isEmpty && dsp.isEmpty && norm.isEmpty && sb.isEmpty
    }
}

/// One position on a parameter's label table: normalized start (0...1) and its display text.
public struct ParamStep: Hashable, Sendable {
    public var start: Double
    public var label: String
}

/// One control of a loaded VST3/AU plugin.
///
/// Values are normalized 0...1, the scale both a plugin's VST3 and AU builds share, so the
/// same row can drive a live Audio Unit or a pedalboard (VST3) render. `steps` maps a
/// position to the plugin's own display text ("163 ms", "Gemini"), taken from its VST3
/// build when available.
public struct VSTParameter: Identifiable, Hashable, Sendable {
    public var id: String { name }
    /// Engine key used for `--raw name=value` renders (VST3 param name).
    public var name: String
    public var label: String
    public var raw: Double
    public var steps: [ParamStep]
    public var isChoice: Bool
    public var isHidden: Bool
    /// Live Audio Unit parameter this row drives, with its native range.
    public var auAddress: UInt64?
    public var auMin: Double = 0
    public var auMax: Double = 1

    public init(name: String, label: String, raw: Double, steps: [ParamStep] = [],
                isChoice: Bool = false, isHidden: Bool = false, auAddress: UInt64? = nil,
                auMin: Double = 0, auMax: Double = 1) {
        self.name = name; self.label = label; self.raw = raw; self.steps = steps
        self.isChoice = isChoice; self.isHidden = isHidden
        self.auAddress = auAddress; self.auMin = auMin; self.auMax = auMax
    }

    /// Index of the step covering a normalized value.
    public func stepIndex(for value: Double) -> Int? {
        guard !steps.isEmpty else { return nil }
        var lo = 0, hi = steps.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if steps[mid].start <= value + 1e-9 { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// Display text for the current value: the plugin's label, or a rounded number.
    public var display: String {
        if let i = stepIndex(for: raw) { return steps[i].label }
        return String(format: "%.2f", raw)
    }

    /// Normalized value at the middle of step `i` (safe target when picking a choice).
    public func value(forStep i: Int) -> Double {
        let start = steps[i].start
        let end = i + 1 < steps.count ? steps[i + 1].start : 1.0
        return min(max((start + end) / 2, 0), 1)
    }

    /// Two-state choice labelled Off/On: shown as a switch.
    public var isSwitch: Bool {
        guard isChoice, steps.count == 2 else { return false }
        return steps[0].label.lowercased() == "off" && steps[1].label.lowercased() == "on"
    }

    /// Convert to / from the live Audio Unit's native range.
    public var auValue: Double { auMin + raw * (auMax - auMin) }
    public func normalized(fromAU v: Double) -> Double {
        auMax > auMin ? min(max((v - auMin) / (auMax - auMin), 0), 1) : 0
    }

    /// Placeholder controls some plugins expose (e.g. Reserved1-4).
    public static func looksHidden(_ name: String) -> Bool {
        name.range(of: #"^(reserved|unused|dummy|placeholder)[0-9]*$"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Loose key for matching an AU parameter to its VST3 counterpart ("Delay_Ms" ~ "delay_ms").
    public static func matchKey(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Readable control name: "delay_ms" -> "Delay ms", "LowCut" -> "Low Cut".
    public static func prettyName(_ s: String) -> String {
        var out = ""
        var prev: Character? = nil
        for c in s {
            if c == "_" || c == "-" { out.append(" "); prev = " "; continue }
            if let p = prev, c.isUppercase, p.isLowercase { out.append(" ") }
            out.append(c)
            prev = c
        }
        let words = out.split(separator: " ").map(String.init)
        guard let first = words.first else { return s }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}

/// A loaded external effect plugin and its parameters.
public struct VSTPlugin: Hashable, Sendable {
    /// File the user picked (.vst3 or .component).
    public var path: String
    /// File pedalboard renders with offline: the plugin's VST3 when one is installed.
    public var renderPath: String
    public var name: String
    public var manufacturer: String
    public var isEffect: Bool
    /// True when labels/units came from a VST3 build (real values, not raw 0..1).
    public var hasRealLabels: Bool
    public var parameters: [VSTParameter]

    public init(path: String, renderPath: String, name: String, manufacturer: String = "",
                isEffect: Bool = true, hasRealLabels: Bool = true, parameters: [VSTParameter] = []) {
        self.path = path; self.renderPath = renderPath; self.name = name
        self.manufacturer = manufacturer; self.isEffect = isEffect
        self.hasRealLabels = hasRealLabels; self.parameters = parameters
    }

    /// Parse `studio.py effect --list-params` JSON. Parameters keep the plugin's own order.
    public static func parse(_ json: Data, path: String, renderPath: String) -> VSTPlugin? {
        guard let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              obj["error"] == nil else { return nil }
        var params: [VSTParameter] = []
        // JSONSerialization drops key order, so recover it from the raw text.
        let order = orderedKeys(in: json)
        if let pdict = obj["parameters"] as? [String: Any] {
            for name in order where pdict[name] != nil {
                let info = pdict[name] as? [String: Any] ?? [:]
                let steps: [ParamStep] = (info["steps"] as? [[Any]] ?? []).compactMap { s in
                    guard s.count == 2, let start = (s[0] as? NSNumber)?.doubleValue else { return nil }
                    return ParamStep(start: start, label: String(describing: s[1]))
                }
                params.append(VSTParameter(
                    name: name,
                    // pedalboard's "label" is the unit ("%", "ms"), so name rows from the key.
                    label: VSTParameter.prettyName(name),
                    raw: (info["raw"] as? NSNumber)?.doubleValue ?? 0,
                    steps: steps,
                    isChoice: info["choice"] as? Bool ?? false,
                    isHidden: info["hidden"] as? Bool ?? VSTParameter.looksHidden(name)
                ))
            }
        }
        let isVST3 = URL(fileURLWithPath: renderPath).pathExtension.lowercased() == "vst3"
        return VSTPlugin(
            path: path, renderPath: renderPath,
            name: obj["plugin"] as? String ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
            manufacturer: obj["manufacturer"] as? String ?? "",
            isEffect: obj["is_effect"] as? Bool ?? true,
            hasRealLabels: isVST3,
            parameters: params
        )
    }

    /// Parameter names in the order they appear in the engine's JSON.
    private static func orderedKeys(in json: Data) -> [String] {
        guard let text = String(data: json, encoding: .utf8),
              let start = text.range(of: "\"parameters\":{") else { return [] }
        var keys: [String] = []
        var depth = 0, i = start.upperBound, inString = false, escaped = false
        var current = "", collecting = false
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false; if collecting { current.append(c) } }
                else if c == "\\" { escaped = true }
                else if c == "\"" {
                    inString = false
                    if collecting { keys.append(current); collecting = false }
                } else if collecting { current.append(c) }
            } else if c == "\"" {
                inString = true
                if depth == 0 { collecting = true; current = "" }
            } else if c == "{" || c == "[" { depth += 1 }
            else if c == "}" || c == "]" { if depth == 0 { break }; depth -= 1 }
            i = text.index(after: i)
        }
        return keys
    }
}

public struct GenerationHistoryItem: Identifiable, Codable, Hashable {
    public var id: String
    public var timestamp: String
    public var model: String
    public var caption: String
    public var lyrics: String
    public var duration: Double
    public var steps: Int
    public var guidance: Double
    public var seed: Int
    public var output_file: String
    public var sidecar_file: String?
    public var format: String
    public var size_mb: Double
    public var elapsed_sec: Double
    public var songbench: SongBenchEvaluation?
    public var analysis: TrackAnalysis?

    public init(
        id: String,
        timestamp: String,
        model: String,
        caption: String,
        lyrics: String,
        duration: Double,
        steps: Int,
        guidance: Double = 1.7,
        seed: Int,
        output_file: String,
        sidecar_file: String? = nil,
        format: String = "wav",
        size_mb: Double = 0.0,
        elapsed_sec: Double = 0.0,
        songbench: SongBenchEvaluation? = nil,
        analysis: TrackAnalysis? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.caption = caption
        self.lyrics = lyrics
        self.duration = duration
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
        self.output_file = output_file
        self.sidecar_file = sidecar_file
        self.format = format
        self.size_mb = size_mb
        self.elapsed_sec = elapsed_sec
        self.songbench = songbench
        self.analysis = analysis
    }
}

public struct QueueJobItem: Identifiable, Hashable {
    public var id: Int
    public var batchId: String
    public var status: String
    public var position: Int
    public var seed: Int
    public var duration: Double
    public var steps: Int
    public var format: String
    public var title: String
    /// Full DB/catalog identifier used for calibration and execution.
    public var modelId: String
    /// Short display name for compact queue rows.
    public var model: String
    public var error: String?

    public init(id: Int, batchId: String, status: String, position: Int, seed: Int, duration: Double, steps: Int, format: String, title: String, modelId: String, model: String, error: String? = nil) {
        self.id = id
        self.batchId = batchId
        self.status = status
        self.position = position
        self.seed = seed
        self.duration = duration
        self.steps = steps
        self.format = format
        self.title = title
        self.modelId = modelId
        self.model = model
        self.error = error
    }
}

public struct EventMessage: Codable {
    public var event: String
    public var component: String?
    public var level: String?
    public var message: String?
    public var output_file: String?
    public var seed: Int?
    public var item: GenerationHistoryItem?
    public var pending: Int?
    public var processed: Int?
    public var job_id: Int?
    public var generation_id: Int?
    public var evaluation: SongBenchEvaluation?
    public var index: Int?
    public var total: Int?
    public var stage: String?
    public var fraction: Double?
    public var error: String?
    public var frame: Int?
    public var max_frames: Int?
    public var fps: Double?
    public var chunk: Int?
    public var total_chunks: Int?
    public var step: Int?
    public var total_steps: Int?
    public var steps: Int?
    public var model: String?
    public var duration: Double?
    public var family: String?
    public var elapsed: Double?
    public var abc_file: String?
    public var abc_score: String?
    // Mastering (FR-013)
    public var output: String?
    public var input: String?
    public var lufs: Double?
    public var peak_db: Double?
    public var hf_repair: Bool?
    public var artifact_reduction: Bool?
    public var size_mb: Double?
}
