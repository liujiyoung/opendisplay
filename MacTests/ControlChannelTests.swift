import XCTest
import Network

final class ControlChannelTests: XCTestCase {
    func testFramingSurvivesEveryByteBoundaryAndCoalescedMessages() throws {
        let messages = [Data("keyDown".utf8), Data("keyUp".utf8), Data("中文".utf8)]
        let wire = messages.reduce(into: Data()) { $0.append(ControlFrameDecoder.frame($1)!) }
        var decoder = ControlFrameDecoder()
        var received: [Data] = []
        for byte in wire { received += try decoder.append(Data([byte])) }
        XCTAssertEqual(received, messages)
        var batched = ControlFrameDecoder()
        XCTAssertEqual(try batched.append(wire), messages)
    }

    func testInvalidLengthsAreRejectedBeforeBodyAllocation() {
        for length: UInt32 in [0, 65_537, .max] {
            var header = length.bigEndian
            var decoder = ControlFrameDecoder()
            XCTAssertThrowsError(try decoder.append(Data(bytes: &header, count: 4)))
        }
        XCTAssertNil(ControlFrameDecoder.frame(Data()))
        XCTAssertNil(ControlFrameDecoder.frame(Data(count: 65_537)))
    }

    func testHandoffKeepsPressAndReleaseOrderedAcrossBarrier() {
        var handoff = ControlHandoff()
        XCTAssertEqual(handoff.route(Data([1])), .video)
        handoff.begin()
        XCTAssertEqual(handoff.route(Data([2])), .buffered)
        XCTAssertEqual(handoff.route(Data([3])), .buffered)
        XCTAssertEqual(handoff.activate(), [Data([2]), Data([3])])
        XCTAssertEqual(handoff.route(Data([4])), .dedicated)
        XCTAssertTrue(handoff.activate().isEmpty)
        handoff.reset()
        XCTAssertEqual(handoff.route(Data([5])), .video)
    }

    func testHandoffBoundsMemoryAndResetNeverReplaysOldInput() {
        var handoff = ControlHandoff()
        handoff.begin()
        XCTAssertEqual(handoff.route(Data(count: 262_144)), .buffered)
        XCTAssertEqual(handoff.route(Data([1])), .overflow)
        handoff.reset()
        handoff.begin()
        XCTAssertTrue(handoff.activate().isEmpty)
        handoff.reset()
        handoff.begin()
        for _ in 0..<512 { XCTAssertEqual(handoff.route(Data([1])), .buffered) }
        XCTAssertEqual(handoff.route(Data([1])), .overflow)
    }

    func testOfferRequiresValidPortAndSessionToken() {
        let token = UUID().uuidString
        XCTAssertEqual(ControlChannelOffer(port: 9002, token: token)?.port, 9002)
        for port in [nil, 0, -1, 65_536] as [Int?] { XCTAssertNil(ControlChannelOffer(port: port, token: token)) }
        for token in [nil, "", "another-session"] as [String?] { XCTAssertNil(ControlChannelOffer(port: 9002, token: token)) }
    }

    func testIndependentSocketPreservesReliableMessageOrder() throws {
        let queue = DispatchQueue(label: "test.control.owner")
        let ready = expectation(description: "listener ready")
        let replies = expectation(description: "ordered replies")
        replies.expectedFulfillmentCount = 100
        let listener = try NWListener(using: .tcp, on: .any)
        var server: ControlSocket?
        var client: ControlSocket?
        var received: [Int] = []
        defer { client?.cancel(); server?.cancel(); listener.cancel() }
        listener.newConnectionHandler = { conn in
            let socket = ControlSocket(connection: conn, owner: queue,
                onMessage: { socket, payload in socket.send(payload) }, onEnd: { _ in })
            server = socket
            socket.start()
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        client = ControlSocket(connection: NWConnection(host: "127.0.0.1", port: port, using: .tcp), owner: queue,
            onMessage: { _, payload in
                received.append(Int(String(decoding: payload, as: UTF8.self))!)
                replies.fulfill()
            }, onEnd: { _ in })
        client?.start {
            for i in 0..<100 { client?.send(Data(String(i).utf8)) }
        }
        wait(for: [replies], timeout: 5)
        XCTAssertEqual(received, Array(0..<100))
    }
}
