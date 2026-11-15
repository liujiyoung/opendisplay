import Foundation
import Network
import Darwin

// Built as a separate executable. The sender's bundle and TCC identity never
// change. No framebuffer, password, username, or raw protocol data is logged.
enum Log {
    static func info(_ message: String) {
        fputs("\(ISO8601DateFormatter().string(from: Date())) \(message)\n", stderr)
    }
}

struct Configuration: Decodable {
    let deviceUDID: String
}

// All mutable state is confined to queue; async usbmux results re-enter queue.
final class USBLoginRelay: @unchecked Sendable {
    private let queue = DispatchQueue(label: "opendisplay.usb-login-relay")
    private let deviceUDID: String
    private let testDevicePort: UInt16?
    private let serverPort: UInt16
    private let once: Bool
    private var polling = false
    private var established = false
    private var generation = UUID()
    private var device: NWConnection?
    private var server: NWConnection?
    private var timer: DispatchSourceTimer?
    private var lastState = ""
    private var upBytes = 0
    private var downBytes = 0

    init(deviceUDID: String, testDevicePort: UInt16? = nil,
         serverPort: UInt16 = 5900, once: Bool = false) {
        self.deviceUDID = deviceUDID
        self.testDevicePort = testDevicePort
        self.serverPort = serverPort
        self.once = once
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        self.timer = timer
        timer.schedule(deadline: .now(), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        Log.info("USB login relay started; USB only, loopback Screen Sharing")
    }

    private func state(_ message: String) {
        guard message != lastState else { return }
        lastState = message
        Log.info(message)
    }

    private func poll() {
        guard !polling, device == nil else { return }
        polling = true
        established = false
        upBytes = 0
        downBytes = 0
        let token = UUID()
        generation = token
        // Bound discovery, USB handshake and local Screen Sharing startup.
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.generation == token, self.polling else { return }
            self.close("connection setup timeout")
        }
        if let port = testDevicePort {
            let connection = loopback(port)
            device = connection
            startDevice(connection, token: token)
            return
        }
        Task { [deviceUDID, queue, weak self] in
            do {
                let connection = try await Usbmux.dial(udid: deviceUDID, port: 9003, queue: queue)
                queue.async { [weak self] in
                    guard let self, self.generation == token else { connection.cancel(); return }
                    self.device = connection // Usbmux has already started this connection.
                    self.connectServer(token: token)
                }
            } catch {
                queue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.polling = false
                    self.generation = UUID()
                    self.state("waiting for trusted USB device and its login page")
                }
            }
        }
    }

    private func loopback(_ port: UInt16) -> NWConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.preferNoProxies = true
        return NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    private func startDevice(_ connection: NWConnection, token: UUID) {
        connection.stateUpdateHandler = { [weak self] status in
            guard let self, self.generation == token else { return }
            switch status {
            case .ready: self.connectServer(token: token)
            case .failed: self.close("USB connection ended")
            case .waiting: self.close("USB loopback connection unavailable")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func connectServer(token: UUID) {
        guard generation == token, server == nil else { return }
        let connection = loopback(serverPort)
        server = connection
        connection.stateUpdateHandler = { [weak self] status in
            guard let self, self.generation == token else { return }
            switch status {
            case .ready:
                connection.stateUpdateHandler = nil
                guard let device = self.device else { return }
                device.send(content: Data("ODLOGIN1\n".utf8), completion: .contentProcessed { [weak self] error in
                    guard let self, self.generation == token else { return }
                    guard error == nil else { self.close("USB greeting failed"); return }
                    self.polling = false
                    self.established = true
                    self.upBytes = 0
                    self.downBytes = 0
                    self.state("USB Screen Sharing byte pipe connected")
                    self.pump(from: device, to: connection, token: token, upstream: true)
                    self.pump(from: connection, to: device, token: token, upstream: false)
                })
            case .failed: self.close("local Screen Sharing unavailable")
            case .waiting: self.close("local Screen Sharing unavailable")
            default: break
            }
        }
        connection.start(queue: queue)
    }

    // Exactly one bounded read and one pending write per direction. Slow peers
    // apply backpressure instead of accumulating a login framebuffer in memory.
    private func pump(from source: NWConnection, to destination: NWConnection,
                      token: UUID, upstream: Bool) {
        guard generation == token else { return }
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.generation == token else { return }
            if let data, !data.isEmpty {
                if upstream { self.upBytes += data.count } else { self.downBytes += data.count }
                destination.send(content: data, completion: .contentProcessed { [weak self] writeError in
                    guard let self, self.generation == token else { return }
                    if writeError != nil || error != nil || complete { self.close("login connection ended") }
                    else { self.pump(from: source, to: destination, token: token, upstream: upstream) }
                })
            } else if error != nil || complete { self.close("login connection ended") }
            else { self.pump(from: source, to: destination, token: token, upstream: upstream) }
        }
    }

    private func close(_ reason: String) {
        let hadPipe = established
        generation = UUID()
        polling = false
        device?.stateUpdateHandler = nil
        server?.stateUpdateHandler = nil
        device?.cancel()
        server?.cancel()
        device = nil
        server = nil
        state("\(reason); bytes to Mac=\(upBytes), to iPad=\(downBytes)")
        if once { exit(hadPipe ? 0 : 1) }
    }
}

let arguments = CommandLine.arguments
let relay: USBLoginRelay
if arguments.count == 5, arguments[1] == "--test-loopback",
   let devicePort = UInt16(arguments[2]), let serverPort = UInt16(arguments[3]),
   arguments[4] == "--once", devicePort > 1024, serverPort > 1024 {
    // Explicit foreground-only harness: destinations remain loopback. Production
    // config cannot change the Screen Sharing target or USB port.
    relay = USBLoginRelay(deviceUDID: "test", testDevicePort: devicePort,
                          serverPort: serverPort, once: true)
} else if arguments.count == 3, arguments[1] == "--config" {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        guard config.deviceUDID.count >= 20, config.deviceUDID.count <= 80,
              config.deviceUDID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw NSError(domain: "USBLoginConfiguration", code: 1)
        }
        relay = USBLoginRelay(deviceUDID: config.deviceUDID)
    } catch {
        Log.info("invalid USB login configuration; no listener or relay started")
        exit(2)
    }
} else {
    fputs("Usage: opendisplay-usb-login-relay --config CONFIG.json\n", stderr)
    exit(2)
}
relay.start()
dispatchMain()
