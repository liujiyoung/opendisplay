import XCTest

final class VideoDeliveryWatchdogTests: XCTestCase {
    func testFreshControlHeartbeatsCannotMaskAStalledVideoSend() {
        for second in 0..<5 {
            XCTAssertFalse(VideoDeliveryWatchdog.shouldReconnect(now: Double(second), oldestPending: 0,
                peerSilence: 0.1, consoleInteractive: true))
        }
        XCTAssertTrue(VideoDeliveryWatchdog.shouldReconnect(now: 5, oldestPending: 0,
            peerSilence: 0.1, consoleInteractive: true))
        XCTAssertTrue(VideoDeliveryWatchdog.shouldReconnect(now: 100, oldestPending: 0,
            peerSilence: 0.1, consoleInteractive: true))
    }

    func testIdleDesktopAndCompletedSendsDoNotTriggerReconnect() {
        XCTAssertFalse(VideoDeliveryWatchdog.shouldReconnect(now: 100, oldestPending: nil,
            peerSilence: 0.1, consoleInteractive: true))
        XCTAssertFalse(VideoDeliveryWatchdog.shouldReconnect(now: 100, oldestPending: 99,
            peerSilence: 0.1, consoleInteractive: true))
    }

    func testLockAndPeerSilenceKeepTheirExistingRecoveryPaths() {
        XCTAssertFalse(VideoDeliveryWatchdog.shouldReconnect(now: 100, oldestPending: 0,
            peerSilence: 0.1, consoleInteractive: false))
        XCTAssertFalse(VideoDeliveryWatchdog.shouldReconnect(now: 100, oldestPending: 0,
            peerSilence: 5, consoleInteractive: true))
    }
}
