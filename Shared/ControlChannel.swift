import Foundation
import Network

/// Additive, session-scoped offer. The token binds a second socket to the
/// video session; it is not encryption or a replacement for device pairing.
struct ControlChannelOffer: Equatable {
    let port: UInt16
    let token: String

    init?(port: Int?, token: String?) {
        guard let port, (1...65535).contains(port), let token,
              UUID(uuidString: token) != nil else { return nil }
        self.port = UInt16(port)
        self.token = token
    }
}

/// A barrier travels on the old TCP stream after its last input event. Until
/// the Mac processes it and replies on the new socket, later events wait here.
/// An active socket failure reconnects the video session, never replays input.
struct ControlHandoff {
    enum Phase { case video, switching, dedicated }
    enum Destination { case video, dedicated, buffered, overflow }
    private(set) var phase: Phase = .video
    private var pending: [Data] = []
    private var pendingBytes = 0

    mutating func begin() { phase = .switching }

    mutating func route(_ data: Data) -> Destination {
        switch phase {
        case .video: return .video
        case .dedicated: return .dedicated
        case .switching:
            guard pending.count < 512, pendingBytes + data.count <= 262_144 else { return .overflow }
            pending.append(data)
            pendingBytes += data.count
            return .buffered
        }
    }

    mutating func activate() -> [Data] {
        guard phase == .switching else { return [] }
        phase = .dedicated
        let result = pending
        pending.removeAll()
        pendingBytes = 0
        return result
    }

    mutating func reset() { self = ControlHandoff() }
}

struct ControlFrameDecoder {
    static let maximumPayload = 65_536
    private var buffer = Data()
    enum Failure: Error { case invalidLength }

    static func frame(_ payload: Data) -> Data? {
        guard !payload.isEmpty, payload.count <= maximumPayload else { return nil }
        var length = UInt32(payload.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(payload)
        return frame
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var result: [Data] = []
        var consumed = 0
        while buffer.count - consumed >= 4 {
            let start = buffer.startIndex + consumed
            let length = buffer[start..<(start + 4)].withUnsafeBytes {
                Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)))
            }
            guard length > 0, length <= Self.maximumPayload else { throw Failure.invalidLength }
            guard buffer.count - consumed >= 4 + length else { break }
            result.append(Data(buffer[(start + 4)..<(start + 4 + length)]))
            consumed += 4 + length
        }
        buffer.removeFirst(consumed)
        return result
    }
}

/// Framing and socket I/O run independently of the video encode/decode queue.
/// Session state and input injection remain ordered on the owner's queue.
final class ControlSocket {
    private let connection: NWConnection
    private let io = DispatchQueue(label: "opendisplay.control", qos: .userInteractive)
    private let owner: DispatchQueue
    private let onMessage: (ControlSocket, Data) -> Void
    private let onEnd: (ControlSocket) -> Void
    private var decoder = ControlFrameDecoder()
    private var ended = false

    init(connection: NWConnection, owner: DispatchQueue,
         onMessage: @escaping (ControlSocket, Data) -> Void,
         onEnd: @escaping (ControlSocket) -> Void) {
        self.connection = connection
        self.owner = owner
        self.onMessage = onMessage
        self.onEnd = onEnd
    }

    func start(onReady: (() -> Void)? = nil) {
        io.async {
            self.connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.ended else { return }
                switch state {
                case .ready:
                    if let onReady { self.owner.async(execute: onReady) }
                    self.receive()
                case .failed, .waiting, .cancelled: self.finish()
                default: break
                }
            }
            self.connection.start(queue: self.io)
        }
    }

    func send(_ payload: Data) {
        guard let frame = ControlFrameDecoder.frame(payload) else { cancel(); return }
        io.async {
            guard !self.ended else { return }
            self.connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish() }
            })
        }
    }

    func sendJSON(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        send(data)
    }

    func cancel() { io.async { self.finish() } }

    private func finish() {
        guard !ended else { return }
        ended = true
        connection.cancel()
        owner.async { self.onEnd(self) }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.ended else { return }
            do {
                if let data {
                    for payload in try self.decoder.append(data) {
                        self.owner.async { self.onMessage(self, payload) }
                    }
                }
            } catch { self.finish(); return }
            if complete || error != nil { self.finish() }
            else { self.receive() }
        }
    }
}
