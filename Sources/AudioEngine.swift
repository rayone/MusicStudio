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
    private var effect: AVAudioUnit?
    private var file: AVAudioFile?

    /// Wall-clock mapping for progress: sample time of play start.
    private var startSampleTime: AVAudioFramePosition = 0
    public private(set) var isPlaying = false
    public private(set) var durationSeconds: Double = 0

    public init() {
        engine.attach(player)
    }

    // MARK: - Graph

    private func rebuildGraph() {
        // Disconnect everything, then wire player -> (effect?) -> mainMixer.
        engine.disconnectNodeOutput(player)
        if let effect { engine.disconnectNodeOutput(effect) }
        let fmt = file?.processingFormat
            ?? engine.mainMixerNode.outputFormat(forBus: 0)
        if let effect {
            engine.connect(player, to: effect, format: fmt)
            engine.connect(effect, to: engine.mainMixerNode, format: fmt)
        } else {
            engine.connect(player, to: engine.mainMixerNode, format: fmt)
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
        rebuildGraph()
        if file != nil {
            scheduleAndPlay(from: resumeAt)
            if !wasPlaying { player.pause(); isPlaying = false }
        }
    }

    public var currentEffect: AVAudioUnit? { effect }

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
