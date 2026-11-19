// Compiled into BOTH the Mac and iOS targets (see project.yml `sources`).
// Keep this Foundation-only so it stays platform-neutral.

import Foundation

/// The wire-protocol contract between the two apps, decoupled from the app's
/// marketing version. See COMPATIBILITY.md.
///
/// Bumped only when the wire changes, not every release, so UI-only releases
/// never trigger a compatibility event. A peer that advertises no version is
/// protocol 1 — that's every install in the field that predates the handshake.
enum WireProtocol {
    /// The protocol version this build speaks.
    static let version = 3

    /// Protocol version that introduced Apple Pencil / proximity wire messages.
    /// Peers below this get pencil input as legacy `touch` events.
    static let pencilWireVersion = 3

    /// Oldest peer protocol version this build still supports. Stays at 1
    /// (support everything) until a deliberate two-phase breaking change
    /// raises it — raising this is what turns "peer too old" into a hard gate.
    static let minSupportedPeer = 1

    /// A peer that advertises no `pv` is defined as protocol 1.
    static let assumedWhenAbsent = 1
}

/// Control-message `type` strings introduced with the handshake. The pre-
/// existing types (`hello`, `ping`, `pong`, `touch`, …) stay inline for now to
/// keep this change additive and low-risk; unify later if we do a wider pass.
enum WireMessage {
    static let welcome = "welcome"                  // Mac -> phone: Mac's pv + min supported
    static let updateRequired = "updateRequired"    // Mac -> phone: peer is below the Mac's floor
    static let sleeping = "sleeping"                // phone -> Mac: device locked, reconnect on wake
    static let closing = "closing"                  // phone -> Mac: app quit, end the session for good
    static let streamConfig = "streamConfig"        // Mac -> receiver: selected video operating point
    static let streamHandoff = "streamHandoff"      // Mac -> receiver: first message on a prepared video path
    static let power = "power"                      // Mac -> receiver: shut down (PROTOCOL.md 6.6)
}

/// A handoff marker precedes codec setup and video on the replacement socket.
/// A receiver uses the sender's previously announced ID to recognize the
/// same display pipeline. Ordinary reconnects need no marker.
enum StreamHandoff {
    static func leadingControlFrameSize(in bytes: Data) -> Int? {
        guard bytes.count >= 5, bytes[bytes.startIndex + 4] == UInt8(ascii: "{") else { return nil }
        let length = bytes.withUnsafeBytes { Int(UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))) }
        guard (1...512).contains(length) else { return nil }
        return length + 4
    }

    static func senderSession(in bytes: Data) -> UUID? {
        guard let size = leadingControlFrameSize(in: bytes), bytes.count >= size,
              let object = try? JSONSerialization.jsonObject(with: Data(bytes.prefix(size).dropFirst(4))) as? [String: Any],
              object["type"] as? String == WireMessage.streamHandoff,
              object["screenLocked"] as? Bool == false,
              let id = object["senderSession"] as? String else { return nil }
        return UUID(uuidString: id)
    }
}

/// What a `power` message asks the receiver to do (PROTOCOL.md 6.6). The
/// wire says what, each receiver platform decides how.
enum PowerAction: String, CaseIterable {
    case shutdown
}

/// One receiver-supported operating envelope. Every non-nil limit in an
/// entry applies together; multiple entries for the same codec are alternatives.
/// Codec names stay strings so older builds can ignore future codecs.
struct VideoCapability: Codable, Equatable {
    let codec: String
    let maxWidth: Int?
    let maxHeight: Int?
    let maxFrameRate: Int?
    let maxPixelsPerSecond: Int?

    init(codec: String, maxWidth: Int? = nil, maxHeight: Int? = nil,
         maxFrameRate: Int? = nil, maxPixelsPerSecond: Int? = nil) {
        self.codec = codec
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.maxFrameRate = maxFrameRate
        self.maxPixelsPerSecond = maxPixelsPerSecond
    }
}
