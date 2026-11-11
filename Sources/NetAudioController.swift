import Foundation
import Combine

/// A network audio receiver discovered by the `netaudio.py` sidecar.
///
/// `available` means discovered and reachable; per the compatibility requirement it
/// does NOT by itself establish that streaming will succeed — that is only known once
/// `select` connects and the backend validates playback.
public struct NetReceiver: Identifiable, Equatable, Codable, Sendable {
    public let id: String            // e.g. "airplay:<pi>", "cast:<uuid>", "dlna:<udn>"
    public let name: String
    public let model: String?
    public let `protocol`: String    // "airplay" | "dlna" | "cast"
    public let protocolLabel: String // "AirPlay" | "DLNA" | "Google Cast"
    public let host: String?
    public let available: Bool
    public let volume: Double?
    public let volumeSupported: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, model, host, available, volume
        case `protocol`
        case protocolLabel = "protocol_label"
        case volumeSupported = "volume_supported"
    }
}

/// State of the active output session, mirrored from the sidecar's `status` events.
public enum NetAudioState: String, Sendable {
    case idle
    case connecting
    case streaming
    case paused
    case reconnecting
    case stopped
    case error
}

/// Owns the long-lived `netaudio.py` sidecar: spawns it, sends JSON commands on stdin,
/// and parses JSON-line events on stdout. All networking (discovery, streaming,
/// reconnection) happens in the sidecar off the UI thread; this controller only holds
/// the published state the UI binds to and forwards PCM tap frames to the feed socket.
@MainActor
public final class NetAudioController: ObservableObject {

    // MARK: - Published UI state
    @Published public private(set) var receivers: [NetReceiver] = []
    @Published public private(set) var state: NetAudioState = .idle
    @Published public private(set) var statusDetail: String = ""
    @Published public private(set) var activeReceiverID: String? = nil
    @Published public private(set) var activeReceiverName: String? = nil
    @Published public private(set) var activeReceiverModel: String? = nil
    @Published public private(set) var activeProtocolLabel: String? = nil
    @Published public private(set) var activeHost: String? = nil
    @Published public private(set) var castingTitle: String = ""
    @Published public private(set) var activeVolume: Double = 0.5
    @Published public private(set) var isDiscovering: Bool = false
    @Published public private(set) var lastError: String? = nil
    @Published public private(set) var isRunning: Bool = false
    // Live transfer stats (point 5): throughput + progress of the file being streamed.
    @Published public private(set) var bytesPerSec: Int = 0
    @Published public private(set) var bytesSent: Int = 0
    @Published public private(set) var totalBytes: Int = 0
    @Published public private(set) var streamPercent: Double = 0

    /// Persisted selection and scan range.
    @Published public var savedReceiverID: String? {
        didSet { UserDefaults.standard.set(savedReceiverID, forKey: Self.kSavedReceiver) }
    }
    @Published public var scanRanges: String {
        didSet { UserDefaults.standard.set(scanRanges, forKey: Self.kScanRanges) }
    }

    static let kSavedReceiver = "netAudioSavedReceiver"
    static let kScanRanges = "netAudioScanRanges"

    // MARK: - Process plumbing
    private let pythonBin: String
    private let scriptPath: String
    private let homePath: String
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stdoutBuffer = Data()

    /// Loopback endpoints announced by the sidecar's `ready` event.
    public private(set) var feedPort: Int = 0
    public private(set) var streamPort: Int = 0

    /// Bridges the AudioEngine tap to the sidecar's PCM feed socket.
    private let feed = PCMFeed()

    private var logHandler: ((LogComponent, LogLevel, String, String) -> Void)?

    public init(pythonBin: String, scriptPath: String, homePath: String) {
        self.pythonBin = pythonBin
        self.scriptPath = scriptPath
        self.homePath = homePath
        self.scanRanges = UserDefaults.standard.string(forKey: Self.kScanRanges) ?? ""
        self.savedReceiverID = UserDefaults.standard.string(forKey: Self.kSavedReceiver)
    }

    /// Route sidecar log events into the app console.
    public func setLogHandler(_ handler: @escaping (LogComponent, LogLevel, String, String) -> Void) {
        self.logHandler = handler
    }

    // MARK: - Lifecycle

    /// Start the sidecar if it isn't already running. Idempotent.
    public func start() {
        guard process == nil else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonBin)
        task.arguments = [scriptPath, "netaudio"]

        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        env["MUSICSTUDIO_HOME"] = homePath
        task.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        task.standardInput = inPipe
        task.standardOutput = outPipe
        // Keep stderr off our JSON channel; send it to the app's stderr for debugging.
        task.standardError = FileHandle.standardError

