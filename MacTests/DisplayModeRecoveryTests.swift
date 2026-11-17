import XCTest

final class DisplayModeRecoveryTests: XCTestCase {
    private let mode = VirtualCanvasSize(pointsWide: 1194, pointsHigh: 834, scale: 2)
    private let now = Date(timeIntervalSinceReferenceDate: 100)

    func testOnlyAwakeUnlockedConsoleCanConfigure() {
        for onConsole in [false, true] {
            for locked in [false, true] {
                for asleep in [false, true] {
                    let state = DisplayConfigurationAvailability(onConsole: onConsole,
                        screenLocked: locked, displayAsleep: asleep)
                    XCTAssertEqual(state.canConfigure, onConsole && !locked && !asleep)
                }
            }
        }
    }

    func testLockBoundaryDoesNotSpendFailureBudgetOrBackOff() {
        var retry = DisplayModeRetry()
        for _ in 0..<4 { retry.failed(canConfigure: true, now: now) }
        for _ in 0..<10 {
            XCTAssertFalse(retry.failed(canConfigure: false, now: now))
        }
        XCTAssertEqual(retry.failures, 0)
        XCTAssertLessThan(retry.retryAfter, now)
        retry.failed(canConfigure: true, now: now)
        XCTAssertEqual(retry.failures, 1)
        XCTAssertLessThan(retry.retryAfter, now)
    }

    func testGenuinelyRefusedModesStillBackOff() {
        var retry = DisplayModeRetry()
        for _ in 0..<DisplayModeRetry.failureLimit {
            XCTAssertTrue(retry.failed(canConfigure: true, now: now))
        }
        XCTAssertEqual(retry.failures, 5)
        XCTAssertEqual(retry.retryAfter, now + 30)
        retry.reset()
        XCTAssertEqual(retry.failures, 0)
        XCTAssertLessThan(retry.retryAfter, now)
    }

    func testFailuresWhileLockedNeverCacheNativeFallback() {
        var modes = RefusedDisplayModes()
        XCTAssertFalse(modes.insert(mode, canConfigure: false))
        XCTAssertFalse(modes.contains(mode))
        XCTAssertFalse(modes.observeConsole(available: true))
        XCTAssertFalse(modes.contains(mode))
    }

    func testOldFallbackIsClearedExactlyOnceOnUnlockOrWake() {
        var modes = RefusedDisplayModes()
        XCTAssertTrue(modes.insert(mode, canConfigure: true))
        XCTAssertFalse(modes.observeConsole(available: true))
        XCTAssertTrue(modes.contains(mode))
        XCTAssertFalse(modes.observeConsole(available: false))
        XCTAssertTrue(modes.observeConsole(available: true))
        XCTAssertFalse(modes.contains(mode))
        XCTAssertFalse(modes.observeConsole(available: true))
        // A mode that really fails after the resume remains protected.
        XCTAssertTrue(modes.insert(mode, canConfigure: true))
        XCTAssertFalse(modes.observeConsole(available: true))
        XCTAssertTrue(modes.contains(mode))
    }

    func testManualReselectionClearsFallbackWithoutNeedingAnotherLock() {
        var modes = RefusedDisplayModes()
        XCTAssertTrue(modes.insert(mode, canConfigure: true))
        XCTAssertFalse(modes.insert(mode, canConfigure: true))
        XCTAssertTrue(modes.reset())
        XCTAssertFalse(modes.contains(mode))
        XCTAssertFalse(modes.reset())
    }
}
