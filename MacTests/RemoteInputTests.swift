import XCTest

final class RemoteInputTests: XCTestCase {
    func testHIDMapsPhysicalKeyboardAndCommandKeys() {
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 4), 0) // A
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 6), 8) // C for Cmd+C
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 40), 36) // Return
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 82), 126) // Up
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 227), 55) // Left Command
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 231), 54) // Right Command
        XCTAssertNil(RemoteInput.macKeyCode(forHID: -1))
        XCTAssertNil(RemoteInput.macKeyCode(forHID: 65535))
    }

    func testUnicodeChunksPreserveChineseAndSurrogatePairs() {
        let text = String(repeating: "输入😀", count: 30)
        let chunks = RemoteInput.textChunks(text)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.map { String(decoding: $0, as: UTF16.self) }.joined(), text)
        XCTAssertTrue(RemoteInput.textChunks("").isEmpty)
    }

    func testIPadCapsLockDoesNotLeakIntoLettersOrPointerModifiers() {
        let caps: UInt64 = 1 << 16
        let shift: UInt64 = 1 << 17
        let command: UInt64 = 1 << 20
        XCTAssertEqual(RemoteInput.iPadModifiers(caps), 0)
        XCTAssertEqual(RemoteInput.iPadModifiers(caps | shift | command), shift | command)
        XCTAssertEqual(RemoteInput.iPadModifiers(UInt64.max), RemoteInput.modifierMask & ~caps)
    }

    func testCapsLockSwitchesOncePerPressAndRecoversAfterFocusLoss() {
        var key = InputSourceSwitchKey()
        XCTAssertTrue(key.update(down: true))
        XCTAssertFalse(key.update(down: true)) // key repeat/long press
        XCTAssertFalse(key.update(down: false))
        XCTAssertFalse(key.update(down: false))
        XCTAssertTrue(key.update(down: true)) // next tap switches back
        key.reset() // app switch or cable loss while held
        XCTAssertFalse(key.update(down: false))
        XCTAssertTrue(key.update(down: true))
    }
}
