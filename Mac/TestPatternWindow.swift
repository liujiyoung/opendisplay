import SwiftUI
import AppKit

/// Debug aid: a full-screen animated window on the virtual display so the
/// pipeline streams continuously — without it, ScreenCaptureKit emits nothing
/// while the screen is static and steady-state latency can't be measured.
/// Enable with `defaults write com.peetzweg.opensidecar.mac testPattern -bool true`.
@MainActor
enum TestPattern {
    // One window per virtual display — multi-device sessions each get their
    // own pattern, so all pipelines stream at once during measurements.
    private static var windows: [CGDirectDisplayID: NSWindow] = [:]
    private static var screenObserver: NSObjectProtocol?

    private static func alignWindows() {
        for (id, window) in windows {
            guard let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == id
            }) else { continue }
            if window.frame != screen.frame {
                window.setFrame(screen.frame, display: true)
                Log.info("test pattern aligned on display \(id): \(window.frame)")
            }
        }
    }

    static func show(on displayID: CGDirectDisplayID) {
        hide(on: displayID)
        // The screen may register a beat after the virtual display appears.
        Task { @MainActor in
            for _ in 0..<10 {
                if let screen = NSScreen.screens.first(where: {
                    ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
                }) {
                    let w = PatternWindow(contentRect: screen.frame, styleMask: [.borderless],
                                          backing: .buffered, defer: false, screen: screen)
                    w.contentView = NSHostingView(rootView: PatternView())
                    w.setFrame(screen.frame, display: true)
                    w.orderFrontRegardless()
                    windows[displayID] = w
                    if screenObserver == nil {
                        screenObserver = NotificationCenter.default.addObserver(
                            forName: NSApplication.didChangeScreenParametersNotification,
                            object: nil, queue: .main
                        ) { _ in
                            Task { @MainActor in alignWindows() }
                        }
                    }
                    Log.info("test pattern window shown on display \(displayID)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            Log.info("test pattern: screen for display \(displayID) never appeared")
        }
    }

    static func hide(on displayID: CGDirectDisplayID) {
        windows.removeValue(forKey: displayID)?.orderOut(nil)
        if windows.isEmpty, let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }
}

/// Keep a test window on its requested display even while macOS is settling
/// a new virtual display's HiDPI mode and arrangement.
private final class PatternWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private struct PatternView: View {
    var body: some View {
        TimelineView(.animation) { context in
            Canvas { g, size in
                let t = context.date.timeIntervalSinceReferenceDate
                g.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
                // Bouncing block — guarantees per-frame pixel changes.
                let x = (sin(t * 1.7) * 0.5 + 0.5) * (size.width - 140)
                let y = (cos(t * 2.3) * 0.5 + 0.5) * (size.height - 240) + 100
                g.fill(Path(roundedRect: CGRect(x: x, y: y, width: 140, height: 140), cornerRadius: 20),
                       with: .color(.blue))
                // Millisecond clock — lets a photo of both screens show lag.
                let ms = Int(t * 1000) % 1_000_000
                g.draw(Text("\(ms)").font(.system(size: 72, design: .monospaced)).foregroundStyle(.black),
                       at: CGPoint(x: size.width / 2, y: 60))
            }
        }
    }
}
