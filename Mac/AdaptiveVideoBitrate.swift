import Foundation

enum AdaptiveVideoBitratePreference {
    // Preserve the existing command-line override and default-on behavior.
    static let disabledKey = "disableAdaptiveBitrate"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        !defaults.bool(forKey: disabledKey)
    }

    static func save(enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(!enabled, forKey: disabledKey)
    }
}

/// Feedback controller for the video byte budget, independent of raster/fps.
/// A slow control RTT alone is not evidence that video bitrate is excessive.
struct AdaptiveVideoBitrate {
    struct Feedback {
        let receivedAt: Double
        let mbps: Double
        let rttMs: Double
        let videoP50Ms: Double
        let videoP95Ms: Double
        let encodeMs: Double
        let decodeMs: Double

        var isValid: Bool {
            [receivedAt, mbps, rttMs, videoP50Ms, videoP95Ms, encodeMs, decodeMs]
                .allSatisfy { $0.isFinite && $0 >= 0 }
        }
    }

    struct Decision {
        let bitrate: Int
        let reason: String
    }

    let ceiling: Int
    let floor: Int
    private(set) var target: Int
    private var minimumRTT: Double?
    private var lastFeedbackAt: Double?
    private var lastChangeAt = -Double.infinity
    private var healthySince: Double?

    init(ceiling: Int, minimum: Int? = nil, initial: Int? = nil) {
        let upper = max(1, ceiling)
        let lower = min(max(minimum ?? 2_000_000, ceiling / 4), upper)
        self.ceiling = upper
        self.floor = lower
        self.target = min(max(initial ?? upper, lower), upper)
    }

    mutating func update(now: Double, offeredMbps: Double, pending: Int,
                         oldestSendMs: Double, networkDrops: Int,
                         feedback: Feedback?) -> Decision? {
        guard now.isFinite, offeredMbps.isFinite, offeredMbps >= 0,
              oldestSendMs.isFinite, oldestSendMs >= 0 else { return nil }
        let fresh = feedback.flatMap { f in
            f.isValid && now >= f.receivedAt && now - f.receivedAt <= 8 ? f : nil
        }
        if let fresh, lastFeedbackAt != fresh.receivedAt {
            lastFeedbackAt = fresh.receivedAt
            minimumRTT = min(minimumRTT ?? fresh.rttMs, fresh.rttMs)
        }
        let traffic = max(offeredMbps, fresh?.mbps ?? 0)
        let active = traffic >= 0.5
        let loaded = traffic >= Double(target) / 1_000_000 * 0.35
        let localPressure = active && (networkDrops >= 2 || pending >= 3 || oldestSendMs >= 80)
        let baseline = minimumRTT ?? 10
        let rttPressure = fresh.map { $0.rttMs > max(40, baseline * 2 + 10) } ?? false
        let videoPressure = fresh.map {
            $0.videoP50Ms - $0.encodeMs - $0.decodeMs > max(40, baseline / 2 + 30)
            || $0.videoP95Ms - $0.encodeMs - $0.decodeMs > max(100, baseline / 2 + 70)
        } ?? false
        let congested = localPressure || (loaded && (videoPressure || rttPressure))
        if congested {
            healthySince = nil
            guard now - lastChangeAt >= 2 else { return nil }
            let next = max(floor, target * 3 / 4)
            guard next < target else { return nil }
            target = next
            lastChangeAt = now
            return Decision(bitrate: next, reason: localPressure ? "send-pressure" : "receiver-delay")
        }
        // No upward extrapolation from stale feedback or an idle desktop.
        guard active, fresh != nil, !rttPressure, !videoPressure,
              pending < 2, networkDrops == 0, oldestSendMs < 30 else {
            healthySince = nil
            return nil
        }
        if healthySince == nil { healthySince = now }
        guard let healthySince, now - healthySince >= 12,
              now - lastChangeAt >= 5 else { return nil }
        let next = min(ceiling, target + max(250_000, ceiling / 20))
        guard next > target else { return nil }
        target = next
        lastChangeAt = now
        return Decision(bitrate: next, reason: "stable-recovery")
    }
}
