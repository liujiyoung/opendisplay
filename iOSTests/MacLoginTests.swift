import XCTest
import WebKit
import Network
@testable import OpenSidecariOS

@MainActor
final class MacLoginTests: XCTestCase {
    func testUSBModeDoesNotRequireOrUseANetworkHost() {
        let session = MacLoginSession()
        session.begin(host: "https://invalid.example/no-lan", username: "test",
                      password: "test-only", mode: .usb)
        XCTAssertTrue(session.started)
        XCTAssertEqual(session.mode, .usb)
        session.cancel()
        XCTAssertTrue(MacLoginTransport.isLoopback(.hostPort(host: "127.0.0.1", port: 9003)))
        XCTAssertFalse(MacLoginTransport.isLoopback(.hostPort(host: "192.168.0.1", port: 9003)))
    }

    func testUSBTransportWaitsForRelayGreetingThenExchangesUnmodifiedRFBBytes() {
        let ready = expectation(description: "USB relay greeting accepted")
        let inbound = expectation(description: "RFB server greeting delivered")
        let outbound = expectation(description: "RFB client bytes delivered")
        let closed = expectation(description: "USB transport closed")
        let queue = DispatchQueue(label: "usb-login-test-peer")
        let transport = MacLoginTransport(endpoint: nil, mode: .usb)
        let peer = NWConnection(host: "127.0.0.1", port: 9003, using: .tcp)
        transport.onReady = {
            ready.fulfill()
            transport.receive()
            transport.send(Data("client-rfb-bytes".utf8))
        }
        transport.onBytes = { data, consumed in
            XCTAssertEqual(data, Data("RFB 003.889\n".utf8))
            inbound.fulfill()
            consumed()
        }
        transport.onClose = { _ in closed.fulfill() }
        transport.start()
        peer.stateUpdateHandler = { state in
            if case .ready = state {
                // A short USB read must not leak the relay header into noVNC.
                peer.send(content: Data("ODLO".utf8), completion: .contentProcessed { _ in
                    queue.asyncAfter(deadline: .now() + 0.1) {
                        peer.send(content: Data("GIN1\nRFB 003.889\n".utf8), completion: .idempotent)
                    }
                })
                peer.receive(minimumIncompleteLength: 16, maximumLength: 16) { data, _, _, _ in
                    XCTAssertEqual(data, Data("client-rfb-bytes".utf8))
                    outbound.fulfill()
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 0.3) { peer.start(queue: queue) }
        wait(for: [ready, inbound, outbound], timeout: 8)
        transport.cancel()
        wait(for: [closed], timeout: 2)
        peer.cancel()
    }

    func testUSBTransportRejectsAnUnrecognizedRelayBeforeAuthentication() {
        let rejected = expectation(description: "bad USB relay rejected")
        let queue = DispatchQueue(label: "usb-login-bad-peer")
        let transport = MacLoginTransport(endpoint: nil, mode: .usb)
        let peer = NWConnection(host: "127.0.0.1", port: 9003, using: .tcp)
        transport.onReady = { XCTFail("must not start RFB without the USB relay greeting") }
        transport.onClose = { reason in
            if case .invalidUSBRelay = reason {} else { XCTFail("unexpected close reason") }
            rejected.fulfill()
        }
        transport.start()
        peer.stateUpdateHandler = { state in
            if case .ready = state {
                peer.send(content: Data("BADLOGIN\n".utf8), completion: .idempotent)
            }
        }
        queue.asyncAfter(deadline: .now() + 0.3) { peer.start(queue: queue) }
        wait(for: [rejected], timeout: 8)
        peer.cancel()
    }

    func testEndpointAcceptsHostsButRejectsURLsCredentialsAndPorts() {
        XCTAssertEqual(MacLoginEndpoint(" 192.168.1.10 ")?.host, "192.168.1.10")
        XCTAssertEqual(MacLoginEndpoint("mac-mini.local")?.host, "mac-mini.local")
        XCTAssertEqual(MacLoginEndpoint("fe80::1")?.host, "fe80::1")
        for invalid in ["", " ", "http://mac.local", "user@mac.local", "mac.local:22",
                        "192.168.1.10:5900", "mac.local/path", "mac.local?x=1", "two hosts"] {
            XCTAssertNil(MacLoginEndpoint(invalid), invalid)
        }
    }

    func testOfflineLoginBundleBootstrapsInEphemeralWebView() throws {
        let ready = expectation(description: "bundled login client initialized")
        let handler = BootstrapHandler(ready: ready)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(handler, name: "macLogin")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "LoginResources"))
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        wait(for: [ready], timeout: 15)
        XCTAssertNil(handler.failure)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        let greeting = expectation(description: "native byte pipe negotiates Apple RFB")
        handler.greeting = greeting
        // Split the server greeting as real TCP may do. No server or real
        // credentials are used; bytes written by RFB are captured by this test.
        view.evaluateJavaScript("""
            window.openDisplayLogin.start({username:'test', password:'test-only'});
            window.openDisplayLogin.receive('UkZC');
            window.openDisplayLogin.receive('IDAwMy44ODkK');
            """
        )
        wait(for: [greeting], timeout: 5)
        XCTAssertEqual(handler.outbound, Data("RFB 003.889\n".utf8))
        view.evaluateJavaScript("window.openDisplayLogin.stop()", completionHandler: nil)
        configuration.userContentController.removeScriptMessageHandler(forName: "macLogin")
        view.stopLoading()
    }

