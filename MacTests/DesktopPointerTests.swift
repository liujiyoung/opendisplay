import XCTest
import CoreGraphics

final class DesktopPointerTests: XCTestCase {
    private let monitor = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let ipad = CGRect(x: 1920, y: 0, width: 1194, height: 834)

    func testCrossesFromIPadToMonitorAndBack() {
        let screens = [monitor, ipad]
        let point = DesktopPointer.moved(from: CGPoint(x: 1930, y: 400), dx: -30, dy: 0, displays: screens)
        XCTAssertEqual(point, CGPoint(x: 1900, y: 400))
        XCTAssertEqual(DesktopPointer.moved(from: point!, dx: 30, dy: 0, displays: screens),
                       CGPoint(x: 1930, y: 400))
    }

    func testSupportsDisplaysLeftAndAboveMain() {
        let left = CGRect(x: -1194, y: -300, width: 1194, height: 834)
        XCTAssertEqual(DesktopPointer.moved(from: CGPoint(x: 5, y: 100), dx: -20, dy: 0,
                                           displays: [monitor, left]), CGPoint(x: -15, y: 100))
    }

    func testClampsToActualScreenRatherThanEmptyDesktopGap() {
        let point = DesktopPointer.moved(from: CGPoint(x: 1900, y: 1000), dx: 100, dy: 0,
                                        displays: [monitor, ipad])!
        XCTAssertTrue([monitor, ipad].contains { $0.contains(point) })
    }

    func testRejectsInvalidDeltasAndMissingDisplays() {
        XCTAssertNil(DesktopPointer.moved(from: .zero, dx: .nan, dy: 0, displays: [monitor]))
        XCTAssertNil(DesktopPointer.moved(from: .zero, dx: 1, dy: 0, displays: []))
        XCTAssertNil(DesktopPointer.moved(from: .zero, dx: 1e20, dy: 0, displays: [monitor]))
    }

    func testRawDoubleClickPairsKeepCountAndDraggingResetsIt() {
        var clicks = RemoteClickTracker()
        XCTAssertEqual(clicks.down(button: 0, time: 1, point: .zero), 1)
        XCTAssertEqual(clicks.up(button: 0, time: 1.1, point: .zero), 1)
        XCTAssertEqual(clicks.down(button: 0, time: 1.2, point: .zero), 2)
        XCTAssertEqual(clicks.up(button: 0, time: 1.3, point: CGPoint(x: 100, y: 0)), 2)
        XCTAssertEqual(clicks.down(button: 0, time: 1.4, point: CGPoint(x: 100, y: 0)), 1)
    }
}
