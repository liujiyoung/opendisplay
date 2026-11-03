import SwiftUI
import WebKit
import Network

/// A user-initiated bridge to macOS Screen Sharing, available before the sender's
/// Aqua LaunchAgent can run. FileVault must first be unlocked over SSH.
struct MacLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = MacLoginSession()
    @AppStorage("macLoginHost") private var host = ""
    @AppStorage("macLoginUsername") private var username = ""
    @State private var password = ""

    var body: some View {
        NavigationView {
            Group {
                if session.started {
                    VStack(spacing: 0) {
                        Text(session.status).font(.footnote).padding(8)
                            .frame(maxWidth: .infinity).background(Color(.secondarySystemBackground))
                        MacLoginWebView(session: session)
                        HStack(spacing: 24) {
                            Button("Tab") { session.sendKey(0xff09) }
                            Button("Return") { session.sendKey(0xff0d) }
                            Button("Esc") { session.sendKey(0xff1b) }
                            Spacer()
                            Button("重新连接") { session.cancel() }
                        }.padding(12)
                    }
                } else {
                    Form {
                        Section {
                            Text("冷启动后先通过 SSH 密码认证解锁 FileVault，再在这里完成 Mac 桌面登录。登录后会自动返回 OpenDisplay 画面。")
                        }
                        Section(header: Text("Mac 账户")) {
                            TextField("Mac 局域网 IP 或 .local 名称", text: $host)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .keyboardType(.URL).accessibilityIdentifier("macLoginHost")
                            TextField("Mac 用户名", text: $username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("macLoginUsername")
                            SecureField("Mac 登录密码", text: $password)
                                .textContentType(.password).accessibilityIdentifier("macLoginPassword")
                        }
                        Section(footer: Text("使用 Mac 已开启的屏幕共享（端口 5900）。只保存地址和用户名，密码不保存。两台设备需在可互访的局域网内。")) {
                            Button("连接登录画面") {
                                session.begin(host: host, username: username, password: password)
                                password = ""
                            }
                            .disabled(host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || username.isEmpty || password.isEmpty)
                            .accessibilityIdentifier("macLoginConnect")
                        }
                        if !session.status.isEmpty {
                            Section { Text(session.status).foregroundColor(.secondary) }
                        }
                    }
                }
            }
            .navigationTitle("Mac 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("返回 OpenDisplay") { session.cancel(); dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onDisappear { password = ""; session.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            password = ""
            session.cancel()
        }
    }
}

struct MacLoginEndpoint: Equatable {
    let host: String

    init?(_ input: String) {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        // No URLs, credentials, paths, or arbitrary destination ports. IPv6
        // literals are accepted; NWEndpoint.Host handles their interpretation.
        guard !value.isEmpty, value.utf8.count <= 253,
              !value.contains(where: { $0.isWhitespace || $0.isNewline }),
              !value.contains(where: { "/@?#\\".contains($0) }),
              !value.contains("://") else { return nil }
        if value.contains(":") {
            guard IPv6Address(value) != nil else { return nil }
        }
        self.host = value
    }
}

/// Queue-confined, back-pressured byte transport. No listener or new Mac daemon.
enum MacLoginTransportEnd {
    case network(NWError)
    case timedOut
    case serverClosed
    case queueLimit
    case cancelled

    func message(host: String, connected: Bool) -> String {
        switch self {
        case .network(let error):
            return connected
                ? "已连接 Mac，但登录连接中断：\(error.localizedDescription)"
                : "无法连接 \(host):5900：\(error.localizedDescription)。请核对 Mac 当前地址和屏幕共享。"
        case .timedOut:
            return "连接 \(host):5900 超时。Mac 的 IP 可能已变化；请核对当前地址，或使用 Mac 的 .local 主机名。"
        case .serverClosed:
            return "Mac 已关闭屏幕共享连接。如已完成登录，请返回 OpenDisplay；否则请重新连接。"
        case .queueLimit:
            return "登录连接发送积压过多，已停止；请重新连接。"
        case .cancelled:
            return "登录连接已关闭。"
        }
    }

    var diagnosticCode: String {
        switch self {
        case .network: return "network-error"
        case .timedOut: return "tcp-timeout"
        case .serverClosed: return "server-closed"
        case .queueLimit: return "send-queue-limit"
        case .cancelled: return "cancelled"
        }
    }
}

final class MacLoginTransport {
    private let queue = DispatchQueue(label: "opendisplay.mac-login")
    private let connection: NWConnection
    private var closed = false
    private var established = false
    private var pendingBytes = 0
    var onReady: (() -> Void)?
    var onBytes: ((Data, @escaping () -> Void) -> Void)?
    var onClose: ((MacLoginTransportEnd) -> Void)?

    init(endpoint: MacLoginEndpoint) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: 5900, using: parameters)
    }

    deinit { connection.cancel() }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                guard !self.established else { return }
                self.established = true
                self.onReady?()
            case .failed(let error): self.finish(.network(error))
            // A waiting path may recover (for example while Wi-Fi wakes).
            // The bounded connection deadline below remains in force.
            case .waiting: break
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, !self.established else { return }
            self.finish(.timedOut)
        }
    }

    /// Start reads only after JavaScript has attached its RFB handlers.
    func receive() {
        queue.async { [weak self] in self?.readNext() }
    }

    private func readNext() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty, let onBytes = self.onBytes {
                onBytes(data) { [weak self] in
                    guard let self else { return }
                    self.queue.async {
                        if let error { self.finish(.network(error)) }
                        else if complete { self.finish(.serverClosed) }
                        else { self.readNext() }
                    }
                }
            } else if let error { self.finish(.network(error)) }
            else if complete { self.finish(.serverClosed) }
            else { self.readNext() }
        }
    }

    func send(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            guard data.count <= 256 * 1024,
                  self.pendingBytes + data.count <= 1024 * 1024 else { self.finish(.queueLimit); return }
            self.pendingBytes += data.count
            self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                self.pendingBytes -= data.count
                if let error { self.finish(.network(error)) }
            })
        }
    }

    func cancel() { queue.async { [weak self] in self?.finish(.cancelled) } }

    private func finish(_ reason: MacLoginTransportEnd) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClose?(reason)
    }
}

