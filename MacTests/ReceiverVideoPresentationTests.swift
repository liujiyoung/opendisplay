import XCTest

final class ReceiverVideoPresentationTests: XCTestCase {
    func testReconnectsWithoutVideoNeverPresentABlackVideoPage() {
        var state = ReceiverVideoPresentation()
        state.begin(1)
        state.receivedFrame(1)
        XCTAssertTrue(state.isReady)
        state.end(1)
        for generation in UInt64(2)...UInt64(500) {
            state.begin(generation)
            XCTAssertFalse(state.isReady)
            state.receivedFrame(generation - 1)
            XCTAssertFalse(state.isReady)
            state.end(generation)
            state.receivedFrame(generation)
            XCTAssertFalse(state.isReady)
        }
    }

    func testOnlyTheCurrentSessionsFirstFrameEnablesVideo() {
        var state = ReceiverVideoPresentation()
        state.begin(1)
        state.begin(2)
        state.receivedFrame(1)
        state.end(1)
        XCTAssertFalse(state.isReady)
        XCTAssertTrue(state.accepts(2))
        state.receivedFrame(2)
        XCTAssertTrue(state.isReady)
    }

    func testUnlockWaitsForFreshVideoInsteadOfShowingTheFrozenDesktop() {
        var state = ReceiverVideoPresentation()
        state.begin(1)
        state.receivedFrame(1)
        state.setLocked(true, generation: 1)
        XCTAssertTrue(state.isLocked)
        XCTAssertFalse(state.isReady)
        state.receivedFrame(1)
        XCTAssertFalse(state.isReady)
        state.setLocked(false, generation: 1)
        XCTAssertFalse(state.isReady)
        state.receivedFrame(1)
        XCTAssertTrue(state.isReady)
    }
}
