import XCTest
import Network
import AVFoundation
import Combine

@MainActor
final class MacTargetRoutingTests: XCTestCase {
    func testChangingSelectionUpdatesTheReceiverAdvertisement() throws {
        let name = "OD routing \(UUID().uuidString.prefix(8))"
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPad",
                                      fallbackServiceName: name)
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_opensidecar._tcp", domain: nil),
                                using: .tcp)
        let first = UUID(), second = UUID()
        let firstAdvertisement = expectation(description: "first selection advertised")
        let secondAdvertisement = expectation(description: "advertisement reflects the new selection")
        var announced: Set<String> = []
        browser.browseResultsChangedHandler = { results, _ in
            DispatchQueue.main.async {
                for result in results {
                    guard case let .service(serviceName, _, _, _) = result.endpoint, name == serviceName,
                          case let .bonjour(txt) = result.metadata,
                          let id = txt[MacTargetRouting.selectionKey], announced.insert(id).inserted else { continue }
                    if id == first.uuidString { firstAdvertisement.fulfill() }
                    if id == second.uuidString { secondAdvertisement.fulfill() }
                }
            }
        }
        browser.start(queue: .main)
        defer { browser.cancel(); receiver.stop() }
        receiver.setServiceName(name)
        receiver.selectMac(first)
        receiver.start(port: UInt16.random(in: 22000...34000))
        wait(for: [firstAdvertisement], timeout: 8)
        receiver.selectMac(second)
        wait(for: [secondAdvertisement], timeout: 8)
    }

    func testSelectedMacSurvivesAnotherSenderAndCanBeSwitched() throws {
        let receiver = StreamReceiver(displayLayer: AVSampleBufferDisplayLayer(), deviceKind: "iPad",
                                      fallbackServiceName: "Mac selection test")
        let first = UUID(), second = UUID()
        let port = try XCTUnwrap(NWEndpoint.Port(rawValue: UInt16.random(in: 22000...34000)))
        let queue = DispatchQueue(label: "mac-selection-test")
        receiver.selectMac(first)
        let listening = expectation(description: "receiver listening")
        // Selecting publishes the first waiting event; listener ready publishes the second.
        let ready = receiver.$status.dropFirst().filter { $0 == "正在等待所选的 Mac…" }
            .dropFirst().prefix(1).sink { _ in listening.fulfill() }
        receiver.start(port: port.rawValue)
        wait(for: [listening], timeout: 5)

        func dial(_ id: UUID, rejected: XCTestExpectation? = nil) -> NWConnection {
            let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            func frame(_ type: String) -> Data {
                let payload = Data("{\"type\":\"\(type)\",\"senderMac\":\"\(id)\",\"screenLocked\":false}".utf8)
                return withUnsafeBytes(of: UInt32(payload.count).bigEndian) { Data($0) } + payload
            }
            let initial = frame(WireMessage.senderIdentity)
            let welcome = frame(WireMessage.welcome)
            conn.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                // Split the header and identity across writes, as a real TCP path can.
                conn.send(content: initial.prefix(6), completion: .contentProcessed { _ in
                    queue.asyncAfter(deadline: .now() + 0.05) {
                        conn.send(content: initial.dropFirst(6) + welcome, completion: .idempotent)
                    }
                })
                if let rejected {
                    func waitForEOF() {
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, complete, error in
                            if complete || error != nil { rejected.fulfill() } else { waitForEOF() }
                        }
                    }
                    waitForEOF()
                }
            }
            conn.start(queue: queue)
            return conn
        }
        defer { receiver.stop(); withExtendedLifetime(ready) {} }
        let receivedFirst = expectation(description: "first Mac selected")
        let firstObservation = receiver.$connectedMacID.filter { $0 == first }.prefix(1).sink { _ in receivedFirst.fulfill() }
        let firstConn = dial(first)
        defer { withExtendedLifetime(firstObservation) {}; firstConn.cancel() }
        wait(for: [receivedFirst], timeout: 5)

        let rejected = expectation(description: "other Mac rejected without replacing the first")
        let rejectedConn = dial(second, rejected: rejected)
        defer { rejectedConn.cancel() }
        wait(for: [rejected], timeout: 5)
        XCTAssertEqual(receiver.connectedMacID, first)
        XCTAssertTrue(receiver.connected)

        receiver.selectMac(second)
        let receivedSecond = expectation(description: "second Mac accepted after selection changes")
        let secondObservation = receiver.$connectedMacID.filter { $0 == second }.prefix(1).sink { _ in receivedSecond.fulfill() }
        let secondConn = dial(second)
        defer { withExtendedLifetime(secondObservation) {}; secondConn.cancel() }
        wait(for: [receivedSecond], timeout: 5)
    }
}
