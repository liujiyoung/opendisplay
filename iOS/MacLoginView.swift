import SwiftUI
import WebKit
import Network

/// A user-initiated bridge to macOS Screen Sharing, available before the sender's
/// Aqua LaunchAgent can run. USB login requires the system relay and an unlocked
/// data volume (FileVault off, or already unlocked).
struct MacLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: MacLoginSession
    @AppStorage("macLoginHost") private var host = ""
    @AppStorage("macLoginUsername") private var username = ""
    @State private var password = ""
    @AppStorage("macLoginConnectionMode") private var connectionMode = MacLoginConnectionMode.usb.rawValue

    private var mode: MacLoginConnectionMode { MacLoginConnectionMode(rawValue: connectionMode) ?? .usb }

    var body: some View {
        NavigationView {
            Group {
                if session.started {
                    VStack(spacing: 0) {
                        Text(session.status).font(.footnote).padding(8)
                            .frame(maxWidth: .infinity).background(Color(.secondarySystemBackground))
                        inputOnlyToggle.padding(.horizontal, 16).padding(.vertical, 6)
                        MacLoginWebView(session: session).id(session.generation)
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
                            Text("USB 登录无需 Wi-Fi：数据线直连 iPad 机身，Mac 需已安装 USB 登录服务。冷启动前须关闭 FileVault，或先解锁磁盘。登录后自动恢复 OpenDisplay。")
                            Picker("连接方式", selection: $connectionMode) {
                                Text("USB 数据线").tag(MacLoginConnectionMode.usb.rawValue)
                                Text("局域网").tag(MacLoginConnectionMode.network.rawValue)
                            }.pickerStyle(.segmented)
                            inputOnlyToggle
                        }
                        Section(header: Text("Mac 账户")) {
                            if mode == .network {
                                TextField("Mac 局域网 IP 或 .local 名称", text: $host)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    .keyboardType(.URL).accessibilityIdentifier("macLoginHost")
                            }
                            TextField("Mac 用户名", text: $username)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("macLoginUsername")
                            SecureField("Mac 登录密码", text: $password)
                                .textContentType(.password).accessibilityIdentifier("macLoginPassword")
                        }
                        Section(footer: Text(mode == .usb
                            ? "使用已信任的 USB 数据线和 Mac 屏幕共享。无需地址或互联网；只保存用户名，密码不保存。"
                            : "使用 Mac 屏幕共享（端口 5900）。两端需能在局域网互访；只保存地址和用户名，密码不保存。")) {
                            Button("连接登录画面") {
                                session.begin(host: host, username: username, password: password, mode: mode)
                                password = ""
                            }
                            .disabled((mode == .network && MacLoginEndpoint(host) == nil)
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
                    Button("返回 OpenDisplay") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { session.resumeLogin() }
        .onDisappear { password = ""; session.leaveLogin() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            password = ""
        }
    }

    private var inputOnlyToggle: some View {
        Toggle("辅助盲输（暂停登录画面）", isOn: Binding(
            get: { session.inputOnly }, set: { session.setInputOnly($0) }))
            .accessibilityIdentifier("macLoginInputOnly")
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

enum MacLoginConnectionMode: String {
    case usb, network
}

/// Queue-confined, back-pressured byte transport. USB accepts the Mac relay
/// through usbmuxd on loopback only; it never falls back to a LAN destination.
enum MacLoginTransportEnd {
    case network(NWError)
    case timedOut
    case serverClosed
    case queueLimit
    case cancelled
    case invalidUSBRelay

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
        case .invalidUSBRelay:
            return "USB 登录服务版本不兼容，请更新 Mac USB 登录服务。"
        }
    }

    var diagnosticCode: String {
        switch self {
        case .network: return "network-error"
        case .timedOut: return "tcp-timeout"
        case .serverClosed: return "server-closed"
        case .queueLimit: return "send-queue-limit"
        case .cancelled: return "cancelled"
        case .invalidUSBRelay: return "invalid-usb-relay"
        }
    }
}

final class MacLoginTransport {
    private let queue = DispatchQueue(label: "opendisplay.mac-login")
    static let usbPort: UInt16 = 9003
    static let usbGreeting = Data("ODLOGIN1\n".utf8)
    private var connection: NWConnection?
    private var listener: NWListener?
    private let mode: MacLoginConnectionMode
    private var closed = false
    private var established = false
    private var pendingBytes = 0
    var onReady: (() -> Void)?
    var onBytes: ((Data, @escaping () -> Void) -> Void)?
    var onClose: ((MacLoginTransportEnd) -> Void)?

    init(endpoint: MacLoginEndpoint?, mode: MacLoginConnectionMode = .network) {
        self.mode = mode
        guard mode == .network, let endpoint else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        connection = NWConnection(host: NWEndpoint.Host(endpoint.host), port: 5900, using: parameters)
    }

    deinit { connection?.cancel(); listener?.cancel() }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.closed else { return }
            if self.mode == .usb { self.listenForUSBRelay() }
            else if let connection = self.connection { self.startConnection(connection) }
            self.queue.asyncAfter(deadline: .now() + (self.mode == .usb ? 45 : 15)) { [weak self] in
                guard let self, !self.established else { return }
                self.finish(.timedOut)
            }
        }
    }

    private func listenForUSBRelay() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.usbPort)!)
        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state { self?.finish(.network(error)) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, !self.closed, self.connection == nil,
                      Self.isLoopback(connection.endpoint) else { connection.cancel(); return }
                self.connection = connection
                self.startConnection(connection)
            }
            listener.start(queue: queue)
        } catch let error as NWError { finish(.network(error)) }
        catch { finish(.invalidUSBRelay) }
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        return host == NWEndpoint.Host("127.0.0.1") || host == NWEndpoint.Host("::1")
    }

    private func startConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, !self.closed, self.connection === connection else { return }
            switch state {
            case .ready:
                if self.mode == .usb {
                    connection.receive(minimumIncompleteLength: Self.usbGreeting.count,
                                       maximumLength: Self.usbGreeting.count) { [weak self] data, _, _, error in
                        guard let self, !self.closed else { return }
                        if let error { self.finish(.network(error)) }
                        else if data == Self.usbGreeting { self.markReady() }
                        else { self.finish(.invalidUSBRelay) }
                    }
                } else { self.markReady() }
            case .failed(let error): self.finish(.network(error))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func markReady() {
        guard !closed, !established else { return }
        established = true
        listener?.cancel()
        listener = nil
        onReady?()
    }

    /// Start reads only after JavaScript has attached its RFB handlers.
    func receive() {
        queue.async { [weak self] in self?.readNext() }
    }

    private func readNext() {
        guard !closed, let connection else { return }
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
            guard let self, !self.closed, let connection = self.connection else { return }
            guard data.count <= 256 * 1024,
                  self.pendingBytes + data.count <= 1024 * 1024 else { self.finish(.queueLimit); return }
            self.pendingBytes += data.count
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
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
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        onClose?(reason)
    }
}

