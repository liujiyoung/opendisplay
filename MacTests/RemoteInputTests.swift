import XCTest

final class RemoteInputTests: XCTestCase {
    func testHIDMapsPhysicalKeyboardAndCommandKeys() {
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 4), 0) // A
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 6), 8) // C for Cmd+C
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 40), 36) // Return
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 82), 126) // Up
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 227), 55) // Left Command
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 231), 54) // Right Command
        XCTAssertEqual(RemoteInput.macKeyCode(forHID: 57), 57) // Caps Lock
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

final class RemoteCapsLockStateTests: XCTestCase {
    func testDefaultControlsCaseOncePerPhysicalPress() {
        var state = RemoteCapsLockState()
        XCTAssertFalse(state.switchesInputSource)
        XCTAssertEqual(state.update(down: true), .caseChanged)
        XCTAssertTrue(state.isLocked)
        XCTAssertEqual(state.update(down: true), .none)
        XCTAssertEqual(state.update(down: false), .none)
        XCTAssertEqual(state.update(down: true), .caseChanged)
        XCTAssertFalse(state.isLocked)
    }

    func testInputSourceModeNeverLatchesCaseAndPreservesOtherModifiers() {
        let caps: UInt64 = 1 << 16
        let shiftCommand: UInt64 = (1 << 17) | (1 << 20)
        var state = RemoteCapsLockState(switchesInputSource: true)
        XCTAssertEqual(state.update(down: true), .switchInputSource)
        XCTAssertEqual(state.update(down: true), .none)
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.modifiers(caps | shiftCommand), shiftCommand)
        _ = state.update(down: false)
        XCTAssertEqual(state.update(down: true), .switchInputSource)
    }

    func testLiveModeChangeClearsCaseWithoutLeakingTheIPadLatch() {
        let caps: UInt64 = 1 << 16
        var state = RemoteCapsLockState()
        _ = state.update(down: true)
        XCTAssertEqual(state.keyboardModifiers(hid: 4, flags: 0), 1 << 17)
        XCTAssertEqual(state.modifiers(caps), 0)
        state.setSwitchesInputSource(true)
        XCTAssertEqual(state.modifiers(caps), 0)
        XCTAssertFalse(state.isLocked)
        XCTAssertEqual(state.update(down: false), .none)
        state.setSwitchesInputSource(false)
        XCTAssertEqual(state.modifiers(caps), 0)
        XCTAssertEqual(state.update(down: true), .caseChanged)
        XCTAssertEqual(state.keyboardModifiers(hid: 4, flags: 1 << 17), 0)
    }

    func testFocusOrTransportResetReleasesTheKeyButPreservesLockedCase() {
        var state = RemoteCapsLockState()
        _ = state.update(down: true)
        state.releaseKey()
        XCTAssertTrue(state.isLocked)
        XCTAssertEqual(state.update(down: false), .none)
        XCTAssertEqual(state.update(down: true), .caseChanged)
        XCTAssertFalse(state.isLocked)
    }

    func testLockedCaseChangesLettersWithoutChangingShortcutsOrPunctuation() {
        var state = RemoteCapsLockState()
        _ = state.update(down: true)
        for hid in 4...29 {
            XCTAssertEqual(state.keyboardModifiers(hid: hid, flags: 0), 1 << 17)
            XCTAssertEqual(state.keyboardModifiers(hid: hid, flags: (1 << 16) | (1 << 17)), 0)
        }
        for flags: UInt64 in [1 << 18, 1 << 19, 1 << 20, (1 << 20) | (1 << 17)] {
            XCTAssertEqual(state.keyboardModifiers(hid: 6, flags: flags), flags)
        }
        for hid in [30, 40, 41, 44, 51, 82, 225] {
            XCTAssertEqual(state.keyboardModifiers(hid: hid, flags: 0), 0)
            XCTAssertEqual(state.keyboardModifiers(hid: hid, flags: 1 << 17), 1 << 17)
        }
    }
}

final class CapsLockInputSourcePreferenceTests: XCTestCase {
    func testNewInstallationDefaultsToLetterCaseWithoutSaving() throws {
        let suite = "CapsLockPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(CapsLockInputSourcePreference.isEnabled(in: defaults))
        XCTAssertNil(defaults.persistentDomain(forName: suite)?[CapsLockInputSourcePreference.key])
    }

    func testInputSourceChoiceIsRememberedAndCanBeDisabled() throws {
        let suite = "CapsLockPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        CapsLockInputSourcePreference.save(enabled: true, in: defaults)
        let reopened = try XCTUnwrap(UserDefaults(suiteName: suite))
        XCTAssertTrue(CapsLockInputSourcePreference.isEnabled(in: reopened))
        CapsLockInputSourcePreference.save(enabled: false, in: reopened)
        XCTAssertFalse(CapsLockInputSourcePreference.isEnabled(in: defaults))
    }
}
