import XCTest

final class RemoteUserActivityTests: XCTestCase {
    func testOnlyRealInputCanWakeTheDisplay() {
        let active: [[String: Any]] = [
            ["type": "key", "hid": 4, "down": true],
            ["type": "key", "hid": 57, "down": true],
            ["type": "text", "text": "a"],
            ["type": "pointerRelative", "phase": "move", "dx": 1.0, "dy": 0.0, "button": 0],
            ["type": "pointerRelative", "phase": "down", "dx": 0.0, "dy": 0.0, "button": 0],
            ["type": "pointerRelative", "phase": "down", "dx": 0.0, "dy": 0.0],
            ["type": "pointer", "phase": "down", "x": 0.5, "y": 0.5],
            ["type": "touch", "phase": "began", "x": 0.5, "y": 0.5],
            ["type": "pointerScroll", "dx": 0.0, "dy": 1.0],
            ["type": "pencil", "phase": "hover", "x": 0.5, "y": 0.5],
        ]
        for message in active {
            XCTAssertTrue(RemoteUserActivityPolicy.isUserInput(message), "\(message["type"] ?? "")")
        }
        let inactive: [[String: Any]] = [
            ["type": "ping"], ["type": "stats"], ["type": "cursorAck"], ["type": "inputReset"],
            ["type": "key", "hid": 4, "down": false], ["type": "key", "hid": -1, "down": true],
            ["type": "text", "text": ""], ["type": "text", "text": String(repeating: "a", count: 4097)],
            ["type": "pointerRelative", "phase": "up", "dx": 0.0, "dy": 0.0, "button": 0],
            ["type": "pointerRelative", "phase": "move", "dx": 0.0, "dy": 0.0, "button": 0],
            ["type": "pointerRelative", "phase": "move", "dx": Double.nan, "dy": 1.0, "button": 0],
            ["type": "pointerScroll", "dx": 0.0, "dy": 0.0],
            ["type": "pointerScroll", "dx": 4097.0, "dy": 0.0],
            ["type": "pointer", "phase": "up", "x": 0.5, "y": 0.5],
            ["type": "pointer", "phase": "down", "x": 0.5, "y": 0.5, "button": -1],
            ["type": "touch", "phase": "cancelled", "x": 0.5, "y": 0.5],
            ["type": "pencil", "phase": "up", "x": 0.5, "y": 0.5],
        ]
        for message in inactive {
            XCTAssertFalse(RemoteUserActivityPolicy.isUserInput(message), "\(message["type"] ?? "")")
        }
    }

    func testContinuousMotionIsThrottledButNewSleepWakesImmediately() {
        var policy = RemoteUserActivityPolicy()
        XCTAssertTrue(policy.shouldDeclare(at: 10, displayAsleep: false))
        XCTAssertFalse(policy.shouldDeclare(at: 10.01, displayAsleep: false))
        // A manual display sleep immediately after input must not wait for
        // the regular throttle before the very first wake keystroke.
        XCTAssertTrue(policy.shouldDeclare(at: 10.02, displayAsleep: true))
        XCTAssertFalse(policy.shouldDeclare(at: 10.03, displayAsleep: true))
        XCTAssertTrue(policy.shouldDeclare(at: 11.1, displayAsleep: true))
        XCTAssertFalse(policy.shouldDeclare(at: 11.11, displayAsleep: false))
        XCTAssertTrue(policy.shouldDeclare(at: 11.12, displayAsleep: true))
        XCTAssertTrue(policy.shouldDeclare(at: 71.12, displayAsleep: true))
    }
}
