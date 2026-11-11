import Foundation
import Network

/// Loopback TCP writer that carries interleaved int16 PCM from the AudioEngine tap to
/// the `netaudio.py` feed socket. The audio render thread must never block, so writes
/// are enqueued onto a dedicated serial queue and a bounded backlog is dropped rather
/// than stalling the tap if the receiver (and therefore the socket drain) falls behind.
public final class PCMFeed: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ai.opencode.musicstudio.pcmfeed")
    private var connection: NWConnection?
    private var connected = false

    /// Bound on bytes queued but not yet handed to the socket. ~1s of 48k stereo int16
    /// (~192 KB). Beyond this we drop the oldest audio to protect the render thread.
    private let maxBacklog = 192_000
    private var backlog = 0

    public init() {}

    /// Open a connection to the sidecar's feed port on loopback.
    public func connect(port: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.cancel()
            self.connected = false
            self.backlog = 0
            guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
            let conn = NWConnection(host: "127.0.0.1", port: nwPort, using: .tcp)
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                self.queue.async {
                    switch state {
                    case .ready: self.connected = true
                    case .failed, .cancelled: self.connected = false
                    default: break
                    }
                }
            }
            self.connection = conn
            conn.start(queue: self.queue)
        }
    }

    /// Enqueue PCM for sending. Safe to call from the audio tap thread.
    public func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, self.connected, let conn = self.connection else { return }
            if self.backlog >= self.maxBacklog {
                // Receiver can't keep up; drop this frame rather than block upstream.
                return
            }
            self.backlog += data.count
            conn.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.queue.async { self?.backlog -= data.count }
            })
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.connection?.cancel()
            self.connection = nil
            self.connected = false
            self.backlog = 0
        }
    }
}
