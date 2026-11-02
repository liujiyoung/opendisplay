import XCTest

final class AdaptiveVideoBitrateTests: XCTestCase {
    private func feedback(_ now: Double, mbps: Double = 18, rtt: Double = 6,
                          video: Double = 18, p95: Double = 25) -> AdaptiveVideoBitrate.Feedback {
        .init(receivedAt: now, mbps: mbps, rttMs: rtt, videoP50Ms: video,
              videoP95Ms: p95, encodeMs: 12, decodeMs: 1)
    }

    func testSendBacklogCutsQuicklyWithoutGoingBelowQualityFloor() {
        var rate = AdaptiveVideoBitrate(ceiling: 18_000_000)
        XCTAssertEqual(rate.update(now: 0, offeredMbps: 18, pending: 3, oldestSendMs: 100,
                                   networkDrops: 0, feedback: nil)?.bitrate, 13_500_000)
        XCTAssertNil(rate.update(now: 1, offeredMbps: 18, pending: 3, oldestSendMs: 100,
                                 networkDrops: 0, feedback: nil))
        for time in stride(from: 2.0, through: 30, by: 2) {
            _ = rate.update(now: time, offeredMbps: 18, pending: 3, oldestSendMs: 100,
                            networkDrops: 0, feedback: nil)
        }
        XCTAssertEqual(rate.target, 4_500_000)
    }

    func testVideoQueueCanReduceRateWhileIndependentControlIsFast() {
        var rate = AdaptiveVideoBitrate(ceiling: 18_000_000)
        let change = rate.update(now: 0, offeredMbps: 18, pending: 0, oldestSendMs: 0,
                                 networkDrops: 0, feedback: feedback(0, video: 150, p95: 250))
        XCTAssertEqual(change?.reason, "receiver-delay")
        XCTAssertEqual(rate.target, 13_500_000)
    }

    func testControlSpikeOnLowTrafficDesktopDoesNotReduceQuality() {
        var rate = AdaptiveVideoBitrate(ceiling: 18_000_000)
        for time in 0..<20 {
            XCTAssertNil(rate.update(now: Double(time), offeredMbps: 1.3, pending: 0, oldestSendMs: 0,
                                     networkDrops: 0, feedback: feedback(Double(time), mbps: 1.3, rtt: 150, video: 150)))
        }
        XCTAssertEqual(rate.target, rate.ceiling)
    }

    func testRecoveryWaitsForSustainedFreshHealthyTrafficAndStaysBounded() {
        var rate = AdaptiveVideoBitrate(ceiling: 10_000_000)
        _ = rate.update(now: 0, offeredMbps: 10, pending: 3, oldestSendMs: 100,
                        networkDrops: 2, feedback: nil)
        for time in 1..<13 {
            XCTAssertNil(rate.update(now: Double(time), offeredMbps: 10, pending: 0, oldestSendMs: 0,
                                     networkDrops: 0, feedback: feedback(Double(time), mbps: 10)))
        }
        XCTAssertEqual(rate.update(now: 13, offeredMbps: 10, pending: 0, oldestSendMs: 0,
                                   networkDrops: 0, feedback: feedback(13, mbps: 10))?.bitrate, 8_000_000)
        for time in 14..<120 {
            _ = rate.update(now: Double(time), offeredMbps: 10, pending: 0, oldestSendMs: 0,
                            networkDrops: 0, feedback: feedback(Double(time), mbps: 10))
        }
        XCTAssertEqual(rate.target, rate.ceiling)
    }

    func testStaleMissingInvalidOrIdleFeedbackCannotRaiseRate() {
        for sample in [nil, feedback(0), feedback(.nan)] as [AdaptiveVideoBitrate.Feedback?] {
            var rate = AdaptiveVideoBitrate(ceiling: 6_000_000)
            _ = rate.update(now: 0, offeredMbps: 6, pending: 3, oldestSendMs: 100,
                            networkDrops: 2, feedback: nil)
            for time in 10..<40 {
                _ = rate.update(now: Double(time), offeredMbps: 6, pending: 0, oldestSendMs: 0,
                                networkDrops: 0, feedback: sample)
            }
            XCTAssertEqual(rate.target, 4_500_000)
        }
        var rate = AdaptiveVideoBitrate(ceiling: 6_000_000)
        _ = rate.update(now: 0, offeredMbps: 6, pending: 3, oldestSendMs: 100, networkDrops: 2, feedback: nil)
        for time in 1..<40 {
            _ = rate.update(now: Double(time), offeredMbps: 0, pending: 0, oldestSendMs: 0,
                            networkDrops: 0, feedback: feedback(Double(time), mbps: 0))
        }
        XCTAssertEqual(rate.target, 4_500_000)
    }

    func testNewPathResetsBudgetAndLatencyBaseline() {
        var rate = AdaptiveVideoBitrate(ceiling: 18_000_000)
        _ = rate.update(now: 0, offeredMbps: 18, pending: 3, oldestSendMs: 100, networkDrops: 2, feedback: nil)
        rate = AdaptiveVideoBitrate(ceiling: 6_000_000)
        XCTAssertEqual(rate.target, 6_000_000)
        XCTAssertEqual(rate.floor, 2_000_000)
    }

    func testFreshLowTrafficDesktopCanRecoverItsQualityBudget() {
        var rate = AdaptiveVideoBitrate(ceiling: 18_000_000)
        _ = rate.update(now: 0, offeredMbps: 18, pending: 3, oldestSendMs: 100, networkDrops: 2, feedback: nil)
        for time in 1..<30 {
            _ = rate.update(now: Double(time), offeredMbps: 1.3, pending: 0, oldestSendMs: 0,
                            networkDrops: 0, feedback: feedback(Double(time), mbps: 1.3))
        }
        XCTAssertGreaterThan(rate.target, 13_500_000)
        XCTAssertLessThanOrEqual(rate.target, rate.ceiling)
    }

    func testFrameProtectionCanHoldTheSafeBudgetUnderContinuedPressure() {
        var rate = AdaptiveVideoBitrate(ceiling: 18_000_000, minimum: 18_000_000)
        for time in 0..<20 {
            XCTAssertNil(rate.update(now: Double(time), offeredMbps: 18, pending: 3, oldestSendMs: 100,
                                     networkDrops: 10, feedback: feedback(Double(time), video: 150)))
        }
        XCTAssertEqual(rate.target, rate.ceiling)
    }

    func testLearnedFrameFloorStartsAtSafeRateAndCanRecoverUpward() {
        var rate = AdaptiveVideoBitrate(ceiling: 18_000_000, minimum: 7_600_000, initial: 7_600_000)
        XCTAssertNil(rate.update(now: 0, offeredMbps: 8, pending: 3, oldestSendMs: 100,
                                 networkDrops: 10, feedback: feedback(0, mbps: 8, video: 150)))
        XCTAssertEqual(rate.target, 7_600_000)
        for time in 1..<30 {
            _ = rate.update(now: Double(time), offeredMbps: 8, pending: 0, oldestSendMs: 0,
                            networkDrops: 0, feedback: feedback(Double(time), mbps: 8))
        }
        XCTAssertGreaterThan(rate.target, 7_600_000)
        XCTAssertEqual(AdaptiveVideoBitrate(ceiling: 18_000_000, initial: 30_000_000).target, 18_000_000)
        XCTAssertEqual(AdaptiveVideoBitrate(ceiling: 18_000_000, initial: 1).target, 4_500_000)
    }
}