        let outHandle = outPipe.fileHandleForReading
        outHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.ingest(data) }
        }

        task.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                outHandle.readabilityHandler = nil
                self.process = nil
                self.stdinPipe = nil
                self.stdoutPipe = nil
                self.isRunning = false
                self.feed.stop()
                if self.state == .streaming || self.state == .connecting {
                    self.state = .error
                    self.statusDetail = "Network audio service stopped unexpectedly"
                }
            }
        }

        self.process = task
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        do {
            try task.run()
            self.isRunning = true
            log(.info, "Network audio service started")
        } catch {
            self.process = nil
            self.isRunning = false
            self.lastError = error.localizedDescription
            log(.error, "Failed to start network audio service", error.localizedDescription)
        }
    }

    /// Spawn the sidecar and begin discovery at app launch. The sidecar runs in its
    /// own process with an asyncio loop entirely off the UI thread, and discovery is a
    /// background task there, so this never blocks the app. Safe to call once on init.
    public func autoStart() {
        start()
        discover()
    }

    /// Stop streaming and terminate the sidecar.
    public func shutdown() {
        guard process != nil else { return }
        send(["cmd": "shutdown"])
        feed.stop()
        // Give the sidecar a moment to release receivers, then hard-stop.
        let proc = process
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if proc?.isRunning == true { proc?.terminate() }
        }
    }

    // MARK: - Commands

    public func discover() {
        start()
        isDiscovering = true
        lastError = nil
        var cmd: [String: Any] = ["cmd": "discover", "timeout": 10.0]
        let ranges = scanRanges.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ranges.isEmpty { cmd["ranges"] = ranges }
        send(cmd)
    }

    /// Connect to a receiver and begin playing a file in one step (so the receiver
    /// starts exactly one stream with the content, avoiding the play->stop->restart on
    /// first select). Saves the receiver as the preferred output.
    public func select(_ receiver: NetReceiver, path: String? = nil, title: String = "") {
        start()
        savedReceiverID = receiver.id
        var cmd: [String: Any] = ["cmd": "select", "id": receiver.id]
        if let path { cmd["path"] = path; cmd["title"] = title }
        send(cmd)
    }

    public func selectSaved() {
        guard let id = savedReceiverID,
              let r = receivers.first(where: { $0.id == id }) else { return }
        select(r)
    }

    /// Select a receiver for LIVE processed-PCM streaming (no file). The engine's tap
    /// feeds the sidecar's bounded buffer, which the receiver pulls continuously. The
    /// feed format must already be configured (via configureFeed) before this call.
    public func selectLive(_ receiver: NetReceiver, title: String = "") {
        start()
        savedReceiverID = receiver.id
        // Clear any file so the sidecar serves the live tap stream, and announce the
        // title for the player/device metadata.
        send(["cmd": "play_file", "path": NSNull(), "title": title])
        send(["cmd": "select", "id": receiver.id, "title": title])
    }

    /// Change the track on the already-active receiver (full-rate file streaming).
    public func playFile(path: String, title: String) {
        start()
        send(["cmd": "play_file", "path": path, "title": title])
    }

    /// Seek the remote session. For a live tap stream, there is no seekable media on
    /// the receiver; seeking is performed by the engine (moving the tapped PCM), and we
    /// tell the sidecar to flush its bounded buffer and restart the receiver session so
    /// no stale pre-seek audio keeps playing. `completion` fires when the sidecar
    /// acknowledges (command round-trip, not speaker output).
    public func seek(to position: Double, completion: (() -> Void)? = nil) {
        let token = (pendingSeekToken &+ 1)
        pendingSeekToken = token
        if let completion { seekCompletions[token] = completion }
        send(["cmd": "seek", "position": position, "token": token])
    }

    private var pendingSeekToken = 0
    private var seekCompletions: [Int: () -> Void] = [:]

    /// pause / resume / stop the remote session.
    public func transport(_ action: String) {
        send(["cmd": "transport", "action": action])
    }

    /// Update the casting metadata title (e.g. when the track changes mid-session)
    /// without restarting the receiver stream.
    public func setTitle(_ title: String) {
        send(["cmd": "set_title", "title": title])
    }

    public func stop() {
        send(["cmd": "stop"])
        feed.stop()
    }

    public func setVolume(_ level: Double) {
        activeVolume = min(1, max(0, level))
        send(["cmd": "set_volume", "level": activeVolume])
    }

    public func setScanRanges(_ ranges: String) {
        scanRanges = ranges
        send(["cmd": "scan_ranges", "ranges": ranges])
    }

    // MARK: - Audio tap bridge

    /// Announce the PCM format the AudioEngine tap will deliver, so the sidecar sizes
    /// its stream and WAV header correctly, then open the feed socket.
    public func configureFeed(sampleRate: Int, channels: Int) {
        pendingFeedFormat = (sampleRate, channels)
        ensureFeedFormat()
    }

    private var pendingFeedFormat: (sr: Int, ch: Int) = (48000, 2)

    private func ensureFeedFormat() {
        send(["cmd": "feed_format",
              "sample_rate": pendingFeedFormat.sr,
              "channels": pendingFeedFormat.ch,
              "bits": 16])
    }

    /// Forward one buffer of interleaved int16 PCM (little-endian) to the sidecar.
    /// Called from the AudioEngine tap. Non-blocking; drops frames if the socket is
    /// not connected yet rather than stalling the audio thread.
    public nonisolated func feedPCM(_ data: Data) {
        feed.write(data)
    }

    // MARK: - stdout parsing

    private func ingest(_ data: Data) {
        stdoutBuffer.append(data)
        // Split on newlines; keep any trailing partial line buffered.
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<nl)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...nl)
            guard !lineData.isEmpty else { continue }
            handleLine(lineData)
        }
    }

    private func handleLine(_ lineData: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let event = obj["event"] as? String else {
            // Not JSON — surface as a console line so nothing is silently lost.
            if let text = String(data: lineData, encoding: .utf8) {
                log(.debug, "netaudio: \(text)")
            }
            return
        }

        switch event {
        case "ready":
            if let fp = obj["feed_port"] as? Int { feedPort = fp }
            if let sp = obj["stream_port"] as? Int { streamPort = sp }
            if feedPort > 0 { feed.connect(port: feedPort) }

        case "receivers":
            if let arr = obj["receivers"] {
                let data = try? JSONSerialization.data(withJSONObject: arr)
                if let data,
                   let decoded = try? JSONDecoder().decode([NetReceiver].self, from: data) {
                    receivers = decoded
                }
            }
            isDiscovering = false

        case "status":
            if let s = obj["state"] as? String, let st = NetAudioState(rawValue: s) {
                state = st
            }
            activeReceiverID = obj["receiver_id"] as? String
            activeReceiverName = obj["receiver_name"] as? String
            activeReceiverModel = obj["receiver_model"] as? String
            activeProtocolLabel = obj["protocol_label"] as? String
            activeHost = obj["host"] as? String
            castingTitle = obj["title"] as? String ?? ""
            statusDetail = obj["detail"] as? String ?? ""
            if let v = obj["volume"] as? Double { activeVolume = v }

        case "stats":
            if let bps = obj["bytes_per_sec"] as? Int { bytesPerSec = bps }
            if let bs = obj["bytes_sent"] as? Int { bytesSent = bs }
            if let tb = obj["total_bytes"] as? Int { totalBytes = tb }
            if let p = obj["percent"] as? Double { streamPercent = p }

        case "seek_ack":
            // Fire the matching seek completion (latest-wins is enforced caller-side).
            if let token = obj["token"] as? Int, let done = seekCompletions[token] {
                seekCompletions.removeValue(forKey: token)
                done()
            }

        case "error":
            let msg = obj["message"] as? String ?? "Unknown network audio error"
            lastError = msg
            isDiscovering = false
            log(.error, msg)

        case "log":
            let msg = obj["message"] as? String ?? ""
            let detail = obj["detail"] as? String ?? ""
            let level = LogLevel.from(obj["level"] as? String)
            log(level, msg, detail)

        default:
            break
        }
    }

    // MARK: - helpers

    private func send(_ dict: [String: Any]) {
        guard let pipe = stdinPipe else { return }
        guard var data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        data.append(0x0A)
        do {
            try pipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            log(.warn, "Could not send command to network audio service", "\(error)")
        }
    }

    private func log(_ level: LogLevel, _ message: String, _ detail: String = "") {
        logHandler?(.netaudio, level, message, detail)
    }
}

private extension LogLevel {
    static func from(_ s: String?) -> LogLevel {
        switch s {
        case "trace": return .trace
        case "debug": return .debug
        case "warn": return .warn
        case "error": return .error
        default: return .info
        }
    }
}
