import Foundation
import SQLite3

public class DB {
    public static var shared: DB!
    public static var logger: ((LogComponent, LogLevel, String, String) -> Void)?


    public static var defaultDatabasePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".MusicStudio/studio.db").path
    }

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "studio.db.serial")
    /// Calibration is stable between completed generations. Cache it so the 1s UI ETA
    /// ticker never re-runs SQL or emits a DB log for every queued row.
    private var calibrationCache: [String: Double] = [:]
    private var calibratedModelIds = Set<String>()

    public init(path: String) {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(path, &db, flags, nil) != SQLITE_OK {
            let msg = db != nil ? String(cString: sqlite3_errmsg(db)) : "unknown"
            Self.logger?(.db, .error, "Error opening database at \(path): \(msg)", "")
        } else {
            Self.logger?(.db, .info, "Database opened successfully", "path=\(path) journal=WAL")
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys = ON;", nil, nil, nil)
        sqlite3_busy_timeout(db, 5000)
    }
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    public func fetchTemplates() -> [PromptTemplate] { queue.sync { _fetchTemplates() } }
    public func saveTemplate(
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
    ) -> Int {
        queue.sync {
            _saveTemplate(
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
        }
    }
    public func deleteTemplate(id: Int) {
        queue.sync { _deleteTemplate(id: id) }
    }
    public func fetchKeywords() -> [Keyword] { queue.sync { _fetchKeywords() } }
    public func fetchGenerations(limit: Int = 200) -> [GenerationHistoryItem] {
        queue.sync { _fetchGenerations(limit: limit) }
    }
    public func pendingJobCount() -> Int { queue.sync { _pendingJobCount() } }
    public func fetchModels() -> [ModelRow] { queue.sync { _fetchModels() } }
    public func fetchQueueJobs() -> [QueueJobItem] { queue.sync { _fetchQueueJobs() } }
    public func cancelJob(id: Int) { queue.sync { _cancelJob(id: id) } }
    public func dismissFailedJobs() { queue.sync { _dismissFailedJobs() } }
    public func deleteGeneration(id: String) { queue.sync { _deleteGeneration(id: id) } }
    public func clearQueue() { queue.sync { _clearQueue() } }
    public func requeueRunningJobs() { queue.sync { _requeueRunningJobs() } }
    public struct DatabaseTableCounts {
        public let generations: Int
        public let templates: Int
        public let lyrics: Int
        public init(generations: Int, templates: Int, lyrics: Int) {
            self.generations = generations
            self.templates = templates
            self.lyrics = lyrics
        }
    }

    public func tableCounts() -> DatabaseTableCounts {
        queue.sync {
            var gen = 0, tmpl = 0, lyr = 0
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT count(*) FROM generations", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { gen = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
            if sqlite3_prepare_v2(db, "SELECT count(*) FROM prompts", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { tmpl = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
            if sqlite3_prepare_v2(db, "SELECT count(*) FROM lyrics", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW { lyr = Int(sqlite3_column_int(stmt, 0)) }
                sqlite3_finalize(stmt)
            }
            return DatabaseTableCounts(generations: gen, templates: tmpl, lyrics: lyr)
        }
    }

    /// Median seconds-of-compute per second-of-audio for a given model, from recorded generations.
    /// Median seconds-of-compute per second-of-audio, cached until a generation completes.
    public func calibratedSecondsPerAudioSecond(modelId: String) -> Double? {
        queue.sync {
            if calibratedModelIds.contains(modelId) { return calibrationCache[modelId] }
            let ratio = _calibratedSecPerAudioSec(modelId: modelId)
            calibratedModelIds.insert(modelId)
            if let ratio { calibrationCache[modelId] = ratio }
            return ratio
        }
    }

    public func invalidateCalibrationCache() {
        queue.sync {
            calibrationCache.removeAll(keepingCapacity: true)
            calibratedModelIds.removeAll(keepingCapacity: true)
        }
    }
    public func fetchLyrics(forPromptId pid: String? = nil) -> [LyricSet] {
        queue.sync { _fetchLyrics(forPromptId: pid) }
    }
    public func saveLyricSet(title: String, body: String, structure: String = "", promptId: String? = nil) -> Int {
        queue.sync { _saveLyricSet(title: title, body: body, structure: structure, promptId: promptId) }
    }
    public func deleteLyricSet(id: Int) {
        queue.sync { _deleteLyricSet(id: id) }
    }

    /// FTS5-backed keyword search over prompts_fts (BM25 ranked). Returns prompt ids
    /// (rowid == prompts.id) best-match first. Every whitespace term is required and
    /// prefix-matched to preserve as-you-type behavior. Returns nil on error so callers
    /// can fall back to substring search.
    public func searchTemplateIDs(_ query: String) -> [Int]? {
        queue.sync { _searchTemplateIDs(query) }
    }

    /// Insert one queued job on the shared WAL connection (serialized, busy-timeout aware).
    /// `position` is supplied by the caller so a batch can compute the base once and
    /// increment in Swift, avoiding a per-row MAX(position) subquery. Returns the new job id.
    public func enqueueJob(batchId: String, modelId: String, caption: String, lyrics: String,
                           seed: Int, params: String, position: Int) -> Int {
        queue.sync { _enqueueJob(batchId: batchId, modelId: modelId, caption: caption,
                                 lyrics: lyrics, seed: seed, params: params, position: position) }
    }

    /// Current base for the next queued job: MAX(position)+1 among queued jobs.
    public func nextQueuedPosition() -> Int {
        queue.sync { _nextQueuedPosition() }
    }

    private func _searchTemplateIDs(_ query: String) -> [Int]? {
        let terms = query
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        // Quote each term to neutralize FTS5 syntax chars, then append * for prefix match.
        // "term"* — a phrase-quoted prefix token. Every term is ANDed (all required).
        let match = terms.map { term -> String in
            let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " ")

        let sql = "SELECT rowid FROM prompts_fts WHERE prompts_fts MATCH ? ORDER BY rank"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logDb(.error, "FTS prepare failed", String(cString: sqlite3_errmsg(db)))
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        // SQLITE_TRANSIENT so SQLite copies the string.
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
        var ids = [Int]()
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                ids.append(Int(sqlite3_column_int(stmt, 0)))
            } else if rc == SQLITE_DONE {
                break
            } else {
                logDb(.error, "FTS step failed", String(cString: sqlite3_errmsg(db)))
                return nil
            }
        }
        return ids
    }

    private func _nextQueuedPosition() -> Int {
        let sql = "SELECT COALESCE(MAX(position), 0) + 1 FROM jobs WHERE status IN ('queued','running')"
        var stmt: OpaquePointer?
        var pos = 1
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                pos = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return pos
    }

    private func _enqueueJob(batchId: String, modelId: String, caption: String, lyrics: String,
                             seed: Int, params: String, position: Int) -> Int {
        let sql = """
            INSERT INTO jobs (batch_id, model_id, caption, lyrics, seed, params, status, position, progress, created_at)
            VALUES (?, ?, ?, ?, ?, ?, 'queued', ?, 0.0, ?)
        """
        var stmt: OpaquePointer?
        let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logDb(.error, "enqueueJob prepare failed", String(cString: sqlite3_errmsg(db)))
            return -1
        }
        sqlite3_bind_text(stmt, 1, batchId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, modelId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, caption, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, lyrics, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 5, Int64(seed))
        sqlite3_bind_text(stmt, 6, params, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 7, Int32(position))
        sqlite3_bind_double(stmt, 8, Date().timeIntervalSince1970)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if rc != SQLITE_DONE {
            logDb(.error, "enqueueJob insert failed", String(cString: sqlite3_errmsg(db)))
            return -1
        }
        return Int(sqlite3_last_insert_rowid(db))
    }

    private func logDb(_ level: LogLevel, _ msg: String, _ detail: String = "") {
        Self.logger?(.db, level, msg, detail)
    }

    private static let fieldLabels: [String: String] = [
        "basic_attributes": "Basic Attributes",
        "emotional_progression": "Global Emotional Progression",
        "application_scenarios": "Application Scenarios & Imagery",
        "sonics_production": "Sonics & Production Profile",
        "vocal_gender_timbre": "Vocal Gender & Timbre",
        "vocal_style": "Vocal Style",
        "harmony_backing": "Harmony/Backing Vocals",
        "vocal_fx": "Vocal FX",
        "instrument_lifecycle": "Instrument Lifecycle Description (Primary/Secondary Layering)",
        "primary_layer": "Primary",
        "secondary_layer": "Secondary",
        "groove_foundation": "Groove & Foundation Progression",
        "embellishments": "Embellishments, Textures & Spatial FX"
    ]

    private func _fetchTemplates() -> [PromptTemplate] {
        func cText(_ s: OpaquePointer?, _ i: Int32) -> String {
            guard let p = sqlite3_column_text(s, i) else { return "" }
            return String(cString: p)
        }
        func cOptText(_ s: OpaquePointer?, _ i: Int32) -> String? {
            guard sqlite3_column_type(s, i) != SQLITE_NULL, let p = sqlite3_column_text(s, i) else { return nil }
            return String(cString: p)
        }

        // 1) All prompts, ordered by id.
        var results = [PromptTemplate]()
        var indexByPid = [Int: Int]()   // prompt id -> index in results
        let promptQuery = """
            SELECT id, title, genre, subgenre, source, format,
                   bpm, music_key, scale, vocal, pro_tip,
                   COALESCE(time_signature, '4/4'), vocal_register, mood_arc, core_palette, COALESCE(language, 'english'),
                   COALESCE(is_user, 0)
            FROM prompts
            ORDER BY id ASC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, promptQuery, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let pid = Int(sqlite3_column_int(stmt, 0))
                let timeSig = sqlite3_column_type(stmt, 11) != SQLITE_NULL ? cText(stmt, 11) : "4/4"
                let lang = sqlite3_column_type(stmt, 15) != SQLITE_NULL ? cText(stmt, 15) : "english"
                let pt = PromptTemplate(
                    id: String(pid),
                    title: cText(stmt, 1),
                    genre: cText(stmt, 2),
                    subgenre: cText(stmt, 3),
                    source: cText(stmt, 4),
                    format: cText(stmt, 5),
                    bpm: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil,
                    key: cOptText(stmt, 7),
                    scale: cOptText(stmt, 8),
                    vocal: cText(stmt, 9),
                    time_signature: timeSig,
                    vocal_register: cOptText(stmt, 12),
                    mood_arc: cOptText(stmt, 13),
                    core_palette: cOptText(stmt, 14),
                    language: lang,
                    moods: [],
                    instruments: [],
                    tags: [],
                    caption: "",
                    caption_flat: "",
                    key_elements: [],
                    variations: [],
                    pro_tip: cText(stmt, 10),
                    is_user: sqlite3_column_int(stmt, 16) != 0
                )
                indexByPid[pid] = results.count
                results.append(pt)
            }
        }
        sqlite3_finalize(stmt)

        // 2) All segments, ordered by prompt_id then ordinal/id — merge into prompts in O(N).
        // Per-prompt caption assembly accumulators keyed by prompt id.
        var captionLines = [Int: [String]]()
        var flatText = [Int: String]()
        var keyEls = [Int: [String]]()
        var vars = [Int: [String]]()
        var lastSec = [Int: String]()
        let segQuery = """
            SELECT prompt_id, section, field, content
            FROM prompt_segments
            ORDER BY prompt_id ASC, ordinal ASC, id ASC
        """
        var segStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, segQuery, -1, &segStmt, nil) == SQLITE_OK {
            while sqlite3_step(segStmt) == SQLITE_ROW {
                let pid = Int(sqlite3_column_int(segStmt, 0))
                guard indexByPid[pid] != nil else { continue }
                let sec = cText(segStmt, 1)
                let fld = cText(segStmt, 2)
                let val = cOptText(segStmt, 3) ?? ""

                if sec == "raw" && fld == "flat" {
                    flatText[pid] = val
                } else if sec == "raw" && fld == "key_elements" {
                    keyEls[pid, default: []].append(val)
                } else if sec == "raw" && fld == "variations" {
                    vars[pid, default: []].append(val)
                } else {
                    if lastSec[pid] != sec {
                        let secHeader = sec == "global_metadata" ? "Global Metadata" : (sec == "vocal_details" ? "Vocal Details" : "Arrangement")
                        captionLines[pid, default: []].append(secHeader)
                        lastSec[pid] = sec
                    }
                    let label = Self.fieldLabels[fld] ?? fld
                    if val.isEmpty {
                        captionLines[pid, default: []].append("\(label):")
                    } else {
                        captionLines[pid, default: []].append("\(label): \(val)")
                    }
                }
            }
        }
        sqlite3_finalize(segStmt)

        // 3) All keyword links, ordered by prompt_id.
        let kwQuery = """
            SELECT pk.prompt_id, k.term, k.kind
            FROM prompt_keywords pk
            JOIN keywords k ON k.id = pk.keyword_id
            ORDER BY pk.prompt_id ASC
        """
        var kwStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, kwQuery, -1, &kwStmt, nil) == SQLITE_OK {
            while sqlite3_step(kwStmt) == SQLITE_ROW {
                let pid = Int(sqlite3_column_int(kwStmt, 0))
                guard let idx = indexByPid[pid] else { continue }
                let term = cText(kwStmt, 1)
                let kind = cText(kwStmt, 2)
                if kind == "instrument" { results[idx].instruments.append(term) }
                else if kind == "mood" || kind == "modifier" { results[idx].moods.append(term) }
                else if kind == "tag" || kind == "scenario" || kind == "genre" { results[idx].tags.append(term) }
            }
        }
        sqlite3_finalize(kwStmt)

        // Assemble caption/segment-derived fields and searchBlob per prompt.
        for (pid, idx) in indexByPid {
            let lines = captionLines[pid] ?? []
            let flat = (flatText[pid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !lines.isEmpty {
                results[idx].caption = lines.joined(separator: "\n")
            } else {
                results[idx].caption = flat
            }
            results[idx].caption_flat = flat
            results[idx].key_elements = keyEls[pid] ?? []
            results[idx].variations = vars[pid] ?? []

            let pt = results[idx]
            results[idx].searchBlob = ([
                pt.title, pt.genre, pt.subgenre, pt.source, pt.vocal,
                pt.key ?? "", pt.scale ?? "",
                pt.time_signature, pt.vocal_register ?? "", pt.language,
                pt.bpm.map { "\($0) bpm" } ?? "",
                pt.tags.joined(separator: " "),
                pt.moods.joined(separator: " "),
                pt.instruments.joined(separator: " "),
                pt.caption_flat.isEmpty ? pt.caption : pt.caption_flat
            ].joined(separator: " ")).lowercased()
        }

        logDb(.debug, "Fetched prompt templates", "count=\(results.count)")
        return results
    }

    private func _fetchKeywords() -> [Keyword] {
        var results = [Keyword]()
        let query = "SELECT term, kind, uses FROM keywords WHERE uses >= 1 ORDER BY uses DESC, term ASC"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(Keyword(
                    term: String(cString: sqlite3_column_text(stmt, 0)),
                    count: Int(sqlite3_column_int(stmt, 2)),
                    kind: String(cString: sqlite3_column_text(stmt, 1))
                ))
            }
        }
        sqlite3_finalize(stmt)
        logDb(.debug, "Fetched keywords", "count=\(results.count)")
        return results
    }

    private func _fetchGenerations(limit: Int) -> [GenerationHistoryItem] {
        var results = [GenerationHistoryItem]()
        let hasEvaluationTable: Bool = {
            var check: OpaquePointer?
            defer { sqlite3_finalize(check) }
            guard sqlite3_prepare_v2(
                db,
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='songbench_evaluations'",
                -1, &check, nil
            ) == SQLITE_OK else { return false }
            return sqlite3_step(check) == SQLITE_ROW
        }()
        let evaluationColumns = hasEvaluationTable
            ? "e.status, e.melody, e.arrangement, e.musicality, e.vocal, e.instrumental, e.mixing, e.structure, e.overall, e.device, e.evaluator_version, e.elapsed_sec, e.error, e.created_at, e.updated_at"
            : "NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL"
        let evaluationJoin = hasEvaluationTable
            ? "LEFT JOIN songbench_evaluations e ON e.generation_id = g.id"
            : ""
        // The analysis column arrived in schema v10; tolerate older DBs that lack it.
        let hasAnalysisColumn: Bool = {
            var check: OpaquePointer?
            defer { sqlite3_finalize(check) }
            guard sqlite3_prepare_v2(
                db,
                "SELECT 1 FROM pragma_table_info('generations') WHERE name='analysis'",
                -1, &check, nil
            ) == SQLITE_OK else { return false }
            return sqlite3_step(check) == SQLITE_ROW
        }()
        let analysisColumn = hasAnalysisColumn ? "g.analysis" : "NULL"
        let query = """
            SELECT g.id, g.model_id, g.caption, g.lyrics, g.seed, g.duration, g.steps,
                   g.format, g.output_file, g.sidecar_file, g.size_mb, g.elapsed_sec,
                   g.created_at, g.guidance, \(evaluationColumns), \(analysisColumn)
            FROM generations g
            \(evaluationJoin)
            ORDER BY g.created_at DESC
            LIMIT ?
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"

            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String {
                    guard let p = sqlite3_column_text(stmt, i) else { return "" }
                    return String(cString: p)
                }
                func optText(_ i: Int32) -> String? {
                    guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
                          let p = sqlite3_column_text(stmt, i) else { return nil }
                    return String(cString: p)
                }

                let id = String(sqlite3_column_int64(stmt, 0))
                let modelId = text(1)
                let cap = text(2)
                let lyr = text(3)
                let seed = Int(sqlite3_column_int64(stmt, 4))
                let dur = sqlite3_column_double(stmt, 5)
                let st = Int(sqlite3_column_int(stmt, 6))
                let format = text(7)
                let outFile = text(8)
                let sidecar = optText(9)
                let sizeMb = sqlite3_column_double(stmt, 10)
                let elapsed = sqlite3_column_double(stmt, 11)
                let createdAt = sqlite3_column_double(stmt, 12)
                let dateStr = fmt.string(from: Date(timeIntervalSince1970: createdAt))

                let guidance = sqlite3_column_type(stmt, 13) != SQLITE_NULL ? sqlite3_column_double(stmt, 13) : 1.7
                let songbench: SongBenchEvaluation?
                if sqlite3_column_type(stmt, 14) != SQLITE_NULL {
                    func optDouble(_ i: Int32) -> Double? {
                        sqlite3_column_type(stmt, i) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, i)
                    }
                    songbench = SongBenchEvaluation(
                        generationId: Int(sqlite3_column_int64(stmt, 0)),
                        status: text(14),
                        melody: optDouble(15),
                        arrangement: optDouble(16),
                        musicality: optDouble(17),
                        vocal: optDouble(18),
                        instrumental: optDouble(19),
                        mixing: optDouble(20),
                        structure: optDouble(21),
                        overall: optDouble(22),
                        device: optText(23),
                        evaluatorVersion: text(24),
                        elapsedSec: sqlite3_column_double(stmt, 25),
                        error: optText(26),
                        createdAt: sqlite3_column_double(stmt, 27),
                        updatedAt: sqlite3_column_double(stmt, 28)
                    )
                } else {
                    songbench = nil
                }
                let analysis: TrackAnalysis? = {
                    guard let json = optText(29) else { return nil }
                    let parsed = TrackAnalysis.parse(json)
                    return (parsed?.isEmpty ?? true) ? nil : parsed
                }()
                results.append(GenerationHistoryItem(
                    id: id,
                    timestamp: dateStr,
                    model: modelId,
                    caption: cap,
                    lyrics: lyr,
                    duration: dur,
                    steps: st,
                    guidance: guidance,
                    seed: seed,
                    output_file: outFile,
                    sidecar_file: sidecar,
                    format: format,
                    size_mb: sizeMb,
                    elapsed_sec: elapsed,
                    songbench: songbench,
                    analysis: analysis
                ))
            }
        }
        logDb(.debug, "Fetched generations history", "count=\(results.count) limit=\(limit)")
        sqlite3_finalize(stmt)
        return results
    }

    /// Median (elapsed_sec / duration) across the last 20 successful generations for a model.
    private func _calibratedSecPerAudioSec(modelId: String) -> Double? {
        var ratios: [Double] = []
        var stmt: OpaquePointer?
        let q = """
            SELECT elapsed_sec, duration FROM generations
            WHERE model_id = ? AND elapsed_sec > 0 AND duration > 0
            ORDER BY created_at DESC LIMIT 20
        """
        if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (modelId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let elapsed = sqlite3_column_double(stmt, 0)
                let dur = sqlite3_column_double(stmt, 1)
                if dur > 0 { ratios.append(elapsed / dur) }
            }
        }
        sqlite3_finalize(stmt)
        guard !ratios.isEmpty else { return nil }
        ratios.sort()
        let mid = ratios.count / 2
        let median = ratios.count % 2 == 0 ? (ratios[mid - 1] + ratios[mid]) / 2.0 : ratios[mid]
        return median
    }
    private func _pendingJobCount() -> Int {
        var count = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT count(*) FROM jobs WHERE status IN ('queued', 'running')", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    private func _fetchModels() -> [ModelRow] {
        var rows = [ModelRow]()
        let query = "SELECT id, name, family, backend, weights_path, available, unavailable_reason FROM models ORDER BY sort_order ASC, name ASC"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String {
                    guard let p = sqlite3_column_text(stmt, i) else { return "" }
                    return String(cString: p)
                }
                rows.append(ModelRow(
                    id: text(0),
                    name: text(1),
                    family: text(2),
                    backend: text(3),
                    weightsPath: text(4),
                    available: sqlite3_column_int(stmt, 5) == 1,
                    reason: text(6)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return rows
    }

    private func _fetchQueueJobs() -> [QueueJobItem] {
        var jobs = [QueueJobItem]()
        let q = """
            SELECT id, batch_id, status, position, seed, caption, params, model_id, error
            FROM jobs WHERE status IN ('queued','running','error')
            ORDER BY CASE status WHEN 'running' THEN 0 WHEN 'queued' THEN 1 ELSE 2 END,
                     position ASC, id DESC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String {
                    guard let p = sqlite3_column_text(stmt, i) else { return "" }
                    return String(cString: p)
                }
                let jid = Int(sqlite3_column_int(stmt, 0))
                func optText(_ i: Int32) -> String? {
                    guard sqlite3_column_type(stmt, i) != SQLITE_NULL,
                          let value = sqlite3_column_text(stmt, i) else { return nil }
                    return String(cString: value)
                }
                let batchId = text(1)
                let status = text(2)
                let pos = Int(sqlite3_column_int(stmt, 3))
                let seed = Int(sqlite3_column_int64(stmt, 4))
                let cap = text(5)
                let paramsJson = text(6)
                let model = text(7)

                var dur = 40.0
                var steps = 30
                var fmt = "mp3"
                if let d = paramsJson.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    dur = obj["duration"] as? Double ?? 40.0
                    steps = obj["steps"] as? Int ?? 30
                    fmt = obj["format"] as? String ?? "mp3"
                }

                let title = cap.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).first ?? "Queued Song"

                jobs.append(QueueJobItem(
                    id: jid,
                    batchId: batchId,
                    status: status,
                    position: pos,
                    seed: seed,
                    duration: dur,
                    steps: steps,
                    format: fmt,
                    title: String(title.prefix(60)),
                    modelId: model,
                    model: model.components(separatedBy: ":").last ?? model,
                    error: optText(8)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return jobs
    }

    private func _cancelJob(id: Int) {
        let q = "UPDATE jobs SET status='cancelled', finished_at=COALESCE(finished_at, ?) WHERE id=? AND status IN ('queued','running','error')"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
            sqlite3_bind_int(stmt, 2, Int32(id))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        logDb(.info, "Cancelled job #\(id)", "job_id=\(id)")
    }
    private func _deleteGeneration(id: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM generations WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        logDb(.info, "Deleted generation #\(id)", "id=\(id)")
    }

    private func _dismissFailedJobs() {
        sqlite3_exec(db, "UPDATE jobs SET status='cancelled' WHERE status='error';", nil, nil, nil)
        logDb(.info, "Dismissed failed jobs", "")
    }

    private func _clearQueue() {
        sqlite3_exec(db, "UPDATE jobs SET status='cancelled', finished_at=strftime('%s', 'now') WHERE status IN ('queued','running','error');", nil, nil, nil)
        logDb(.info, "Cleared pending queue", "")
    }

    private func _requeueRunningJobs() {
        sqlite3_exec(db, "UPDATE jobs SET status='queued', started_at=NULL, progress=0.0 WHERE status='running';", nil, nil, nil)
        logDb(.info, "Requeued interrupted jobs", "")
    }

    private func _fetchLyrics(forPromptId pidStr: String?) -> [LyricSet] {
        var results = [LyricSet]()
        let query: String
        if let pidStr = pidStr, let pid = Int(pidStr) {
            query = """
                SELECT l.id, l.title, l.structure, l.body, l.language, l.genre_affinity, l.is_user
                FROM lyrics l
                JOIN prompt_lyrics pl ON pl.lyric_id = l.id
                WHERE pl.prompt_id = \(pid)
                UNION
                SELECT id, title, structure, body, language, genre_affinity, is_user
                FROM lyrics
                WHERE is_user = 1
                ORDER BY is_user DESC, id ASC
            """
        } else {
            query = "SELECT id, title, structure, body, language, genre_affinity, is_user FROM lyrics ORDER BY is_user DESC, id ASC"
        }

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String {
                    guard let p = sqlite3_column_text(stmt, i) else { return "" }
                    return String(cString: p)
                }
                let lid = Int(sqlite3_column_int(stmt, 0))
                let title = text(1)
                let structDesc = text(2)
                let body = text(3)
                let lang = text(4)
                let genreAffinity = text(5)
                let isUser = sqlite3_column_int(stmt, 6) != 0
                results.append(LyricSet(
                    id: lid,
                    title: title,
                    structure: structDesc,
                    body: body,
                    language: lang,
                    genre_affinity: genreAffinity,
                    is_user: isUser
                ))
            }
        }
        sqlite3_finalize(stmt)
        logDb(.debug, "Fetched lyric sets", "count=\(results.count) prompt_id=\(pidStr ?? "all")")
        return results
    }

    private func _saveLyricSet(title: String, body: String, structure: String, promptId: String?) -> Int {
        var stmt: OpaquePointer?
        let now = Date().timeIntervalSince1970
        let ins = "INSERT INTO lyrics (title, structure, body, language, genre_affinity, is_user, created_at, updated_at) VALUES (?, ?, ?, 'english', '', 1, ?, ?)"
        var newId = 0
        if sqlite3_prepare_v2(db, ins, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (structure as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (body as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 4, now)
            sqlite3_bind_double(stmt, 5, now)
            if sqlite3_step(stmt) == SQLITE_DONE {
                newId = Int(sqlite3_last_insert_rowid(db))
            }
        }
        sqlite3_finalize(stmt)

        if newId > 0, let pStr = promptId, let pid = Int(pStr) {
            var linkStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO prompt_lyrics (prompt_id, lyric_id) VALUES (?, ?)", -1, &linkStmt, nil) == SQLITE_OK {
                sqlite3_bind_int(linkStmt, 1, Int32(pid))
                sqlite3_bind_int(linkStmt, 2, Int32(newId))
                sqlite3_step(linkStmt)
            }
            sqlite3_finalize(linkStmt)
        }
        logDb(.info, "Saved user lyric set #\(newId)", "title=\(title)")
        return newId
    }

    private func _deleteLyricSet(id: Int) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM lyrics WHERE id = ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(id))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        logDb(.info, "Deleted lyric set #\(id)", "id=\(id)")
    }
    private func _saveTemplate(
        title: String,
        genre: String,
        subgenre: String,
        bpm: Int?,
        key: String?,
        scale: String?,
        vocal: String,
        time_signature: String,
        vocal_register: String?,
        language: String,
        pro_tip: String,
        caption: String,
        moods: [String],
        instruments: [String],
        tags: [String]
    ) -> Int {
        let now = Date().timeIntervalSince1970
        let cleanTitle = title.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "_")
        let slug = "user_\(cleanTitle.isEmpty ? "preset" : cleanTitle)_\(Int(now))"

        let ins = """
            INSERT INTO prompts (
                slug, title, genre, subgenre, source, format, bpm, music_key, scale, vocal, pro_tip,
                is_user, is_favorite, created_at, updated_at, time_signature, vocal_register, mood_arc, core_palette, language
            ) VALUES (?, ?, ?, ?, 'User', 'adapted', ?, ?, ?, ?, ?, 1, 0, ?, ?, ?, ?, NULL, NULL, ?)
        """

        var stmt: OpaquePointer?
        var newId = 0
        if sqlite3_prepare_v2(db, ins, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (slug as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (genre as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (subgenre as NSString).utf8String, -1, nil)

            if let bpm = bpm {
                sqlite3_bind_int(stmt, 5, Int32(bpm))
            } else {
                sqlite3_bind_null(stmt, 5)
            }

            if let key = key, !key.isEmpty {
                sqlite3_bind_text(stmt, 6, (key as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 6)
            }

            if let scale = scale, !scale.isEmpty {
                sqlite3_bind_text(stmt, 7, (scale as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 7)
            }

            sqlite3_bind_text(stmt, 8, (vocal as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 9, (pro_tip as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 10, now)
            sqlite3_bind_double(stmt, 11, now)
            sqlite3_bind_text(stmt, 12, (time_signature.isEmpty ? "4/4" : time_signature as NSString).utf8String, -1, nil)

            if let vr = vocal_register, !vr.isEmpty {
                sqlite3_bind_text(stmt, 13, (vr as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 13)
            }

            sqlite3_bind_text(stmt, 14, (language.isEmpty ? "english" : language as NSString).utf8String, -1, nil)

            if sqlite3_step(stmt) == SQLITE_DONE {
                newId = Int(sqlite3_last_insert_rowid(db))
            }
        }
        sqlite3_finalize(stmt)

        guard newId > 0 else {
            logDb(.error, "Failed to insert template '\(title)'")
            return 0
        }

        var segStmt: OpaquePointer?
        let segIns = "INSERT INTO prompt_segments (prompt_id, section, field, ordinal, content, enabled) VALUES (?, 'raw', 'flat', 0, ?, 1)"
        if sqlite3_prepare_v2(db, segIns, -1, &segStmt, nil) == SQLITE_OK {
            sqlite3_bind_int(segStmt, 1, Int32(newId))
            sqlite3_bind_text(segStmt, 2, (caption as NSString).utf8String, -1, nil)
            sqlite3_step(segStmt)
        }
        sqlite3_finalize(segStmt)

        let kwItems: [(String, String)] = moods.map { ($0, "mood") } +
                                          instruments.map { ($0, "instrument") } +
                                          tags.map { ($0, "tag") }

        for (rawTerm, kind) in kwItems {
            let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !term.isEmpty else { continue }

            var kwInsStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO keywords (term, kind, uses) VALUES (?, ?, 1)", -1, &kwInsStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(kwInsStmt, 1, (term as NSString).utf8String, -1, nil)
                sqlite3_bind_text(kwInsStmt, 2, (kind as NSString).utf8String, -1, nil)
                sqlite3_step(kwInsStmt)
            }
            sqlite3_finalize(kwInsStmt)

            var kwIdStmt: OpaquePointer?
            var kwId = 0
            if sqlite3_prepare_v2(db, "SELECT id FROM keywords WHERE term = ?", -1, &kwIdStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(kwIdStmt, 1, (term as NSString).utf8String, -1, nil)
                if sqlite3_step(kwIdStmt) == SQLITE_ROW {
                    kwId = Int(sqlite3_column_int(kwIdStmt, 0))
                }
            }
            sqlite3_finalize(kwIdStmt)

            if kwId > 0 {
                var linkStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO prompt_keywords (prompt_id, keyword_id) VALUES (?, ?)", -1, &linkStmt, nil) == SQLITE_OK {
                    sqlite3_bind_int(linkStmt, 1, Int32(newId))
                    sqlite3_bind_int(linkStmt, 2, Int32(kwId))
                    sqlite3_step(linkStmt)
                }
                sqlite3_finalize(linkStmt)
            }
        }

        logDb(.info, "Saved prompt template #\(newId)", "slug=\(slug) title=\(title)")
        return newId
    }

    private func _deleteTemplate(id: Int) {
        var stmt1: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM prompt_segments WHERE prompt_id = ?", -1, &stmt1, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt1, 1, Int32(id))
            sqlite3_step(stmt1)
        }
        sqlite3_finalize(stmt1)

        var stmt2: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM prompt_keywords WHERE prompt_id = ?", -1, &stmt2, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt2, 1, Int32(id))
            sqlite3_step(stmt2)
        }
        sqlite3_finalize(stmt2)

        var stmt3: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM prompt_lyrics WHERE prompt_id = ?", -1, &stmt3, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt3, 1, Int32(id))
            sqlite3_step(stmt3)
        }
        sqlite3_finalize(stmt3)

        var stmt4: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM prompts WHERE id = ?", -1, &stmt4, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt4, 1, Int32(id))
            sqlite3_step(stmt4)
        }
        sqlite3_finalize(stmt4)

        logDb(.info, "Deleted prompt template #\(id)", "id=\(id)")
    }
}
