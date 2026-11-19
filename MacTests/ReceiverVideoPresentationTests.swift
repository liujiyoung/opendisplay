import XCTest

final class ReceiverVideoPresentationTests: XCTestCase {
    func testPreparedHandoffHoldsPictureButWaitsForFreshVideo() {
        var state = ReceiverVideoPresentation()
        state.begin(1)
        state.receivedFrame(1)
        state.begin(2, retainingPicture: true)
        XCTAssertTrue(state.isHoldingPreviousFrame)
        XCTAssertFalse(state.isReady)
        state.receivedFrame(1)
        state.endHold(1)
        XCTAssertTrue(state.isHoldingPreviousFrame)
        XCTAssertFalse(state.isReady)
        state.receivedFrame(2)
        XCTAssertFalse(state.isHoldingPreviousFrame)
        XCTAssertTrue(state.isReady)
    }

    func testLockAndTimeoutClearHeldPicture() {
        var state = ReceiverVideoPresentation()
        state.begin(1)
        state.receivedFrame(1)
        state.begin(2, retainingPicture: true)
        state.setLocked(true, generation: 2)
        XCTAssertFalse(state.isHoldingPreviousFrame)
        XCTAssertFalse(state.isReady)
        state.begin(3, retainingPicture: true)
        XCTAssertFalse(state.isHoldingPreviousFrame)
        state.receivedFrame(3)
        state.begin(4, retainingPicture: true)
        state.endHold(4)
        XCTAssertFalse(state.isHoldingPreviousFrame)
        XCTAssertFalse(state.isReady)
        state.receivedFrame(4)
        XCTAssertTrue(state.isReady)
    }

    func testHandoffMarkerIsReadOnlyFromACompleteUnlockedFirstFrame() throws {
        let id = UUID()
        func frame(_ json: String) -> Data {
            let payload = Data(json.utf8)
            var bytes = withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) }
            bytes.append(payload)
            return bytes
        }
        let marker = frame("{\"type\":\"streamHandoff\",\"senderSession\":\"\(id)\",\"screenLocked\":false}")
        XCTAssertEqual(StreamHandoff.leadingControlFrameSize(in: marker.prefix(6)), marker.count)
        XCTAssertNil(StreamHandoff.senderSession(in: marker.dropLast()))
        XCTAssertEqual(StreamHandoff.senderSession(in: marker + frame("{\"type\":\"streamConfig\"}")), id)
        XCTAssertNil(StreamHandoff.senderSession(in: frame("{\"type\":\"streamHandoff\",\"senderSession\":\"\(id)\",\"screenLocked\":true}")))
        XCTAssertNil(StreamHandoff.senderSession(in: frame("{\"type\":\"welcome\",\"senderSession\":\"\(id)\",\"screenLocked\":false}") + marker))
    }

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