    func testLoginViewCanReleaseTheStreamingKeyboardResponder() {
        let keyboard = RemoteKeyboardView()
        XCTAssertTrue(keyboard.canBecomeFirstResponder)
        keyboard.setForwardingEnabled(false)
        XCTAssertFalse(keyboard.canBecomeFirstResponder)
        keyboard.focus()
        XCTAssertFalse(keyboard.isFirstResponder)
        keyboard.setForwardingEnabled(true)
        XCTAssertTrue(keyboard.canBecomeFirstResponder)
    }

    func testStreamingHandoffKeepsAuthenticatedLoginAndReusesItsWebView() {
        let session = MacLoginSession()
        session.begin(host: "192.0.2.1", username: "test", password: "test-only")
        let view = session.makeWebView()
        let generation = session.generation
        session.handle(["type": "authenticated"])

        // This used to cancel and destroy the RFB viewer on every dismissal,
        // letting macOS re-lock immediately after a successful unlock.
        session.leaveLogin()
        XCTAssertTrue(session.started)
        XCTAssertTrue(session.authenticated)
        XCTAssertFalse(session.visible)
        XCTAssertEqual(session.generation, generation)
        XCTAssertTrue(session.webView === view)

        session.appWillResignActive()
        XCTAssertTrue(session.authenticated)
        XCTAssertEqual(session.generation, generation)
        XCTAssertTrue(session.webView === view)

        // Video can be paused independently of the retained encrypted session.
        XCTAssertTrue(session.inputOnly)
        session.setInputOnly(false)
        XCTAssertFalse(session.inputOnly)
        session.setInputOnly(true)
        XCTAssertTrue(session.authenticated)
        XCTAssertEqual(session.generation, generation)
        XCTAssertTrue(session.webView === view)

        session.resumeLogin()
        XCTAssertTrue(session.visible)
        XCTAssertTrue(session.makeWebView() === view)
        session.appWillResignActive() // A visible login still closes on focus loss.
        XCTAssertFalse(session.started)
        XCTAssertFalse(session.authenticated)
        XCTAssertNil(session.webView)
        XCTAssertNotEqual(session.generation, generation)
        session.handle(["type": "authenticated"])
        XCTAssertFalse(session.authenticated)
    }

    func testLeavingAnUnfinishedLoginCancelsInsteadOfKeepingCredentials() {
        let session = MacLoginSession()
        session.begin(host: "192.0.2.1", username: "test", password: "test-only")
        let generation = session.generation
        session.leaveLogin()
        XCTAssertFalse(session.started)
        XCTAssertFalse(session.authenticated)
        XCTAssertNotEqual(session.generation, generation)
        XCTAssertNil(session.webView)
    }

    private final class BootstrapHandler: NSObject, WKScriptMessageHandler {
        let ready: XCTestExpectation
        var failure: String?
        var greeting: XCTestExpectation?
        var outbound: Data?
        init(ready: XCTestExpectation) { self.ready = ready }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "failure" { failure = body["value"] as? String; ready.fulfill() }
            if type == "ready" { ready.fulfill() }
            if type == "send", outbound == nil, let data = body["data"] as? String {
                outbound = Data(base64Encoded: data)
                greeting?.fulfill()
            }
        }
    }
}
