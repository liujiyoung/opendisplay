import Foundation

/// Additive local extension of protocol 3; advertised by welcome.remoteInput.
/// UIKit HID usages are physical keys; macOS CGKeyCode is a different table.
enum RemoteInput {
    static let capability = 1
    static let modifierMask: UInt64 = 0x00BF0000 // caps, shift, control, option, command, keypad, fn

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
