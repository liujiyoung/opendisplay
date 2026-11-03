import Foundation

/// Additive local extension of protocol 3; advertised by welcome.remoteInput.
/// UIKit HID usages are physical keys; macOS CGKeyCode is a different table.
enum RemoteInput {
    static let capability = 1
    static let relativePointerCapability = 2
    static let capsLockKeyCapability = 1
    static let modifierMask: UInt64 = 0x00BF0000 // caps, shift, control, option, command, keypad, fn

    /// The Mac owns Caps Lock behavior; the iPad's local latch must not leak
    /// into the independently tracked remote case or input-source mode.
    static func iPadModifiers(_ flags: UInt64) -> UInt64 {
        flags & modifierMask & ~(1 << 16)
    }

    /// Raw pointer events have no UIKit modifier flags. Prefer the current
    /// physical keyboard snapshot over the last key event's cached flags.
    static func pointerModifiers(fallback: UInt64, observedHIDs: Set<Int>, pressedHIDs: Set<Int>) -> UInt64 {
        var flags = iPadModifiers(fallback)
        let groups: [(UInt64, Set<Int>)] = [
            (1 << 18, [224, 228]), (1 << 17, [225, 229]),
            (1 << 19, [226, 230]), (1 << 20, [227, 231]),
        ]
        for (mask, hids) in groups where !hids.isDisjoint(with: observedHIDs) {
            flags &= ~mask
            if !hids.isDisjoint(with: pressedHIDs) { flags |= mask }
        }
        return flags
    }

    static func macKeyCode(forHID usage: Int) -> UInt16? { keyCodes[usage] }

    private static let keyCodes: [Int: UInt16] = [
        4:0, 5:11, 6:8, 7:2, 8:14, 9:3, 10:5, 11:4, 12:34,
        13:38, 14:40, 15:37, 16:46, 17:45, 18:31, 19:35, 20:12,
        21:15, 22:1, 23:17, 24:32, 25:9, 26:13, 27:7, 28:16, 29:6,
        30:18, 31:19, 32:20, 33:21, 34:23, 35:22, 36:26, 37:28, 38:25, 39:29,
        40:36, 41:53, 42:51, 43:48, 44:49, 45:27, 46:24, 47:33, 48:30,
        49:42, 50:42, 51:41, 52:39, 53:50, 54:43, 55:47, 56:44, 57:57,
        58:122, 59:120, 60:99, 61:118, 62:96, 63:97, 64:98, 65:100,
        66:101, 67:109, 68:103, 69:111,
        73:114, 74:115, 75:116, 76:117, 77:119, 78:121,
        79:124, 80:123, 81:125, 82:126,
        83:71, 84:75, 85:67, 86:78, 87:69, 88:76,
        89:83, 90:84, 91:85, 92:86, 93:87, 94:88, 95:89, 96:91, 97:92, 98:82, 99:65,
        100:10, 103:81, 104:105, 105:107, 106:113, 107:106, 108:64, 109:79, 110:80,
        224:59, 225:56, 226:58, 227:55, 228:62, 229:60, 230:61, 231:54,
    ]

    /// Respect CGEvent's short Unicode payload without splitting a surrogate
    /// pair (e.g. a Chinese character or emoji).
    static func textChunks(_ text: String) -> [[UInt16]] {
        var result: [[UInt16]] = []
        var chunk: [UInt16] = []
        for scalar in text.unicodeScalars {
            let units = Array(String(scalar).utf16)
            if chunk.count + units.count > 20 { result.append(chunk); chunk = [] }
            chunk += units
        }
        if !chunk.isEmpty { result.append(chunk) }
        return result
    }
}

/// The last injected flags can outlive their key-down (for example after an
/// app-switch reset followed by a delayed event). Release only modifiers owned
/// by this remote session, never infer ownership from the Mac's global state.
struct RemoteModifierState {
    private(set) var flags: UInt64 = 0
    private static let keys: [(UInt64, [UInt16])] = [
        (1 << 17, [56, 60]), // Shift
        (1 << 18, [59, 62]), // Control
        (1 << 19, [58, 61]), // Option
        (1 << 20, [55, 54]), // Command
        (1 << 23, [63]),     // Fn
    ]

    mutating func observe(_ flags: UInt64) {
        self.flags = flags & RemoteInput.modifierMask
    }

    mutating func reconcile(to desired: UInt64, heldKeys: Set<UInt16>) -> [UInt16] {
        let desired = desired & RemoteInput.modifierMask
        var releases = Set<UInt16>()
        for (mask, codes) in Self.keys where desired & mask == 0 {
            let held = heldKeys.intersection(codes)
            releases.formUnion(held)
            // A flag-bearing ordinary key or mouse event may have asserted
            // the modifier without a matching explicit modifier key-down.
            if flags & mask != 0, held.isEmpty { releases.insert(codes[0]) }
        }
        flags = desired
        return releases.sorted()
    }

    mutating func releaseAll(heldKeys: Set<UInt16>) -> [UInt16] {
        Array(heldKeys.union(reconcile(to: 0, heldKeys: heldKeys))).sorted()
    }
}

/// A held/repeated Caps Lock press switches once; the next press switches back.
struct InputSourceSwitchKey {
    private var held = false

    mutating func update(down: Bool) -> Bool {
        let shouldSwitch = down && !held
        held = down
        return shouldSwitch
    }

    mutating func reset() { held = false }
}

/// Remote Caps Lock is independent of the iPad's own input-source settings.
/// The sender chooses its action without renegotiating or reconnecting.
struct RemoteCapsLockState {
    enum Action: Equatable { case none, caseChanged, switchInputSource }
    private var key = InputSourceSwitchKey()
    private(set) var switchesInputSource: Bool
    private(set) var isLocked = false

    init(switchesInputSource: Bool = false) {
        self.switchesInputSource = switchesInputSource
    }

    mutating func setSwitchesInputSource(_ enabled: Bool) {
        guard switchesInputSource != enabled else { return }
        switchesInputSource = enabled
        isLocked = false
        key.reset()
    }

    mutating func update(down: Bool) -> Action {
        guard key.update(down: down) else { return .none }
        if switchesInputSource { return .switchInputSource }
        isLocked.toggle()
        return .caseChanged
    }

    mutating func releaseKey() { key.reset() }

    func modifiers(_ flags: UInt64) -> UInt64 {
        RemoteInput.iPadModifiers(flags)
    }

    func keyboardModifiers(hid: Int, flags: UInt64) -> UInt64 {
        var result = modifiers(flags)
        let shortcutModifiers: UInt64 = (1 << 18) | (1 << 19) | (1 << 20)
        if isLocked, !switchesInputSource, (4...29).contains(hid), result & shortcutModifiers == 0 {
            // AlphaShift itself can trigger macOS's Caps-to-input-source
            // behavior. Apply case to letters with Shift instead, without
            // changing punctuation or turning Cmd+C into Cmd+Shift+C.
            result ^= 1 << 17
        }
        return result
    }
}