final class MacLoginSession: NSObject, ObservableObject {
    @Published private(set) var started = false
    @Published private(set) var status = ""
    @Published private(set) var authenticated = false
    @Published private(set) var inputOnly = true
    private(set) var visible = true
    private var endpoint: MacLoginEndpoint?
    private(set) var mode: MacLoginConnectionMode = .network
    private var credentials: [String: String]?
    private var transport: MacLoginTransport?
    private var tcpConnected = false
    private(set) var generation = UUID()
    // Owned by the receiver screen, not the presented login view. Disconnecting
    // the last Screen Sharing viewer can re-lock the console it just unlocked.
    // Keep its encrypted session alive during foreground OpenDisplay use.
    private(set) var webView: WKWebView?

    override init() {
        super.init()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-usbLoginProbe") {
            Task { await USBLoginProbe.run() }
        }
        #endif
    }

    func begin(host: String, username: String, password: String, mode: MacLoginConnectionMode = .network) {
        let endpoint = MacLoginEndpoint(host)
        guard (mode == .usb || endpoint != nil), !username.isEmpty, !password.isEmpty else {
            status = "请填写 Mac 的 IP 或主机名、用户名和登录密码。"
            return
        }
        cancel()
        visible = true
        self.endpoint = endpoint
        self.mode = mode
        tcpConnected = false
        credentials = ["username": username, "password": password]
        status = mode == .usb ? "等待 USB 登录服务…请保持数据线直连 iPad 机身。" : "正在连接 Mac 登录画面…"
        started = true
    }

    func cancel() {
        generation = UUID()
        credentials = nil
        authenticated = false
        let old = transport
        transport = nil
        old?.cancel()
        started = false
        let oldView = webView
        webView = nil
        oldView?.configuration.userContentController.removeScriptMessageHandler(forName: "macLogin")
        oldView?.navigationDelegate = nil
        oldView?.stopLoading()
        oldView?.loadHTMLString("", baseURL: nil)
    }

    func resumeLogin() {
        visible = true
        webView?.evaluateJavaScript("window.openDisplayLogin?.setVisible(true)", completionHandler: nil)
    }

    func leaveLogin() {
        visible = false
        guard authenticated else { cancel(); return }
        // Hide input and stop framebuffer updates without closing the socket.
        // Reopening Mac Login reuses this same WebKit/RFB session, no password.
        webView?.evaluateJavaScript("window.openDisplayLogin?.setVisible(false)", completionHandler: nil)
        Log.info("Mac login: handed off to streaming; retaining authenticated connection")
    }

    func sendKey(_ keysym: UInt32) {
        guard visible, authenticated else { return }
        webView?.evaluateJavaScript("window.openDisplayLogin?.key(\(keysym))", completionHandler: nil)
    }

    func setInputOnly(_ value: Bool) {
        inputOnly = value
        webView?.evaluateJavaScript("window.openDisplayLogin?.setInputOnly(\(value))", completionHandler: nil)
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
        case "authenticated":
            authenticated = true
            Log.info("Mac login: encrypted session authenticated")
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
        guard transport == nil, (mode == .usb || endpoint != nil), credentials != nil else { return }
        let token = generation
        let socket = MacLoginTransport(endpoint: endpoint, mode: mode)
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
                webView.evaluateJavaScript("window.openDisplayLogin.start(\(json), {inputOnly: \(self.inputOnly)})") { [weak self, weak socket] _, error in
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
                if self.mode == .usb, !self.tcpConnected {
                    self.fail("USB 登录尚未建立。请确认数据线直连 iPad 机身、已信任 Mac，且 Mac 的 USB 登录服务已安装并运行。冷启动须关闭 FileVault 或先解锁磁盘。")
                } else {
                    self.fail(reason.message(host: self.endpoint?.host ?? "USB Mac", connected: self.tcpConnected))
                }
            }
        }
        socket.start()
    }

    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let coordinator = Coordinator(session: self)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(coordinator, name: "macLogin")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = coordinator
        view.scrollView.isScrollEnabled = false
        view.isOpaque = false
        view.backgroundColor = .black
        webView = view
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "LoginResources") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            handle(["type": "failure", "value": "登录画面资源缺失，请重新安装接收端。"])
        }
        return view
    }

    private final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
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
            guard session?.generation == generation else { return }
            session?.handle(["type": "failure", "value": "无法载入登录画面。"])
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard session?.generation == generation else { return }
            session?.handle(["type": "failure", "value": "无法载入登录画面。"])
        }
    }
}

