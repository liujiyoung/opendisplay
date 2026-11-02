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
