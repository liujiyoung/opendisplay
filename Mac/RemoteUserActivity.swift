import Foundation
import CoreGraphics
import IOKit.pwr_mgt

/// Only deliberate input renews activity. Video, pings, input resets and
/// releases must leave the user's idle-display timer alone.
struct RemoteUserActivityPolicy {
    private var lastDeclaration: TimeInterval?
    private var displayWasAsleep = false

    mutating func shouldDeclare(at now: TimeInterval, displayAsleep: Bool) -> Bool {
        guard now.isFinite else { return false }
        let justSlept = displayAsleep && !displayWasAsleep
        displayWasAsleep = displayAsleep
        guard justSlept || lastDeclaration == nil || now - lastDeclaration! >= 1 else { return false }
        lastDeclaration = now
        return true
    }

    static func isUserInput(_ message: [String: Any]) -> Bool {
        switch message["type"] as? String {
        case "key":
            guard let hid = message["hid"] as? Int else { return false }
            return message["down"] as? Bool == true && RemoteInput.macKeyCode(forHID: hid) != nil
        case "text":
            guard let text = message["text"] as? String else { return false }
            return !text.isEmpty && text.utf16.count <= 4096
        case "pointerRelative":
            let button = message["button"] as? Int ?? 0
            guard let phase = message["phase"] as? String,
                  (0...2).contains(button),
                  let dx = message["dx"] as? Double, let dy = message["dy"] as? Double,
                  validDelta(dx, dy) else { return false }
            return phase == "down" || (phase == "move" && (dx != 0 || dy != 0))
        case "pointer", "touch", "pencil":
            guard let phase = message["phase"] as? String,
                  let x = message["x"] as? Double, let y = message["y"] as? Double,
                  x.isFinite, y.isFinite else { return false }
            if message["type"] as? String == "pointer",
               !(0...2).contains(message["button"] as? Int ?? 0) { return false }
            if message["type"] as? String == "touch" { return phase == "began" || phase == "moved" }
            return phase == "down" || phase == "move" || (phase == "hover" && message["type"] as? String == "pencil")
        case "pointerScroll", "scroll":
            guard let dx = message["dx"] as? Double, let dy = message["dy"] as? Double else { return false }
            return validDelta(dx, dy) && (dx != 0 || dy != 0)
        default:
            return false
        }
    }

    private static func validDelta(_ dx: Double, _ dy: Double) -> Bool {
        dx.isFinite && dy.isFinite && abs(dx) <= 4096 && abs(dy) <= 4096
    }
}

/// Owned by a sender session, independently of its capture/input-injector
/// lifetime. CGEvent injection alone need not wake a sleeping display.
final class RemoteUserActivity {
    // Policy is confined to MacSender.queue; potentially blocking powerd IPC
    // runs separately so it cannot hold up the ordered keyboard/control path.
    private var policy = RemoteUserActivityPolicy()
    private let powerQueue = DispatchQueue(label: "opendisplay.user-activity", qos: .userInitiated)
    private var assertionID = IOPMAssertionID(kIOPMNullAssertionID) // powerQueue
    private var loggedActive = false // powerQueue

    func record(_ message: [String: Any]) {
        guard RemoteUserActivityPolicy.isUserInput(message) else { return }
        let asleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        guard policy.shouldDeclare(at: ProcessInfo.processInfo.systemUptime, displayAsleep: asleep) else { return }
        powerQueue.async {
            // Explicitly request local-display wake, as a directly attached
            // keyboard would. This neither unlocks nor authenticates a user.
            let result = IOPMAssertionDeclareUserActivity("OpenDisplay remote input" as CFString,
                                                         kIOPMUserActiveLocal, &self.assertionID)
            if asleep || result != kIOReturnSuccess {
                Log.info("remote input requested display wake: asleep=\(asleep) result=\(result)")
            } else if !self.loggedActive {
                Log.info("remote user activity reporting active")
            }
            self.loggedActive = true
        }
    }

    func reset() {
        policy = RemoteUserActivityPolicy()
        powerQueue.async { self.releaseAssertion() }
    }

    deinit { releaseAssertion() }

    private func releaseAssertion() {
        if assertionID != kIOPMNullAssertionID {
            IOPMAssertionRelease(assertionID)
            assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        }
    }
}