final class MacLoginSession: NSObject, ObservableObject {
    @Published private(set) var started = false
    @Published private(set) var status = ""
    private var endpoint: MacLoginEndpoint?
    private var credentials: [String: String]?
    private var transport: MacLoginTransport?
    private var tcpConnected = false
    fileprivate private(set) var generation = UUID()
    weak var webView: WKWebView?

    func begin(host: String, username: String, password: String) {
        guard let endpoint = MacLoginEndpoint(host), !username.isEmpty, !password.isEmpty else {
            status = "请填写 Mac 的 IP 或主机名、用户名和登录密码。"
            return
        }
        cancel()
        self.endpoint = endpoint
        tcpConnected = false
        credentials = ["username": username, "password": password]
        status = "正在连接 Mac 登录画面…"
        started = true
    }

    func cancel() {
        generation = UUID()
        credentials = nil
        let old = transport
        transport = nil
        old?.cancel()
        webView?.evaluateJavaScript("window.openDisplayLogin?.stop()", completionHandler: nil)
        started = false
    }

    func sendKey(_ keysym: UInt32) {
        webView?.evaluateJavaScript("window.openDisplayLogin?.key(\(keysym))", completionHandler: nil)
    }

    func handle(_ body: Any) {
        guard started, let message = body as? [String: Any], let type = message["type"] as? String else { return }
        switch type {
        case "ready": connect()
        case "send":
            guard let text = message["data"] as? String, text.utf8.count <= 350_000,
                  let data = Data(base64Encoded: text) else { fail("登录连接数据无效，已停止。"); return }
            transport?.send(data)
        case "status":
            if let value = message["value"] as? String { status = String(value.prefix(300)) }
        case "failure":
            fail((message["value"] as? String) ?? "登录连接失败。")
        case "close":
            fail("登录连接已关闭。如已登录，请返回 OpenDisplay；否则请重新连接。")
        default: break
        }
    }

    private func fail(_ message: String) {
        cancel()
        status = message
    }

    private func connect() {
        guard transport == nil, let endpoint, credentials != nil else { return }
        let token = generation
        let socket = MacLoginTransport(endpoint: endpoint)
        transport = socket
        socket.onReady = { [weak self, weak socket] in
            DispatchQueue.main.async {
                guard let self, self.generation == token, let credentials = self.credentials,
                      let data = try? JSONSerialization.data(withJSONObject: credentials),
                      let json = String(data: data, encoding: .utf8), let webView = self.webView else { return }
                self.credentials = nil
                self.tcpConnected = true
                self.status = "已连接 Mac，正在协商屏幕共享认证…"
                Log.info("Mac login: TCP connected")
                webView.evaluateJavaScript("window.openDisplayLogin.start(\(json))") { [weak self, weak socket] _, error in
                    guard let self, self.generation == token else { return }
                    if error != nil { self.fail("无法启动登录画面，请重新连接。") }
                    else { socket?.receive() }
                }
            }
        }
        socket.onBytes = { [weak self] data, consumed in
            DispatchQueue.main.async {
                guard let self, self.generation == token, let webView = self.webView else { consumed(); return }
                // Base64's alphabet cannot terminate the JavaScript string.
                webView.evaluateJavaScript("window.openDisplayLogin.receive('\(data.base64EncodedString())')") { [weak self] _, error in
                    if let self, self.generation == token, error != nil { self.fail("登录画面处理失败，已停止。") }
                    consumed()
                }
            }
        }
        socket.onClose = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, self.generation == token else { return }
                Log.info("Mac login transport ended: \(reason.diagnosticCode), tcpConnected=\(self.tcpConnected)")
                self.fail(reason.message(host: endpoint.host, connected: self.tcpConnected))
            }
        }
        socket.start()
    }
}

private struct MacLoginWebView: UIViewRepresentable {
    let session: MacLoginSession

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "macLogin")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .black
        session.webView = view
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "LoginResources") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            session.handle(["type": "failure", "value": "登录画面资源缺失，请重新安装接收端。"])
        }
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "macLogin")
        uiView.navigationDelegate = nil
        uiView.stopLoading()
        uiView.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var session: MacLoginSession?
        private let generation: UUID
        init(session: MacLoginSession) { self.session = session; generation = session.generation }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, session?.generation == generation else { return }
            session?.handle(message.body)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(url?.isFileURL == true || url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            session?.handle(["type": "failure", "value": "无法载入登录画面。"])
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            session?.handle(["type": "failure", "value": "无法载入登录画面。"])
        }
    }
}
