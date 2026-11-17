import CoreGraphics
import Foundation

/// WindowServer may reject otherwise valid modes while the console is locked,
/// asleep or owned by another user. Those failures say nothing about support.
struct DisplayConfigurationAvailability {
    let onConsole: Bool
    let screenLocked: Bool
    let displayAsleep: Bool

    var canConfigure: Bool { onConsole && !screenLocked && !displayAsleep }

    static var current: Self {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        return Self(onConsole: info?[kCGSessionOnConsoleKey as String] as? Bool ?? true,
                    screenLocked: info?["CGSSessionScreenIsLocked"] as? Bool ?? false,
                    displayAsleep: CGDisplayIsAsleep(CGMainDisplayID()) != 0)
    }
}

/// Bound genuine mode failures, but give a resumed console a fresh attempt.
struct DisplayModeRetry {
    static let failureLimit = 5
    static let retryInterval: TimeInterval = 30
    private(set) var failures = 0
    private(set) var retryAfter = Date.distantPast

    mutating func reset() {
        failures = 0
        retryAfter = .distantPast
    }

    /// False means the attempt crossed a lock/sleep boundary and was deferred.
    @discardableResult
    mutating func failed(canConfigure: Bool, now: Date = Date()) -> Bool {
        guard canConfigure else { reset(); return false }
        failures += 1
        if failures >= Self.failureLimit {
            retryAfter = now.addingTimeInterval(Self.retryInterval)
        }
        return true
    }
}

/// A fallback belongs to one interactive-console period, not the whole life
/// of a receiver session. Access is serialized by the sender's pipeline lock.
struct RefusedDisplayModes {
    private var modes: Set<VirtualCanvasSize> = []
    private var wasAvailable: Bool?

    func contains(_ mode: VirtualCanvasSize) -> Bool { modes.contains(mode) }

    /// Returns true when an old fallback was discarded on wake/unlock.
    @discardableResult
    mutating func observeConsole(available: Bool) -> Bool {
        let resumed = wasAvailable == false && available
        wasAvailable = available
        return resumed ? reset() : false
    }

    mutating func insert(_ mode: VirtualCanvasSize, canConfigure: Bool) -> Bool {
        observeConsole(available: canConfigure)
        guard canConfigure else { return false }
        return modes.insert(mode).inserted
    }

    /// A manual choice also requests a fresh attempt, even for the same preset.
    @discardableResult
    mutating func reset() -> Bool {
        let hadModes = !modes.isEmpty
        modes.removeAll()
        return hadModes
    }
}
