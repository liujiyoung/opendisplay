import XCTest

final class CursorSequenceStateTests: XCTestCase {
    func testTCPMirrorBeforeFirstUDPStillAcknowledgesDelivery() {
        var state = CursorSequenceState()
        XCTAssertTrue(state.acceptForPresentation(10))
        XCTAssertTrue(state.receiveUDP(10).acknowledge)
        XCTAssertFalse(state.acceptForPresentation(10))
        XCTAssertFalse(state.receiveUDP(11).acknowledge)
        XCTAssertTrue(state.acceptForPresentation(11))
    }

    func testNewerFirstUDPAlsoAcknowledgesAfterTCPAdvanced() {
        var state = CursorSequenceState()
        XCTAssertTrue(state.acceptForPresentation(10))
        XCTAssertTrue(state.receiveUDP(11).acknowledge)
        XCTAssertTrue(state.acceptForPresentation(11))
    }

    func testNewUDPFlowCannotRewindPresentationSequence() {
        var state = CursorSequenceState()
        XCTAssertTrue(state.acceptForPresentation(100))
        _ = state.receiveUDP(100)
        state.beginUDPFlow()
        XCTAssertTrue(state.receiveUDP(99).acknowledge)
        XCTAssertFalse(state.acceptForPresentation(99))
        XCTAssertEqual(state.lastPresented, 100)
        XCTAssertTrue(state.acceptForPresentation(101))
    }

    func testLossAccountingIgnoresTCPMirrorsAndRejectsReordering() {
        var state = CursorSequenceState()
        XCTAssertTrue(state.receiveUDP(1).acknowledge)
        XCTAssertTrue(state.acceptForPresentation(1))
        XCTAssertTrue(state.acceptForPresentation(3)) // TCP doesn't alter UDP accounting
        XCTAssertEqual(state.receiveUDP(4).lost, 2)
        XCTAssertTrue(state.acceptForPresentation(4))
        XCTAssertEqual(state.receiveUDP(3).lost, 1)
        XCTAssertFalse(state.acceptForPresentation(3))
    }

    func testSessionResetAndInvalidOrExtremeSequence() {
        var state = CursorSequenceState()
        XCTAssertFalse(state.receiveUDP(0).acknowledge)
        XCTAssertTrue(state.receiveUDP(1).acknowledge)
        XCTAssertEqual(state.receiveUDP(UInt64.max).lost, 1_000_000)
        XCTAssertTrue(state.acceptForPresentation(100))
        state.resetSession()
        XCTAssertTrue(state.receiveUDP(1).acknowledge)
        XCTAssertTrue(state.acceptForPresentation(1))
    }
}