private struct MacLoginWebView: UIViewRepresentable {
    let session: MacLoginSession

    func makeUIView(context: Context) -> WKWebView { session.makeWebView() }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    // Removing the view during handoff must not stop its authenticated session.
}

#if DEBUG
/// Developer-only real-device check: negotiate RFB through the USB relay,
/// then close before selecting authentication. Never sends credentials/input.
@MainActor
private final class USBLoginProbe {
    private var transport: MacLoginTransport?
    private var bytes: [UInt8] = []
    private var greeted = false
    private var done = false
    private var completion: (() -> Void)?

    static func run() async {
        let probe = USBLoginProbe()
        await probe.perform()
    }

    private func perform() async {
        await withCheckedContinuation { continuation in
            completion = { continuation.resume() }
            let transport = MacLoginTransport(endpoint: nil, mode: .usb)
            self.transport = transport
            transport.onReady = { [weak self] in
                DispatchQueue.main.async { self?.transport?.receive() }
            }
            transport.onBytes = { [weak self] data, consumed in
                DispatchQueue.main.async {
                    self?.accept(data)
                    consumed()
                }
            }
            transport.onClose = { [weak self] reason in
                DispatchQueue.main.async { self?.finish("failed: \(reason.diagnosticCode)") }
            }
            Log.info("USB login probe: started (no credentials or input)")
            transport.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.finish("failed: probe timeout")
            }
        }
    }

    private func accept(_ data: Data) {
        guard !done else { return }
        bytes.append(contentsOf: data)
        if !greeted {
            guard bytes.count >= 12 else { return }
            guard Array(bytes.prefix(12)) == Array("RFB 003.889\n".utf8) else {
                finish("failed: unexpected RFB greeting"); return
            }
            bytes.removeFirst(12)
            greeted = true
            transport?.send(Data("RFB 003.889\n".utf8))
        }
        guard let count = bytes.first else { return }
        guard count > 0, count <= 64 else { finish("failed: invalid RFB security offer"); return }
        if bytes.count >= Int(count) + 1 {
            finish("passed: USB RFB greeting and bidirectional negotiation (security types=\(count))")
        }
    }

    private func finish(_ result: String) {
        guard !done else { return }
        done = true
        Log.info("USB login probe: \(result)")
        transport?.cancel()
        transport = nil
        completion?()
        completion = nil
    }
}
#endif
