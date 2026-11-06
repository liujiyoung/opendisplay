import XCTest
import AVFoundation
import UIKit
@testable import OpenSidecariOS

@MainActor
final class VideoLayoutTests: XCTestCase {
    func testVideoRemainsFullSizeWhenInputSubviewPrecedesItsLayer() {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(),
                                      deviceKind: "iPad", fallbackServiceName: "Layout test")
        receiver.videoSize = CGSize(width: 2388, height: 1668)
        let view = VideoLayerView.VideoView(frame: CGRect(x: 0, y: 0, width: 1194, height: 834))
        view.receiver = receiver
        // This ordering caused the black screen: first sublayer is input,
        // so resizing sublayers.first sized a text view and left video at zero.
        view.addSubview(view.keyboardInput)
        view.videoLayer = receiver.displayLayer
        view.layer.addSublayer(receiver.displayLayer)
        view.setNeedsLayout()
        view.layoutIfNeeded()
        XCTAssertEqual(receiver.displayLayer.frame, view.bounds)
        XCTAssertEqual(view.keyboardInput.frame.size, CGSize(width: 1, height: 1))
    }

    func testHardwareResponderDoesNotOpenAnIPadInputMethod() {
        XCTAssertFalse((RemoteKeyboardView() as Any) is UITextInput)
    }
}

final class RelativePointerInputHealthTests: XCTestCase {
    func testIdleAndBackgroundDoNotTriggerInputRepairs() {
        var health = RelativePointerInputHealth()
        health.didBind(at: 0)
        XCTAssertFalse(health.shouldRebind(now: 100, capturing: true))
        health.uiMotion(at: 100)
        XCTAssertFalse(health.shouldRebind(now: 100, capturing: false))
        XCTAssertFalse(health.shouldRebind(now: 102, capturing: true))
    }

    func testRawAndUIKitMotionTogetherStayOnTheExistingBinding() {
        var health = RelativePointerInputHealth()
        health.didBind(at: 0)
        for i in 1...100 {
            let time = Double(i) / 10
            health.rawMotion(at: time)
            health.uiMotion(at: time + 0.01)
            XCTAssertFalse(health.shouldRebind(now: time + 0.02, capturing: true))
        }
    }

    func testContinuousUIKitMotionCanRepairSilentRawInputWithACooldown() {
        var health = RelativePointerInputHealth()
        health.didBind(at: 0)
        health.rawMotion(at: 0.1)
        health.uiMotion(at: 0.8)
        XCTAssertFalse(health.shouldRebind(now: 0.9, capturing: true))
        XCTAssertTrue(health.shouldRebind(now: 1, capturing: true))
        health.didBind(at: 1)
        health.uiMotion(at: 1.5)
        XCTAssertFalse(health.shouldRebind(now: 1.5, capturing: true))
        health.uiMotion(at: 2)
        XCTAssertTrue(health.shouldRebind(now: 2, capturing: true))
        health.rawMotion(at: 2)
        XCTAssertFalse(health.shouldRebind(now: 2.1, capturing: true))
    }
}
