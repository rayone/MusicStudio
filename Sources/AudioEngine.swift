import Foundation
import AVFoundation
import AudioToolbox

/// Live playback graph: AVAudioPlayerNode -> [optional AU effect] -> mainMixer.
///
/// Replaces the old AVAudioPlayer so a loaded Audio Unit can be inserted as a live
/// node — moving a plugin knob is heard instantly on the playing track. VST3 plugins
/// cannot be hosted here (AVAudioEngine loads AU only); those use offline re-render.
@MainActor
public final class AudioEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Dedicated mixer between the effect and the main mixer. The network tap lives
    /// here so it captures full-level post-effect PCM regardless of the local speaker
    /// volume. (Verified: a tap on mainMixerNode is POST-volume, so muting the speaker
    /// there would also zero the network stream; a pre-mix tap node avoids that.)
    private let tapMixer = AVAudioMixerNode()
    private var effect: AVAudioUnit?
    private var file: AVAudioFile?

    /// Wall-clock mapping for progress: sample time of play start.
    private var startSampleTime: AVAudioFramePosition = 0
    public private(set) var isPlaying = false
    public private(set) var durationSeconds: Double = 0

    // MARK: - Network audio tap (processed-PCM sink)
    //
    // One engine, one plugin chain. The mixer tap captures the SAME post-effect PCM
    // that feeds the local speakers, so a network sink receives exactly what the Mac
    // would play (including live AU effects, or dry when bypassed). In network mode the
    // graph keeps rendering and only the local speaker branch is silenced
    // (mainMixer.outputVolume = 0), so switching Mac<->receiver mid-track preserves
    // position and plugin state.

    /// Called with interleaved little-endian int16 PCM for each tap buffer while a
    /// network output is active. Set by the view model to forward audio to the sidecar.
    private var tapHandler: ((Data) -> Void)?
    /// Converts the mixer's native float format to the int16 interleaved format the
    /// sidecar/receivers expect. Rebuilt whenever the tap format changes.
    private var tapConverter: AVAudioConverter?
    private var tapOutputFormat: AVAudioFormat?
    private var tapInstalled = false
    /// Preallocated int16 scratch so the audio callback copies into fixed memory
    /// rather than allocating per buffer. Sized for the largest expected tap buffer.
    private var tapScratch: UnsafeMutablePointer<Int16>?
    private var tapScratchCapacity = 0
    /// Whether the local speaker branch is muted (network-only output).
    public private(set) var localMuted = false
    /// The user's local output volume before muting, restored on switch-back.
    private var savedLocalVolume: Float = 1.0

    /// The format the network tap delivers: the tap mixer's sample rate, stereo, int16.
    public var tapFormat: (sampleRate: Int, channels: Int) {
        let sr = tapMixer.outputFormat(forBus: 0).sampleRate
        return (Int(sr > 0 ? sr : 48000), 2)
    }

    /// Silence (or restore) only the local speaker branch, downstream of the tap. The
    /// graph keeps rendering so the network tap keeps feeding audio; playback position
    /// and plugin state are untouched. Restores the user's previous volume on unmute.
    public func setLocalMuted(_ muted: Bool) {
        guard muted != localMuted else { return }
        if muted {
            savedLocalVolume = engine.mainMixerNode.outputVolume
            engine.mainMixerNode.outputVolume = 0.0
        } else {
            engine.mainMixerNode.outputVolume = savedLocalVolume
        }
        localMuted = muted
    }

    /// Start forwarding full-level post-effect PCM from the tap mixer to `handler` as
    /// int16 interleaved. Idempotent. Encoding and network I/O happen in `handler`
    /// (off this render callback).
    public func startNetworkTap(_ handler: @escaping (Data) -> Void) {
        self.tapHandler = handler
        guard !tapInstalled else { return }
        if !engine.isRunning { try? engine.start() }
        let inFormat = tapMixer.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: inFormat.sampleRate,
                                            channels: 2,
                                            interleaved: true) else { return }
        self.tapOutputFormat = outFormat
        self.tapConverter = AVAudioConverter(from: inFormat, to: outFormat)
        // Preallocate scratch for up to 8192 frames stereo int16.
        let cap = 8192 * 2
        tapScratch?.deallocate()
        tapScratch = UnsafeMutablePointer<Int16>.allocate(capacity: cap)
        tapScratchCapacity = cap
        tapMixer.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.forwardTapBuffer(buffer)
        }
        tapInstalled = true
    }

    /// Remove the network tap and restore local output.
    public func stopNetworkTap() {
        if tapInstalled {
            tapMixer.removeTap(onBus: 0)
            tapInstalled = false
        }
        tapHandler = nil
        tapConverter = nil
        tapOutputFormat = nil
        tapScratch?.deallocate()
        tapScratch = nil
        tapScratchCapacity = 0
        setLocalMuted(false)
    }

    private func forwardTapBuffer(_ input: AVAudioPCMBuffer) {
        guard let handler = tapHandler,
              let converter = tapConverter,
              let outFormat = tapOutputFormat else { return }
        let ratio = outFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat,
                                               frameCapacity: capacity) else { return }
        var error: NSError?
        let box = UncheckedSendableBox(input)
        var fed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return box.value
        }
        guard status != .error, outBuffer.frameLength > 0,
              let channelData = outBuffer.int16ChannelData else { return }
        let sampleCount = Int(outBuffer.frameLength) * Int(outFormat.channelCount)
        // Copy into preallocated scratch (no per-callback heap alloc), then wrap for the
        // handler. The handler enqueues onto its own queue and returns immediately, so
        // encoding and socket I/O never run on this render thread.
        let byteCount = sampleCount * MemoryLayout<Int16>.size
        if let scratch = tapScratch, sampleCount <= tapScratchCapacity {
            scratch.update(from: channelData[0], count: sampleCount)
            let data = Data(bytes: scratch, count: byteCount)
            handler(data)
        } else {
            let data = Data(bytes: channelData[0], count: byteCount)
            handler(data)
        }
    }

    /// Fixed format of tapMixer's output (= the network stream format). Connected once
    /// and never reconnected: reconnecting the tapped node at a new rate (e.g. on a
    /// track change from a 44.1 kHz to a 48 kHz file, or a plugin insert) silently
    /// invalidated the tap and the receiver went silent. The mixer resamples inputs.
    private var streamFormat: AVAudioFormat?

    public init() {
        engine.attach(player)
        engine.attach(tapMixer)
        tapMixer.outputVolume = 1.0
        let hwRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let fmt = AVAudioFormat(standardFormatWithSampleRate: hwRate > 0 ? hwRate : 48000,
                                channels: 2)!
        streamFormat = fmt
        engine.connect(tapMixer, to: engine.mainMixerNode, format: fmt)
    }

    // MARK: - Graph

    private func rebuildGraph() {
        // Permanent path for all playback (plugin enabled OR bypassed):
        //   player -> [effect] -> tapMixer -> mainMixer -> device
        // Only the nodes UPSTREAM of tapMixer are rewired here; tapMixer -> mainMixer
        // stays connected at the fixed stream format so an installed tap survives
        // track changes and plugin swaps.
        engine.disconnectNodeOutput(player)
        if let effect { engine.disconnectNodeOutput(effect) }
        // Source keeps its own rate/layout up to tapMixer, which converts to the stream
        // format.
        let fmt = file?.processingFormat ?? streamFormat
        if let effect {
            engine.connect(player, to: effect, format: fmt)
            engine.connect(effect, to: tapMixer, format: fmt)
        } else {
            engine.connect(player, to: tapMixer, format: fmt)
        }
    }

    // MARK: - Transport

    /// Load a file and start playback from the given offset (seconds).
    public func load(path: String, startAt offset: Double = 0) throws {
        stop()
        let url = URL(fileURLWithPath: path)
        let f = try AVAudioFile(forReading: url)
        self.file = f
        self.durationSeconds = Double(f.length) / f.processingFormat.sampleRate
        rebuildGraph()
        if !engine.isRunning { try engine.start() }
        scheduleAndPlay(from: offset)
    }

    private func scheduleAndPlay(from offset: Double) {
        guard let f = file else { return }
        let sr = f.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, offset) * sr)
        let remaining = f.length - startFrame
        guard remaining > 0 else { return }
        player.stop()
        player.scheduleSegment(f, startingFrame: startFrame,
                               frameCount: AVAudioFrameCount(remaining), at: nil)
        startSampleTime = startFrame
        player.play()
        isPlaying = true
    }

    public func pause() {
        player.pause()
        isPlaying = false
    }

    public func resume() {
        guard file != nil else { return }
        if !engine.isRunning { try? engine.start() }
        player.play()
        isPlaying = true
    }

    public func stop() {
        player.stop()
        isPlaying = false
        file = nil
        durationSeconds = 0
    }

    /// Current playback position in seconds (0 when stopped).
    public var currentTime: Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              let f = file else { return 0 }
        let base = Double(startSampleTime) / f.processingFormat.sampleRate
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        return min(base + max(0, elapsed), durationSeconds)
    }

    public func seek(to seconds: Double) {
        let wasPlaying = isPlaying
        scheduleAndPlay(from: seconds)
        if !wasPlaying { player.pause(); isPlaying = false }
    }

    // MARK: - Live AU effect

    /// Insert (or replace) a live Audio Unit effect in the chain. Returns the node so
    /// callers can present its view / set parameters. Throws if the component can't load.
    public func insertAudioUnit(description: AudioComponentDescription,
                                completion: @escaping (Result<AVAudioUnit, Error>) -> Void) {
        AVAudioUnit.instantiate(with: description,
                                options: []) { [weak self] avAudioUnit, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { completion(.failure(error)); return }
                guard let au = avAudioUnit else {
                    completion(.failure(NSError(domain: "AudioEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio Unit returned nil"])))
                    return
                }
                self.swapEffect(au)
                completion(.success(au))
            }
        }
    }

    private func swapEffect(_ au: AVAudioUnit) {
        let resumeAt = currentTime
        let wasPlaying = isPlaying
        removeParameterObserver()
        if let old = effect {
            engine.disconnectNodeOutput(old)
            engine.detach(old)
        }
        engine.attach(au)
        effect = au
        effectBypassed = false
        rebuildGraph()
        // Re-schedule from the current position so the new node is in the live path.
        if file != nil {
            scheduleAndPlay(from: resumeAt)
            if !wasPlaying { player.pause(); isPlaying = false }
        }
    }

    /// Remove the live effect, returning to dry playback.
    public func removeEffect() {
        guard let old = effect else { return }
        removeParameterObserver()
        let resumeAt = currentTime
        let wasPlaying = isPlaying
        engine.disconnectNodeOutput(old)
        engine.detach(old)
        effect = nil
        effectBypassed = false
        rebuildGraph()
        if file != nil {
            scheduleAndPlay(from: resumeAt)
            if !wasPlaying { player.pause(); isPlaying = false }
        }
    }

    public var currentEffect: AVAudioUnit? { effect }

    /// Whether the live effect is currently bypassed.
    public private(set) var effectBypassed = false

    /// Toggle the live AU's processing on/off WITHOUT touching the graph or the
    /// playhead. Uses the AU's `shouldBypassEffect`, so audio keeps flowing (dry when
    /// bypassed, wet when active), the position keeps advancing, and a network session
    /// stays connected while the streamed audio changes.
    public func setEffectBypassed(_ bypassed: Bool) {
        guard let au = effect else { return }
        au.auAudioUnit.shouldBypassEffect = bypassed
        effectBypassed = bypassed
    }

    // MARK: - AU-native parameters
    // The live AU is the source of truth for its own parameters (names/ranges differ
    // from the plugin's VST3 schema), so read/write them directly off its parameterTree.

    /// Snapshot of the live AU's parameters, keyed by stable address.
    public func effectParameters() -> [(address: UInt64, identifier: String, name: String,
                                        value: Double, min: Double, max: Double)] {
        guard let tree = effect?.auAudioUnit.parameterTree else { return [] }
        return tree.allParameters.map { p in
            (p.address, p.identifier, p.displayName, Double(p.value),
             Double(p.minValue), Double(p.maxValue))
        }
    }

    private var observerToken: AUParameterObserverToken?

    /// Set one live AU parameter by address — takes effect immediately on the playing audio.
    public func setEffectParameter(address: UInt64, value: Double) {
        guard let tree = effect?.auAudioUnit.parameterTree,
              let param = tree.parameter(withAddress: address) else { return }
        let v = AUValue(value)
        if let token = observerToken {
            param.setValue(v, originator: token)   // don't echo our own change back
        } else {
            param.value = v
        }
    }

    /// Report parameter changes made outside the app (the plugin's own window, automation),
    /// so the inspector stays in sync with what the plugin is actually doing.
    public func observeEffectParameters(_ handler: @escaping @MainActor (UInt64, Double) -> Void) {
        removeParameterObserver()
        guard let tree = effect?.auAudioUnit.parameterTree else { return }
        observerToken = tree.token(byAddingParameterObserver: { address, value in
            DispatchQueue.main.async { handler(address, Double(value)) }
        })
    }

    private func removeParameterObserver() {
        if let token = observerToken {
            effect?.auAudioUnit.parameterTree?.removeParameterObserver(token)
        }
        observerToken = nil
    }

    // MARK: - Offline render (save AU-processed audio)

    /// Render `inputPath` through a fresh copy of `component` at the given parameter
    /// values (address -> value), writing a WAV to `outputPath`. Runs off the live graph
    /// via manual rendering so playback is undisturbed. Calls back on the main actor.
    public static func renderOffline(inputPath: String,
                                     outputPath: String,
                                     description: AudioComponentDescription,
                                     parameters: [UInt64: Double],
                                     completion: @escaping (Result<String, Error>) -> Void) {
        func fail(_ msg: String) {
            DispatchQueue.main.async {
                completion(.failure(NSError(domain: "AudioEngine.renderOffline", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: msg])))
            }
        }
        AVAudioUnit.instantiate(with: description, options: []) { au, err in
            guard let au else { fail(err?.localizedDescription ?? "AU load failed"); return }
            do {
                let inFile = try AVAudioFile(forReading: URL(fileURLWithPath: inputPath))
                let fmt = inFile.processingFormat
                let engine = AVAudioEngine()
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.attach(au)
                engine.connect(player, to: au, format: fmt)
                engine.connect(au, to: engine.mainMixerNode, format: fmt)

                // Apply parameter values before rendering.
                if let tree = au.auAudioUnit.parameterTree {
                    for (addr, val) in parameters {
                        tree.parameter(withAddress: addr)?.value = AUValue(val)
                    }
                }

                let block = AVAudioFrameCount(4096)
                try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
                try engine.start()
                player.scheduleFile(inFile, at: nil)
                try player.play()

                let outFile = try AVAudioFile(
                    forWriting: URL(fileURLWithPath: outputPath),
                    settings: fmt.settings,
                    commonFormat: fmt.commonFormat,
                    interleaved: fmt.isInterleaved)
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: engine.manualRenderingFormat,
                    frameCapacity: engine.manualRenderingMaximumFrameCount) else {
                    fail("Could not allocate render buffer"); return
                }
                // Render fully into memory first so we can peak-normalize before writing:
                // wideners/EQs can push samples past 0 dBFS, which would clip on playback.
                var chunks: [AVAudioPCMBuffer] = []
                var peak: Float = 0
                let total = inFile.length
                while engine.manualRenderingSampleTime < total {
                    let remaining = total - engine.manualRenderingSampleTime
                    let toRender = min(AVAudioFramePosition(buffer.frameCapacity), remaining)
                    let status = try engine.renderOffline(AVAudioFrameCount(toRender), to: buffer)
                    switch status {
                    case .success:
                        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                                          frameCapacity: buffer.frameLength),
                              let srcData = buffer.floatChannelData,
                              let dstData = copy.floatChannelData else { continue }
                        copy.frameLength = buffer.frameLength
                        let n = Int(buffer.frameLength)
                        for ch in 0..<Int(buffer.format.channelCount) {
                            dstData[ch].update(from: srcData[ch], count: n)
                            for i in 0..<n { peak = max(peak, abs(srcData[ch][i])) }
                        }
                        chunks.append(copy)
                    case .insufficientDataFromInputNode: break
                    case .cannotDoInCurrentContext, .error: throw NSError(
                        domain: "AudioEngine.renderOffline", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Render status \(status.rawValue)"])
                    @unknown default: break
                    }
                }
                let ceiling: Float = 0.98   // ~-0.2 dBFS headroom
                let gain: Float = peak > ceiling ? ceiling / peak : 1
                for chunk in chunks {
                    if gain < 1, let data = chunk.floatChannelData {
                        let n = Int(chunk.frameLength)
                        for ch in 0..<Int(chunk.format.channelCount) {
                            for i in 0..<n { data[ch][i] *= gain }
                        }
                    }
                    try outFile.write(from: chunk)
                }
                player.stop(); engine.stop()
                DispatchQueue.main.async { completion(.success(outputPath)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}

/// Transfers a non-Sendable value through a @Sendable boundary where the programmer
/// has verified the access is actually single-threaded (here: the AVAudioConverter
/// input block runs synchronously on the calling thread).
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
