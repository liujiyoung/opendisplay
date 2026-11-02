import Foundation
import CoreGraphics

/// Global desktop points, including displays to the left/above the main one.
enum DesktopPointer {
    static func moved(from origin: CGPoint, dx: Double, dy: Double,
                      displays: [CGRect]) -> CGPoint? {
        guard origin.x.isFinite, origin.y.isFinite, dx.isFinite, dy.isFinite,
              abs(dx) <= 4096, abs(dy) <= 4096 else { return nil }
        let screens = displays.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard !screens.isEmpty else { return nil }
        let proposed = CGPoint(x: origin.x + dx, y: origin.y + dy)
        if screens.contains(where: { $0.contains(proposed) }) { return proposed }
        // Clamp to a real display, rather than the empty gaps in their union.
        return screens.map { screen in
            CGPoint(x: min(max(proposed.x, screen.minX), screen.maxX - 0.001),
                    y: min(max(proposed.y, screen.minY), screen.maxY - 0.001))
        }.min { a, b in
            hypot(a.x - proposed.x, a.y - proposed.y) < hypot(b.x - proposed.x, b.y - proposed.y)
        }
    }
}

/// Raw mouse callbacks don't include UIKit's tapCount.
struct RemoteClickTracker {
    private struct Click {
        let time: TimeInterval
        let point: CGPoint
        let count: Int
    }
    private var completed: [Int: Click] = [:]
    private var active: [Int: Click] = [:]

    mutating func down(button: Int, time: TimeInterval, point: CGPoint) -> Int {
        let previous = completed[button]
        let consecutive = previous.map {
            time >= $0.time && time - $0.time <= 0.5
                && hypot(point.x - $0.point.x, point.y - $0.point.y) <= 4
        } ?? false
        let count = consecutive ? min((previous?.count ?? 0) + 1, 3) : 1
        active[button] = Click(time: time, point: point, count: count)
        return count
    }

    mutating func up(button: Int, time: TimeInterval, point: CGPoint) -> Int {
        guard let click = active.removeValue(forKey: button) else { return 1 }
        if hypot(point.x - click.point.x, point.y - click.point.y) <= 4 {
            completed[button] = Click(time: time, point: point, count: click.count)
        } else { completed.removeValue(forKey: button) }
        return click.count
    }
}
