import Foundation

/// Control-channel heartbeats must not hide a video socket that has stopped
/// processing sends. A static desktop with no pending video is healthy.
enum VideoDeliveryWatchdog {
    static func shouldReconnect(now: TimeInterval, oldestPending: TimeInterval?,
                                peerSilence: TimeInterval, consoleInteractive: Bool) -> Bool {
        guard consoleInteractive, now.isFinite, peerSilence.isFinite,
              peerSilence >= 0, peerSilence < 5,
              let oldestPending, oldestPending.isFinite else { return false }
        return now - oldestPending >= 5
    }
}
