import SwiftUI
import Network
import Combine
import Sparkle
import SystemConfiguration

enum LocalMacTarget {
    static let id: UUID = {
        let key = "localMacTargetID"
        if let raw = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }()
    static var name: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "Mac" }
    static var host: String { (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" } ?? "" }

    // The discovery socket only publishes metadata. Actual login always goes
    // to macOS Screen Sharing on port 5900.
    static func advertise() -> NWListener? {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            var txt = NWTXTRecord()
            txt["role"] = MacTargetRouting.senderRole
            txt["id"] = id.uuidString
            txt["host"] = host
            listener.service = NWListener.Service(name: name, type: MacTargetRouting.service, txtRecord: txt)
            listener.newConnectionHandler = { $0.cancel() }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { Log.info("Mac discovery listener failed: \(error)") }
            }
            listener.serviceRegistrationUpdateHandler = { change in
                if case .add = change { Log.info("Mac selection Bonjour advertisement registered") }
            }
            listener.start(queue: .main)
            return listener
        } catch {
            Log.info("Mac discovery listener unavailable: \(error)")
            return nil
        }
    }
}

/// How the app presents itself. One bundle, switched at runtime via the
/// activation policy — like Raycast/Hammerspoon style background agents.
enum AppPresentation: String, CaseIterable {
    case menuBar, dock, background

    var label: String {
        switch self {
        case .menuBar: return "Menu bar"
        case .dock: return "Dock"
        case .background: return "Background only"
        }
    }
}

@main
struct OpenSidecarMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = SenderController.shared

    var body: some Scene {
        MenuBarExtra(isInserted: Binding(
            get: { controller.presentation == .menuBar },
            set: { _ in }
        )) {
            ContentView(controller: controller, updater: appDelegate.updater)
        } label: {
            Image(systemName: controller.running
                  ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Sparkle's standard updater. `startingUpdater: true` boots the updater
    // immediately so scheduled background checks (SUEnableAutomaticChecks)
    // run; the menu item drives manual "Check for Updates…". Held for the
    // app's lifetime here so every window (menu bar + control window) shares
    // one updater instance.
    let updater = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hand the updater to the control window, which is built outside the
        // SwiftUI App scene (NSHostingView), so it can offer the same button.
        MainWindow.updater = updater
        let presentation = SenderController.shared.presentation
        NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
        if presentation != .menuBar {
            MainWindow.show()
        }
    }

    // Background/Dock modes: opening the app again (Spotlight, Finder, Dock
    // click) brings up the control window — Hammerspoon-style.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        MainWindow.show()
        return false
    }
}

/// The control panel as a regular window, for Dock/background presentation.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    // Set once at launch by AppDelegate so the control window can share the
    // app's single Sparkle updater.
    static var updater: SPUStandardUpdaterController?

    static func show() {
        if window == nil {
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false)
            w.title = "OpenDisplay"
            w.contentView = NSHostingView(
                rootView: ContentView(controller: SenderController.shared,
                                      updater: updater))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum ConnectionTarget: Hashable {
    case usb(udid: String?)           // wired via built-in usbmuxd; nil = first device
    case wifi(NWBrowser.Result)       // discovered via Bonjour
    case peerWiFi(NWBrowser.Result, NWInterface)

    var service: NWBrowser.Result? {
        switch self {
        case .usb: return nil
        case .wifi(let result), .peerWiFi(let result, _): return result
        }
    }

    var peerRoute: (NWEndpoint, NWInterface)? {
        guard case .peerWiFi(let result, let interface) = self,
              case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
        return (.service(name: name, type: type, domain: domain, interface: interface), interface)
    }

    /// Stable identity for sessions and persistence — survives Bonjour
    /// re-discovery (fresh NWBrowser.Result) and USB replugs (new DeviceID).
    var sessionID: String {
        switch self {
        case .usb(let udid): return "usb:\(udid ?? "first")"
        case .wifi(let result):
            if case .service(let name, _, _, _) = result.endpoint { return "wifi:\(name)" }
            return "wifi:unknown"
        case .peerWiFi(let result, _):
            return "peer:\(ConnectionTarget.wifi(result).sessionID)"
        }
    }
}

enum ConnectionChoice: String, CaseIterable {
    case automatic = "Auto"
    case usb = "USB"
    case wifi = "Wi-Fi"
    case sidecar = "随航"
}

/// One connected (or connecting) device: its target, its sender pipeline,
/// and the per-device status the UI shows. Each session owns a full pipeline
/// — virtual display, capture, encoder, socket — so devices are independent:
/// one disconnecting never stalls the others.
@MainActor
final class DeviceSession: ObservableObject, Identifiable {
    nonisolated let id: String
    let target: ConnectionTarget
    let name: String
    let sender: MacSender

    @Published var status = "Starting…"
    @Published var framesSent = 0
    // The sender's start() threw: the pipeline is freed, only this row's
    // error text remains. A failed session must never swallow a fresh
    // connect for its device the way a live one does.
    @Published var failed = false
    // Receiver's per-install identity (from hello) — the key for recognizing
    // the same physical device across USB and WiFi.
    var deviceID: String?
    // "iPhone" / "iPad" from hello — naming fallback while (or in case)
    // lockdown hasn't resolved the device's real name.
    var deviceKind: String?
    // Power actions the receiver offers on the live path (PROTOCOL.md 6.6).
    // Every hello replaces it, so it follows the session on and off the cable.
    @Published var powerActions: [PowerAction] = []
    // `target` names the identity the session was created for; the live
    // transport can migrate (cable-in upgrade, unplug failover) — these
    // track where the sender actually is right now.
    @Published var onUSB: Bool
    @Published var onPeerWiFi = false
    // The udid the session is (or was last) cabled through, so a usbmuxd
    // detach can be matched back to this session for failover.
    var usbUDID: String?
    // The Bonjour service name this session was started from or failed over
    // to. Kept because browse results routinely arrive without their TXT
    // record (no install id to match on) and the USB device is detached
    // after a failover — the name is then the only link between the session
    // and its service row.
    var wifiServiceName: String?

    // The live TCP path runs over a cable (Thunderbolt Bridge / Ethernet)
    // rather than WiFi — reported by the sender once connected.
    @Published var wired = false

    var transportLabel: String {
        if onUSB { return "USB" }
        if onPeerWiFi { return "Wi-Fi 直连" }
        return wired ? "Cable" : "Wi-Fi"
    }

    // The Display size control (extend only): the choice for this device
    // and what each choice gives on it, from the latest hello.
    private var lastHello: PhoneInfo?
    @Published private(set) var displaySize: DisplaySize = .default
    @Published private(set) var displaySizeOutcomes: [DisplaySizeOutcome] = []

    func helloArrived(_ info: PhoneInfo) {
        lastHello = info
        refreshDisplaySize()
    }

    func setDisplaySize(_ size: DisplaySize) {
        guard let info = lastHello else { return }
        sender.setDisplaySize(size, for: info)
        refreshDisplaySize()
    }

    /// Also called when the picker opens: the outcomes can change without a
    /// hello (an HEVC failure, a refused 2x mode).
    func refreshDisplaySize() {
        guard let info = lastHello else { return }
        displaySize = DisplaySizeStore.load(key: sender.displaySizeKey(for: info))
        let outcomes = sender.displaySizeOutcomes(for: info)
        if outcomes != displaySizeOutcomes { displaySizeOutcomes = outcomes }
    }

    init(id: String, target: ConnectionTarget, name: String, sender: MacSender) {
        self.id = id
        self.target = target
        self.name = name
        self.sender = sender
        if case .usb(let udid) = target {
            onUSB = true
            usbUDID = udid
        } else {
            onUSB = false
        }
        onPeerWiFi = target.peerRoute != nil
    }
}

@MainActor
final class SenderController: ObservableObject {
    static let shared = SenderController()

    @Published var presentation = AppPresentation(
        rawValue: UserDefaults.standard.string(forKey: "presentation") ?? "") ?? .menuBar {
        didSet {
            UserDefaults.standard.set(presentation.rawValue, forKey: "presentation")
            NSApp.setActivationPolicy(presentation == .dock ? .regular : .accessory)
            // Never strand the user without UI: leaving menu-bar mode opens
            // the window immediately.
            if presentation != .menuBar { MainWindow.show() }
        }
    }

    @Published var sessions: [DeviceSession] = []
    @Published var discovered: [NWBrowser.Result] = []
    // Every cabled device: usbmuxd's iPhones and iPads plus Android devices
    // in accessory mode (udid `aoa:<serial>`). The connection policy treats
    // them alike.
    @Published var usbDevices: [UsbmuxDevice] = []
    private var usbmuxDevices: [UsbmuxDevice] = []
    private var accessoryDevices: [UsbmuxDevice] = []
    // `-host x.x.x.x` / `-port n` bypass usbmuxd with a manual TCP endpoint
    // (debugging escape hatch, e.g. an iproxy or SSH tunnel).
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "127.0.0.1"
    @Published var port = UserDefaults.standard.string(forKey: "port") ?? "9000"
    // `-mode mirror` / `-mode extend` launch argument also works.
    @Published var mode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .extend
    @Published var quality = StreamQuality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .best {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "quality") }
    }
    @Published var adaptiveBitrateEnabled = AdaptiveVideoBitratePreference.isEnabled() {
        didSet {
            AdaptiveVideoBitratePreference.save(enabled: adaptiveBitrateEnabled)
            sessions.forEach { $0.sender.setAdaptiveBitrateEnabled(adaptiveBitrateEnabled) }
        }
    }
    @Published var capsLockSwitchesInputSource = CapsLockInputSourcePreference.isEnabled() {
        didSet {
            CapsLockInputSourcePreference.save(enabled: capsLockSwitchesInputSource)
            sessions.forEach { $0.sender.setCapsLockSwitchesInputSource(capsLockSwitchesInputSource) }
        }
    }

    @Published private(set) var connectionChoice: ConnectionChoice = .automatic
    @Published private(set) var peerWiFiTargets: [ConnectionTarget] = []
    @Published private(set) var peerWiFiStatus = ""
    @Published private(set) var sidecarDevices: [SystemSidecar.Device] = []
    @Published private(set) var sidecarDevice: SystemSidecar.Device?
    @Published private(set) var sidecarStatus = ""
    @Published private(set) var switchingConnection = false
    private lazy var sidecar = SystemSidecar()
    private var sidecarStandby: VirtualDisplay?
    private var sidecarMonitor: Task<Void, Never>?
    private var suspendedTargets: [ConnectionTarget] = []

    var running: Bool { !sessions.isEmpty || sidecarDevice != nil }

    private var browser: NWBrowser?
    private var peerWiFiBrowser: NWBrowser?
    private var macTargetService: NWListener?
    private var policyTimer: Timer?
    private var usbWatcher: UsbmuxDeviceWatcher?
    private var accessoryWatcher: AccessoryDeviceWatcher?

    // Connection policy — one session per physical device, and the cable
    // wins whenever it's available (lower, steadier latency than WiFi):
    //
    //  - USB devices connect on attach ("plug in and go") unless the user
    //    explicitly disconnected them once (usbDisabled).
    //  - Plugging the cable in while the device streams over WiFi migrates
    //    the live session onto USB; unplugging it fails over to WiFi when
    //    the device's service is visible — otherwise the session ends after
    //    the usual grace. Migrations swap only the socket (switchTransport):
    //    the virtual display survives, so no screen flash, no window
    //    reshuffle — the earlier no-switching policy existed because
    //    migration used to mean destroying and recreating the session.
    //  - WiFi devices the user connected before (wifiRemembered) reconnect
    //    in a short window at LAUNCH. The opt-in headless launcher keeps
    //    waiting for those remembered devices with -autoReconnectWiFi YES.
    // `-autostart NO` disables all auto-connecting, including migrations.
    private var usbDisabled = Set(UserDefaults.standard.stringArray(forKey: "usbDisabled") ?? []) {
        didSet { UserDefaults.standard.set(Array(usbDisabled), forKey: "usbDisabled") }
    }
    private var wifiRemembered = Set(UserDefaults.standard.stringArray(forKey: "wifiRemembered") ?? []) {
        didSet { UserDefaults.standard.set(Array(wifiRemembered), forKey: "wifiRemembered") }
    }
    private var rememberedPeerIDs = Set(UserDefaults.standard.stringArray(forKey: "rememberedPeerIDs") ?? []) {
        didSet { UserDefaults.standard.set(Array(rememberedPeerIDs), forKey: "rememberedPeerIDs") }
    }
    // Install id learned from each USB device's hello, persisted, so the
    // same hardware is recognized across transports even when the user
    // renamed the advertised service. @Published so the device list regroups
    // the moment an identity is learned.
    @Published private var installIDByUDID: [String: String] =
        UserDefaults.standard.dictionary(forKey: "installIDByUDID") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(installIDByUDID, forKey: "installIDByUDID") }
    }
    private let autoConnectEnabled = UserDefaults.standard.object(forKey: "autostart") == nil
        || UserDefaults.standard.bool(forKey: "autostart")
    private let autoReconnectWiFi = UserDefaults.standard.bool(forKey: "autoReconnectWiFi")

    // Bonjour usually reports devices before usbmuxd does — WiFi reconnects
    // wait out this window so a cabled device is dialed over USB first. The
    // deadline closes the window for good: a remembered WiFi device that
    // appears later was brought near the Mac mid-session, which is a user
    // action to confirm, not auto-grab. The headless opt-in removes this
    // deadline only for previously remembered receivers; Disconnect still
    // removes a device from that list.
    private var wifiAutoConnectArmed = false
    private let wifiAutoConnectDeadline = Date().addingTimeInterval(12)
    // Services whose Bonjour record is currently seen over the direct
    // host-to-host cable. Plugging that cable in is a deliberate act, so a
    // record newly gaining such an interface connects like a cabled iPhone
    // does; plain WiFi discovery never grabs a (possibly shared) receiver
    // after the launch window. Transition-based, so a record that stays on
    // the cable connects once, not on every browse update.
    private var onDirectCable: Set<String> = []
    // Service names the user disconnected while cabled. The record can
    // vanish and return without a replug (the receiver's display sleeps and
    // wakes, it restarts), and a cable-only receiver's unplug looks the
    // same, so the opt-out simply holds until the user connects by hand.
    // In memory: a relaunched sender starts fresh.
    private var cableOptOut: Set<String> = []
    // Accessory-mode devices whose receiver app quit (`closing`). Dialing one
    // opens the app again, so the next wired-list change must not redial it:
    // the opt-out holds until the device is unplugged or the user connects it.
    // In memory, like cableOptOut.
    private var receiverClosedOnCable: Set<String> = []
    // Every service seen on the cable this run: a Disconnect counts as a
    // cable opt-out even while the record is briefly gone (receiver asleep).
    private var everOnCable: Set<String> = []

    init() {
        macTargetService = LocalMacTarget.advertise()
        startBrowsing()
        updatePeerWiFiBrowsing()
        usbWatcher = UsbmuxDeviceWatcher { [weak self] devices in
            self?.usbmuxDevices = devices
            self?.wiredDevicesChanged()
        }
        accessoryWatcher = AccessoryDeviceWatcher { [weak self] devices in
            self?.accessoryDevices = devices
            self?.wiredDevicesChanged()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            self.wifiAutoConnectArmed = true
            self.autoConnect()
        }
        if autoConnectEnabled {
            policyTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.updatePeerWiFiBrowsing()
                    self?.autoConnect()
                }
            }
        }
    }

    private func startBrowsing() {
        // TXT records carry the receiver's install id (new receivers).
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MacTargetRouting.service, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.discovered = results.filter { !Self.isMacAdvertisement($0) }
                self.retireUnselectedWirelessSessions(in: self.discovered)
                self.endSessionsWhoseServiceVanished()
                self.autoConnect()
                self.connectNewlyCabled()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func updatePeerWiFiBrowsing() {
        guard connectionChoice != .sidecar, autoConnectEnabled || connectionChoice == .wifi else {
            peerWiFiBrowser?.cancel()
            peerWiFiBrowser = nil
            peerWiFiTargets = []
            return
        }
        guard peerWiFiBrowser == nil else { return }
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MacTargetRouting.service, domain: nil),
                                using: params)
        peerWiFiStatus = ""
        peerWiFiBrowser = browser
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            DispatchQueue.main.async {
                guard let self, let browser, self.peerWiFiBrowser === browser else { return }
                // includePeerToPeer also discovers LAN services. Offer only
                // advertisements received on the Apple peer-to-peer link.
                var targets: [String: ConnectionTarget] = [:]
                for result in results {
                    guard !Self.isMacAdvertisement(result),
                          let interface = result.interfaces.first(where: { $0.name == "awdl0" }),
                          self.serviceName(of: result) != nil else { continue }
                    let target = ConnectionTarget.peerWiFi(result, interface)
                    targets[target.sessionID] = target
                }
                self.peerWiFiTargets = targets.values.sorted { $0.sessionID < $1.sessionID }
                self.retireUnselectedWirelessSessions(in: self.peerWiFiTargets.compactMap(\.service))
                self.autoConnect()
            }
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            DispatchQueue.main.async {
                guard let self, let browser, self.peerWiFiBrowser === browser else { return }
                switch state {
                case .ready: self.peerWiFiStatus = ""
                case .waiting(let error):
                    self.peerWiFiStatus = "直连发现失败：\(error.localizedDescription)"
                case .failed(let error):
                    self.peerWiFiStatus = "直连发现失败：\(error.localizedDescription)"
                    self.peerWiFiBrowser = nil
                    self.peerWiFiTargets = []
                    browser.cancel()
                default: break
                }
            }
        }
        browser.start(queue: .main)
    }

    func refreshPeerWiFi() {
        peerWiFiBrowser?.cancel()
        peerWiFiBrowser = nil
        peerWiFiTargets = []
        updatePeerWiFiBrowsing()
    }

    // MARK: - Physical-device identity

    private static func isMacAdvertisement(_ result: NWBrowser.Result) -> Bool {
        if case .bonjour(let txt) = result.metadata { return txt["role"] == MacTargetRouting.senderRole }
        return false
    }

    private func serviceName(of result: NWBrowser.Result) -> String? {
        if case .service(let name, _, _, _) = result.endpoint { return name }
        return nil
    }

    private func txtID(of result: NWBrowser.Result) -> String? {
        if case .bonjour(let txt) = result.metadata { return txt["id"] }
        return nil
    }

    private func sameReceiver(_ first: NWBrowser.Result, _ second: NWBrowser.Result) -> Bool {
        if let id = txtID(of: first), let otherID = txtID(of: second) { return id == otherID }
        guard let name = serviceName(of: first) else { return false }
        return name == serviceName(of: second)
    }

    private func installID(of session: DeviceSession) -> String? {
        session.deviceID ?? session.target.service.flatMap(txtID)
            ?? session.usbUDID.flatMap { installIDByUDID[$0] }
    }

    /// Bonjour can deliver the LAN record without TXT during a handoff.
    /// Keep matching the active pipeline by its known service name or by the
    /// same receiver's AWDL advertisement until the LAN record has its id.
    private func matches(_ result: NWBrowser.Result, session: DeviceSession) -> Bool {
        let peerID = installID(of: session)
        if let id = txtID(of: result), let peerID { return id == peerID }
        guard let name = serviceName(of: result) else { return false }
        if name == session.wifiServiceName || name == session.name
            || name == session.target.service.flatMap(serviceName) { return true }
        if let peerID, let peerService = peerTarget(for: peerID)?.service,
           name == serviceName(of: peerService) { return true }
        return session.usbUDID.flatMap { udid in usbDevices.first { $0.udid == udid }?.name } == name
    }

    /// Same hardware? Strong match: the service's install id equals the id
    /// this USB device announced in a (past or present) hello. Fallback for
    /// old receivers: lockdown device name equals the service name.
    private func sameDevice(_ result: NWBrowser.Result, _ device: UsbmuxDevice) -> Bool {
        if let id = txtID(of: result), let otherID = installIDByUDID[device.udid] { return otherID == id }
        if let name = serviceName(of: result), let usbName = device.name,
           usbName == name { return true }
        return false
    }

    /// The session (over either transport) already serving this USB device.
    /// A failed session serves nothing — it must not block auto-connecting
    /// the same physical device over the other transport.
    private func activeSession(coveringUSB device: UsbmuxDevice) -> DeviceSession? {
        if let direct = session(for: "usb:\(device.udid)"), !direct.failed { return direct }
        return sessions.first { s in
            guard !s.failed else { return false }
            if s.usbUDID == device.udid { return true }
            if let id = installIDByUDID[device.udid], let peerID = installID(of: s) { return peerID == id }
            guard let result = s.target.service else { return false }
            return sameDevice(result, device)
        }
    }

    /// The session (over either transport) already serving this WiFi service.
    /// Failed sessions are excluded for the same reason as above.
    private func activeSession(coveringWiFi result: NWBrowser.Result) -> DeviceSession? {
        sessions.first { !$0.failed && matches(result, session: $0) }
    }

    // MARK: - Connection policy

    func selectConnection(_ choice: ConnectionChoice) async {
        guard choice != connectionChoice, !switchingConnection else { return }
        if choice == .sidecar {
            connectionChoice = choice
            sessions.forEach { $0.sender.pausePeerWiFiProbing() }
            updatePeerWiFiBrowsing()
            refreshSidecarDevices()
            return
        }
        if let device = sidecarDevice, let sidecar {
            switchingConnection = true
            defer { switchingConnection = false }
            do {
                try await sidecar.setConnected(false, device: device)
            } catch {
                sidecarStatus = error.localizedDescription
                Log.info("Sidecar disconnect failed: \(error)")
                return
            }
        }
        resumeOpenDisplay(choice)
    }

    func refreshSidecarDevices() {
        guard !switchingConnection, sidecarDevice == nil else { return }
        sidecarDevices = sidecar?.devices() ?? []
        if sidecar == nil {
            sidecarStatus = SystemSidecar.Failure.unavailable.localizedDescription
        } else if sidecarDevices.isEmpty {
            sidecarStatus = "No Sidecar iPads found. Unlock the iPad and try again."
        } else {
            sidecarStatus = ""
        }
    }

    func connectSidecar(_ device: SystemSidecar.Device) async {
        guard connectionChoice == .sidecar, !switchingConnection,
              sidecarDevice == nil, let sidecar else { return }
        switchingConnection = true
        sidecarStatus = "Connecting…"
        let previousTargets = sessions.filter { !$0.failed }.map(currentTarget)
        defer { switchingConnection = false }
        let alreadyConnected = sidecar.isConnected(device)
        let beforeConnect = SidecarDisplayArrangement.onlineDisplays()
        let openDisplays = sessions.compactMap { $0.sender.displayForSidecarHandoff }
            .filter { beforeConnect.contains($0.displayID) }
        let openDisplayIDs = Set(openDisplays.map(\.displayID))
        let otherDisplays = beforeConnect.subtracting(openDisplayIDs)
        // Retain a monitor WindowServer already accepted. Do not create
        // another virtual display just to replace this one after connecting.
        let standby = otherDisplays.count <= (alreadyConnected ? 1 : 0) ? openDisplays.first : nil
        do {
            Log.info("Requesting system Sidecar; retaining display id=\(standby?.displayID.description ?? "none")")
            try await sidecar.setConnected(true, device: device)
            if let standby {
                standby.suspendOriginTrackingForSidecar()
                try await SidecarDisplayArrangement.makeSidecarPrimary(
                    excluding: alreadyConnected ? openDisplayIDs : beforeConnect)
            }
            guard sidecar.isConnected(device) else { throw SystemSidecar.Failure.deviceGone }
            sidecarStandby = standby
            sidecarDevice = device
            sidecarStatus = "Connected via Sidecar"
            Log.info("System Sidecar connected")
            suspendedTargets = previousTargets
            // Only retire the old displays once macOS reports Sidecar active.
            // Keep the normal auto-connect records for the return trip.
            sessions.forEach { end($0) }
            updatePeerWiFiBrowsing()
            observeSidecar(device)
        } catch {
            standby?.restoreOriginAfterFailedSidecarHandoff()
            if !alreadyConnected, sidecar.isConnected(device) {
                try? await sidecar.setConnected(false, device: device)
            }
            sidecarStatus = error.localizedDescription
            Log.info("Sidecar connect failed: \(error)")
        }
    }

    var currentOpenDisplayConnectionLabel: String? {
        let transports = Set(sessions.filter { !$0.failed }.map(\.transportLabel)).sorted()
        return transports.isEmpty ? nil : transports.joined(separator: " · ")
    }

    private func observeSidecar(_ device: SystemSidecar.Device) {
        sidecarMonitor?.cancel()
        sidecarMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.sidecarDevice == device, let sidecar = self.sidecar else { return }
                if !self.switchingConnection, !sidecar.isConnected(device) {
                    Log.info("System Sidecar ended — waiting for a manual selection")
                    self.sidecarDevice = nil
                    self.sidecarStatus = "Sidecar disconnected."
                    self.refreshSidecarDevices()
                    return
                }
            }
        }
    }

    private func resumeOpenDisplay(_ choice: ConnectionChoice) {
        let targets = suspendedTargets
        sidecarMonitor?.cancel()
        sidecarMonitor = nil
        sidecarDevice = nil
        sidecarStandby = nil
        suspendedTargets.removeAll()
        sidecarStatus = ""
        connectionChoice = choice
        updatePeerWiFiBrowsing()
        autoConnect()
        for target in targets where isAvailable(target) { connect(to: target) }
    }

    func connectionTarget(for entry: DeviceEntry) -> ConnectionTarget? {
        switch connectionChoice {
        case .usb: return entry.usbTarget
        case .wifi: return entry.wifiTarget
        case .automatic, .sidecar: return entry.preferredTarget
        }
    }

    private func autoConnect() {
        guard autoConnectEnabled, connectionChoice != .sidecar else { return }
        dedupeSessions()
        // The -host/-port escape hatch is an explicit choice — dial it like
        // the wired devices (it joins them, not replaces them).
        if UserDefaults.standard.object(forKey: "host") != nil,
           !usbDisabled.contains("usb:first"), session(for: "usb:first") == nil {
            connect(to: .usb(udid: nil))
        }
        for device in usbDevices {
            // Not even a cable upgrade: the dial would reopen the app.
            guard !receiverClosedOnCable.contains(device.udid) else { continue }
            if let covering = activeSession(coveringUSB: device) {
                // usbDisabled gates auto-connecting a device, not the
                // transport of a session the user deliberately has running —
                // however it was started, the cable is better: take it.
                upgradeToUSB(covering, device: device)
            } else if !usbDisabled.contains("usb:\(device.udid)"), connectsOnAttach(device) {
                connect(to: .usb(udid: device.udid))
            }
        }
        for session in sessions where !session.failed {
            // Refresh the LAN route independently so an AWDL failure can use
            // it immediately, even if the devices changed Wi-Fi networks.
            session.sender.updateLANFallback(wifiService(for: session)?.endpoint)
            if !session.onUSB, !session.onPeerWiFi, !session.wired,
               let id = session.deviceID, let (endpoint, interface) = peerTarget(for: id)?.peerRoute {
                session.sender.preferPeerWiFi(endpoint, interface: interface, installID: id)
            }
        }
        guard wifiAutoConnectArmed else { return }
        for result in discovered {
            let target = ConnectionTarget.wifi(result)
            if shouldDialAutomatically(result, remembered: wifiRemembered.contains(target.sessionID)),
               activeSession(coveringWiFi: result) == nil,
               !cabled(result) {
                connect(to: target)
            }
        }
        for target in peerWiFiTargets {
            guard let result = target.service,
                  shouldDialAutomatically(result, remembered: txtID(of: result).map(rememberedPeerIDs.contains) == true),
                  activeSession(coveringWiFi: result) == nil,
                  !cabled(result) else { continue }
            connect(to: target)
        }
    }

    private func shouldDialAutomatically(_ result: NWBrowser.Result, remembered: Bool) -> Bool {
        let selection = macSelection(of: result)
        guard selection != MacTargetRouting.usbSelection else { return false }
        return MacTargetRouting.permitsAutomaticDial(
            local: LocalMacTarget.id, selected: selection.flatMap(UUID.init(uuidString:)),
            remembered: remembered && (autoReconnectWiFi || Date() < wifiAutoConnectDeadline))
    }

    private func macSelection(of result: NWBrowser.Result) -> String? {
        guard case .bonjour(let txt) = result.metadata else { return nil }
        return txt[MacTargetRouting.selectionKey]
    }

    private func retireUnselectedWirelessSessions(in services: [NWBrowser.Result]) {
        for session in sessions where !session.onUSB {
            guard let result = services.first(where: { matches($0, session: session) }),
                  let selection = macSelection(of: result),
                  selection != LocalMacTarget.id.uuidString else { continue }
            // Keep the remembered device so changing the selection back can
            // reconnect without requiring a click on this Mac.
            end(session)
        }
    }

    private func peerTarget(for installID: String) -> ConnectionTarget? {
        peerWiFiTargets.first { $0.service.flatMap(txtID) == installID }
    }

    private func currentTarget(_ session: DeviceSession) -> ConnectionTarget {
        if session.onUSB { return .usb(udid: session.usbUDID) }
        if session.onPeerWiFi, let id = session.deviceID, let target = peerTarget(for: id) { return target }
        if let result = wifiService(for: session) { return .wifi(result) }
        return session.target
    }

    private func isAvailable(_ target: ConnectionTarget) -> Bool {
        switch target {
        case .usb(let udid): return udid == nil || usbDevices.contains { $0.udid == udid }
        case .wifi: return discovered.contains { ConnectionTarget.wifi($0).sessionID == target.sessionID }
        case .peerWiFi: return peerWiFiTargets.contains { $0.sessionID == target.sessionID }
        }
    }

    /// An attached, auto-connectable USB device is (about to be) dialed over
    /// the cable — its WiFi service must not be grabbed in the launch race.
    private func cabled(_ result: NWBrowser.Result) -> Bool {
        usbDevices.contains {
            sameDevice(result, $0) && !usbDisabled.contains("usb:\($0.udid)") && connectsOnAttach($0)
        }
    }

    /// Dialing an Android device in accessory mode switches its USB mode and
    /// opens the receiver app on it, so plugging in only connects a device
    /// that streamed over the cable before (its install id is known).
    /// Anything else is any Android phone plugged in to charge: the first
    /// connect is a click in the device list.
    private func connectsOnAttach(_ device: UsbmuxDevice) -> Bool {
        guard AOA.serial(fromUDID: device.udid) != nil else { return true }
        return !receiverClosedOnCable.contains(device.udid) && installIDByUDID[device.udid] != nil
    }

    /// A Mac receiver just appeared on the direct cable: connect to it unless
    /// a session already covers it (a live WiFi session moves onto the cable
    /// through the sender's own upgrade probe instead).
    private func connectNewlyCabled() {
        let nowOnCable = Set(discovered.compactMap { result in
            result.interfaces.contains(where: DirectCable.isDirectLink) ? serviceName(of: result) : nil
        })
        let plugged = nowOnCable.subtracting(onDirectCable)
        onDirectCable = nowOnCable
        everOnCable.formUnion(nowOnCable)
        guard autoConnectEnabled, connectionChoice != .sidecar, !plugged.isEmpty else { return }
        for result in discovered {
            guard let name = serviceName(of: result), plugged.contains(name),
                  !cableOptOut.contains(name),
                  activeSession(coveringWiFi: result) == nil,
                  !alreadyServedOnCable(result),
                  // A USB-attached phone belongs to the usbmux path and its
                  // own opt-out, never this one.
                  !usbDevices.contains(where: { sameDevice(result, $0) }) else { continue }
            Log.info("\(name) appeared on the direct cable — connecting")
            connect(to: .wifi(result))
        }
    }

    /// A live session may already talk to this receiver under another
    /// service name (renamed while streaming). Match the install id when the
    /// browse result carries TXT; it often does not, so also treat any live
    /// session already on the cable as covering it: a second cabled Mac
    /// receiver at the same time is rare, and a click still connects it.
    private func alreadyServedOnCable(_ result: NWBrowser.Result) -> Bool {
        let id = txtID(of: result)
        return sessions.contains { s in
            guard !s.failed else { return false }
            if let id, s.deviceID == id { return true }
            return s.wired && s.deviceKind == "Mac"
        }
    }

    private func wiredDevicesChanged() {
        let devices = usbmuxDevices + accessoryDevices
        let detached = Set(usbDevices.map(\.udid)).subtracting(devices.map(\.udid))
        usbDevices = devices
        receiverClosedOnCable.subtract(detached)
        failover(detachedUDIDs: detached)
        autoConnect()
    }

    /// How to dial a cabled device: usbmuxd, or accessory mode for Android.
    private func wiredTransport(udid: String?, port: UInt16) -> SenderTransport {
        if let serial = udid.flatMap(AOA.serial(fromUDID:)) {
            return .accessory(serial: serial)
        }
        return .usb(udid: udid, port: port)
    }

    /// Cable plugged in while the device streams over WiFi: migrate the live
    /// session onto USB. No-op when the session is already cabled.
    private func upgradeToUSB(_ session: DeviceSession, device: UsbmuxDevice) {
        guard !session.onUSB, let portNum = UInt16(port) else { return }
        Log.info("cable attached for \(session.id) — migrating to USB")
        session.onUSB = true
        session.onPeerWiFi = false
        session.usbUDID = device.udid
        // The match may have been by name only — pin the strong identity so
        // future matching (and the next launch) recognizes the pair.
        if let id = session.deviceID { installIDByUDID[device.udid] = id }
        session.sender.switchTransport(to: wiredTransport(udid: device.udid, port: portNum))
    }

    /// Cable unplugged under a live session: fail over to the device's WiFi
    /// service if one is visible. Without one the session keeps its normal
    /// fate — retry over USB through the grace period, then end.
    private func failover(detachedUDIDs: Set<String>) {
        guard autoConnectEnabled, connectionChoice != .sidecar,
              !detachedUDIDs.isEmpty else { return }
        for session in sessions where session.onUSB {
            guard let udid = session.usbUDID, detachedUDIDs.contains(udid) else { continue }
            let lan = wifiService(for: session)
            if let id = installID(of: session), let target = peerTarget(for: id),
               let (endpoint, interface) = target.peerRoute {
                session.onUSB = false
                session.onPeerWiFi = true
                session.wifiServiceName = target.service.flatMap(serviceName)
                session.sender.updateLANFallback(lan?.endpoint)
                session.sender.switchTransport(to: .tcp(endpoint, peerInterface: interface))
                continue
            }
            guard let lan else { continue }
            Log.info("cable detached for \(session.id) — failing over to WiFi")
            session.onUSB = false
            session.wifiServiceName = serviceName(of: lan)
            session.sender.switchTransport(to: .tcp(lan.endpoint))
        }
    }

    /// A quit receiver app loses its Bonjour advertisement within ~1s, far
    /// faster than WiFi dial timeouts can notice (dials to a withdrawn
    /// service stall rather than getting refused). Report the withdrawal to
    /// each live WiFi session's sender; it only acts if its connection is
    /// already down too, which together proves the app is gone. Debounced
    /// 3s: an mDNS record can drop briefly during a WiFi roam — only a
    /// withdrawal that persists counts. One-shot, guarded re-check, so
    /// overlapping browse events at worst repeat an idempotent call.
    private func endSessionsWhoseServiceVanished() {
        for session in sessions where !session.onUSB && !session.onPeerWiFi {
            guard wifiService(for: session) == nil else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
                guard let self, let session,
                      self.sessions.contains(where: { $0 === session }),
                      !session.onUSB, !session.onPeerWiFi,
                      self.wifiService(for: session) == nil else { return }
                session.sender.peerServiceWithdrawn()
            }
        }
    }

    /// The discovered WiFi service belonging to this session's device.
    private func wifiService(for session: DeviceSession) -> NWBrowser.Result? {
        discovered.first { matches($0, session: session) }
    }

    /// Safety net, not a feature: if identity was learned too late (old
    /// receiver, renamed service) and one physical device ended up with two
    /// sessions, preserve the established pipeline and record the service
    /// alias before retiring the twin, so discovery cannot dial it again.
    private func dedupeSessions() {
        var owners: [String: DeviceSession] = [:]
        for session in sessions where !session.failed {
            guard let id = installID(of: session) else { continue }
            guard let owner = owners[id] else {
                owners[id] = session
                continue
            }
            if let name = session.target.service.flatMap(serviceName) {
                owner.wifiServiceName = name
            }
            Log.info("two sessions for one device — keeping \(owner.id), dropping \(session.id)")
            end(session)
        }
    }

    /// Human-readable device name for a target (no transport suffix — the
    /// UI shows transports separately).
    func label(for target: ConnectionTarget) -> String {
        switch target {
        case .usb(let udid):
            if let device = usbDevices.first(where: { $0.udid == udid }), let name = device.name {
                return name
            }
            if udid == nil { return "Manual (\(host):\(port))" }
            return udid.flatMap(AOA.serial(fromUDID:)) == nil ? "iPhone / iPad" : "Android device"
        case .wifi(let result), .peerWiFi(let result, _):
            return serviceName(of: result) ?? "WiFi device"
        }
    }

    func session(for id: String) -> DeviceSession? {
        sessions.first { $0.id == id }
    }

    /// Derive a stable, per-device display serial from the session identity.
    /// FNV-1a over the id string; macOS keys saved display arrangement on
    /// vendor/product/serial, so each device keeps its screen position.
    private static func displaySerial(for id: String) -> UInt32 {
        var hash: UInt32 = 2_166_136_261
        for byte in id.utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        return hash == 0 ? 1 : hash
    }

    // A display identity macOS saved hostile state for (see
    // MacSender.setupExtend) is abandoned permanently: the validated offset
    // from the device's base identity is persisted per session id and every
    // future session starts from it.
    private static func identityOffsetKey(for id: String) -> String { "displaySerialBump.\(id)" }
    private func identityOffset(for id: String) -> UInt32 {
        UInt32(clamping: UserDefaults.standard.integer(forKey: Self.identityOffsetKey(for: id)))
    }

    func connect(to target: ConnectionTarget, userInitiated: Bool = false,
                 awaitingWake: Bool = false) {
        guard connectionChoice != .sidecar else { return }
        if let result = target.service, let selection = macSelection(of: result),
           selection != LocalMacTarget.id.uuidString { return }
        let id = target.sessionID
        if let existing = session(for: id) {
            // A failed session holds no pipeline — replace the corpse
            // instead of letting it swallow the fresh attempt.
            guard existing.failed else { return }
            end(existing)
        }

        // Never create a second session for the same physical device — the
        // receiver holds one connection, so a twin would steal it. But an
        // explicit user click overrides: e.g. right after unplugging the
        // cable, the dying USB session sits in its 10s reconnect grace and
        // would otherwise swallow the tap on the WiFi row.
        let covering: DeviceSession?
        switch target {
        case .usb(let udid?):
            covering = usbDevices.first(where: { $0.udid == udid })
                .flatMap { activeSession(coveringUSB: $0) }
        case .wifi(let result), .peerWiFi(let result, _):
            covering = activeSession(coveringWiFi: result)
        default:
            covering = nil
        }
        if let covering {
            guard userInitiated else { return }
            if autoConnectEnabled {
                autoConnect()
                return
            }
            Log.info("user chose \(id) — taking over from \(covering.id)")
            end(covering)
        }

        // Connecting a device clears its "don't auto-connect" state.
        switch target {
        case .usb(let udid):
            usbDisabled.remove(id)
            if userInitiated, let udid { receiverClosedOnCable.remove(udid) }
        case .wifi(let result):
            wifiRemembered.insert(id)
            if userInitiated, let name = serviceName(of: result) { cableOptOut.remove(name) }
        case .peerWiFi(let result, _):
            // Allow LAN recovery for a device first connected over AWDL.
            wifiRemembered.insert(ConnectionTarget.wifi(result).sessionID)
        }

        let transport: SenderTransport
        switch target {
        case .usb(let udid):
            guard let portNum = UInt16(port) else { return }
            if UserDefaults.standard.object(forKey: "host") != nil, udid == nil {
                // Manual override: dial a plain TCP endpoint instead of usbmuxd.
                transport = .tcp(.hostPort(host: NWEndpoint.Host(host),
                                           port: NWEndpoint.Port(rawValue: portNum)!))
            } else {
                transport = wiredTransport(udid: udid, port: portNum)
            }
        case .wifi(let result):
            transport = .tcp(result.endpoint)
        case .peerWiFi:
            guard let (endpoint, interface) = target.peerRoute else { return }
            transport = .tcp(endpoint, peerInterface: interface)
        }

        let name = label(for: target)
        let lanFallback = target.service.flatMap { result in
            discovered.first { sameReceiver(result, $0) }?.endpoint
        }
        let sender = MacSender(transport: transport, name: name, mode: mode,
                               quality: quality, adaptiveBitrateEnabled: adaptiveBitrateEnabled,
                               capsLockSwitchesInputSource: capsLockSwitchesInputSource,
                               lanFallback: lanFallback,
                               displaySerial: Self.displaySerial(for: id),
                               identityOffset: identityOffset(for: id),
                               awaitingWake: awaitingWake)
        let session = DeviceSession(id: id, target: target, name: name, sender: sender)
        if let result = target.service {
            session.wifiServiceName = serviceName(of: result)
        }
        sender.onStatus = { [weak session] text in
            // Retry loops re-announce the same status every second (e.g. the
            // asleep wait) — only a change is worth the UI churn and the log line.
            guard let session, session.status != text else { return }
            session.status = text
            Log.info("status[\(id)]: \(text)")
        }
        sender.onHello = { [weak self, weak session] info in
            guard let self, let session, self.session(for: id) === session else { return }
            if let id = info.id { session.deviceID = id }
            session.deviceKind = info.device
            if let installID = info.id,
               info.device == "iPad" || info.device == "iPhone",
               !self.rememberedPeerIDs.contains(installID) {
                self.rememberedPeerIDs.insert(installID)
            }
            session.helloArrived(info)
            let power = (info.power ?? []).compactMap(PowerAction.init(rawValue:))
            if power != session.powerActions {
                Log.info("session \(session.id) power actions: "
                    + (power.isEmpty ? "none" : power.map(\.rawValue).joined(separator: ",")))
                session.powerActions = power
            }
            if session.onUSB, let udid = session.usbUDID, let installID = info.id {
                self.installIDByUDID[udid] = installID
            }
            // The learned identity may reveal that this WiFi session's device
            // is cabled — take the upgrade opportunity right away.
            self.autoConnect()
        }
        sender.onStats = { [weak session] frames, _ in
            session?.framesSent = frames
        }
        sender.onDisconnected = { [weak self, weak session] in
            // Device unplugged / left the network and stayed gone: end this
            // session fully (virtual display + capture + indicator). No
            // transport fallback — reconnecting is the user's call.
            guard let self, let session else { return }
            Log.info("device disconnected — session \(session.id) stopped")
            self.end(session)
        }
        sender.onPeerSleeping = { [weak self, weak session] in
            // The device locked. Unlike a plain disconnect this is a
            // known-temporary state announced by the receiver, so ending
            // the session (which frees the cursor from the now-invisible
            // display) is paired with a replacement session that dials
            // patiently until the device wakes and accepts again.
            guard let self, let session, self.session(for: id) === session else { return }
            let target = self.currentTarget(session)
            Log.info("session \(session.id) asleep — display down, waiting for wake")
            self.end(session)
            self.connect(to: target, awaitingWake: true)
        }
        sender.onCaptureStoppedByUser = { [weak self, weak session] in
            // The user stopped the capture in the system UI — same intent as
            // the in-app Disconnect, so it also opts the device out of
            // auto-connect (or the next browse event would resurrect it).
            guard let self, let session, self.session(for: id) === session else { return }
            Log.info("session \(session.id) capture stopped via the system UI — honoring as disconnect")
            self.disconnect(session)
        }
        sender.onDisplayIdentityBumped = { [weak session] totalOffset in
            // The sender reports the validated absolute offset — store it
            // as-is. Adding would double-count when a rotation rebuild
            // re-discovers the same poisoned identity within one session.
            guard let session else { return }
            UserDefaults.standard.set(Int(totalOffset), forKey: Self.identityOffsetKey(for: session.id))
            Log.info("display identity for \(session.id) moved to offset \(totalOffset) — "
                + "macOS saved hostile state for the old one")
        }
        sender.onTransportPath = { [weak session] wired, peerWiFi in
            session?.wired = wired
            session?.onPeerWiFi = peerWiFi
        }
        sender.onPeerClosed = { [weak self, weak session] in
            // The receiver app quit — a deliberate goodbye, so no reconnect
            // waits around. Reopening the app is a fresh start handled by
            // the normal discovery/auto-connect paths.
            guard let self, let session, self.session(for: id) === session else { return }
            Log.info("session \(session.id) closed by the receiver — ending")
            if session.onUSB, let udid = session.usbUDID, AOA.serial(fromUDID: udid) != nil {
                self.receiverClosedOnCable.insert(udid)
            }
            self.end(session)
        }
        sessions.append(session)
        Task {
            do {
                try await sender.start()
            } catch is CancellationError {
                // stopped by the user while waiting — nothing to report
            } catch {
                Log.info("sender failed to start: \(error)")
                session.status = "Failed: \(error.localizedDescription)"
                // Free the half-built pipeline: a leaked virtual display
                // would keep holding this device's serial, and a parked
                // live-looking session would swallow every future connect.
                session.failed = true
                sender.stop()
            }
        }
    }

    /// User-initiated disconnect: also opt the device out of auto-connect.
    func disconnect(_ session: DeviceSession) {
        switch session.target {
        case .usb: usbDisabled.insert(session.id)
        case .wifi:
            wifiRemembered.remove(session.id)
            if let name = session.wifiServiceName, everOnCable.contains(name) {
                cableOptOut.insert(name)
            }
        case .peerWiFi: break
        }
        // A migrated session is also reachable the other way — opt that side
        // out too, or auto-connect resurrects the device moments later.
        if let udid = session.usbUDID { usbDisabled.insert("usb:\(udid)") }
        if let name = session.wifiServiceName { wifiRemembered.remove("wifi:\(name)") }
        if let id = session.deviceID ?? session.target.service.flatMap(txtID) {
            rememberedPeerIDs.remove(id)
            for result in discovered where txtID(of: result) == id {
                wifiRemembered.remove(ConnectionTarget.wifi(result).sessionID)
            }
        }
        end(session)
    }

    func disconnectAll() {
        if sidecarDevice != nil {
            Task { await selectConnection(.automatic) }
            return
        }
        sessions.forEach { disconnect($0) }
    }

    /// Restart a session that failed to start (its pipeline is already
    /// freed): tear the corpse out and dial the same target fresh. The
    /// socket-only Reconnect can't help there — nothing was ever built.
    func retry(_ session: DeviceSession) {
        let target = currentTarget(session)
        end(session)
        connect(to: target, userInitiated: true)
    }

    private func end(_ session: DeviceSession) {
        session.sender.stop()
        sessions.removeAll { $0 === session }
    }

    /// Mode/quality apply per-pipeline at construction — rebuild every session.
    func restartAll() {
        guard !sessions.isEmpty else { return }
        let targets = sessions.map(currentTarget)
        sessions.forEach { $0.sender.stop() }
        sessions.removeAll()
        targets.forEach { connect(to: $0) }
        autoConnect()   // a rebuilt WiFi session may deserve its cable back
    }

    // MARK: - Device list (one row per physical device)

    struct DeviceEntry: Identifiable {
        let id: String
        let name: String
        let usbTarget: ConnectionTarget?
        let wifiTarget: ConnectionTarget?

        var transportLabel: String {
            let wireless = wifiTarget?.peerRoute == nil ? "Wi-Fi" : "Wi-Fi 直连"
            if usbTarget != nil { return wifiTarget == nil ? "USB" : "USB · \(wireless)" }
            return wifiTarget == nil ? "" : wireless
        }
        /// Lowest latency first.
        var preferredTarget: ConnectionTarget? { usbTarget ?? wifiTarget }
    }

    var deviceEntries: [DeviceEntry] {
        // AWDL and LAN can advertise the same app. Keep one row with AWDL as
        // its preferred wireless target and LAN available for fallback.
        var wirelessTargets: [ConnectionTarget] = []
        for target in peerWiFiTargets + discovered.map(ConnectionTarget.wifi) {
            guard let result = target.service, !wirelessTargets.contains(where: { existing in
                existing.service.map { sameReceiver($0, result) } ?? false
            }) else { continue }
            wirelessTargets.append(target)
        }
        var entries: [DeviceEntry] = []
        var mergedWireless = Set<ConnectionTarget>()
        var coveredSessionIDs = Set<String>()

        for device in usbDevices {
            let twin = wirelessTargets.first { target in
                target.service.map { sameDevice($0, device) } ?? false
            }
            let usbTarget = ConnectionTarget.usb(udid: device.udid)
            coveredSessionIDs.insert(usbTarget.sessionID)
            if let twin {
                mergedWireless.insert(twin)
                coveredSessionIDs.insert(twin.sessionID)
            }
            // A WiFi-identity session migrated onto this cable serves the
            // device even when its service is no longer advertised.
            if let covering = activeSession(coveringUSB: device) {
                coveredSessionIDs.insert(covering.id)
            }
            entries.append(DeviceEntry(
                id: "device:\(device.udid)",
                name: device.name
                    ?? twin?.service.flatMap(serviceName)
                    ?? session(for: usbTarget.sessionID)?.deviceKind
                    ?? label(for: usbTarget),
                usbTarget: usbTarget,
                wifiTarget: twin))
        }
        if UserDefaults.standard.object(forKey: "host") != nil {
            let target = ConnectionTarget.usb(udid: nil)
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: target.sessionID, name: label(for: target),
                                       usbTarget: target, wifiTarget: nil))
        }
        for target in wirelessTargets where !mergedWireless.contains(target) {
            guard let result = target.service, let name = serviceName(of: result) else { continue }
            // A USB-identity session that failed over to WiFi serves this
            // service — claim it, or it would dangle as a second row and
            // this one would offer a Connect that steals the receiver.
            if let covering = activeSession(coveringWiFi: result) {
                guard coveredSessionIDs.insert(covering.id).inserted else {
                    coveredSessionIDs.insert(target.sessionID)
                    continue
                }
            }
            coveredSessionIDs.insert(target.sessionID)
            entries.append(DeviceEntry(id: "service:\(txtID(of: result) ?? name)", name: name,
                                       usbTarget: nil, wifiTarget: target))
        }
        // Sessions whose device vanished from discovery (e.g. Bonjour record
        // gone while the stream is still alive) keep a row to disconnect.
        for session in sessions where !coveredSessionIDs.contains(session.id) {
            entries.append(DeviceEntry(id: session.id, name: session.name,
                                       usbTarget: nil, wifiTarget: nil))
        }
        return entries
    }

    var visibleDeviceEntries: [DeviceEntry] {
        let entries = deviceEntries
        guard connectionChoice == .wifi else { return entries }
        return entries.filter { $0.wifiTarget != nil || session(for: $0)?.onUSB == false }
    }

    func session(for entry: DeviceEntry) -> DeviceSession? {
        if let target = entry.usbTarget {
            if let s = session(for: target.sessionID) { return s }
            if case .usb(let udid?) = target,
               let device = usbDevices.first(where: { $0.udid == udid }),
               let s = activeSession(coveringUSB: device) { return s }
        }
        if let target = entry.wifiTarget {
            if let s = session(for: target.sessionID) { return s }
            // Transport-migrated sessions keep their original identity — a
            // USB-identity session failed over to WiFi still owns this row.
            if let result = target.service,
               let s = activeSession(coveringWiFi: result) { return s }
        }
        return session(for: entry.id)   // dangling-session rows
    }
}

/// Polls the permission states the app depends on so the UI can surface
/// exactly what's missing instead of failing silently.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published var screenRecording = false
    @Published var accessibility = false
    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
    }

    /// Fire the system permission dialog on demand. macOS only shows each
    /// dialog once per reset — after that the call just (re)registers the
    /// app in System Settings, so the row exists to toggle manually.
    func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refresh()
    }

    func requestAccessibility() {
        _ = InputInjector.ensureAccessibilityPermission()
        refresh()
    }

    static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct ContentView: View {
    @ObservedObject var controller: SenderController
    @StateObject private var permissions = PermissionMonitor()
    // Optional so the view still compiles/previews without an updater (e.g.
    // if Sparkle ever fails to start); the button just disables itself then.
    let updater: SPUStandardUpdaterController?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenDisplay")
                        .font(.title3.bold())
                    Text("Your iPads, iPhones and Macs as extra displays")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if controller.running {
                    Button(controller.sidecarDevice == nil ? "Disconnect All" : "Disconnect Sidecar") {
                        controller.disconnectAll()
                    }
                        .controlSize(.large)
                    .disabled(controller.switchingConnection)
                }
            }
            .padding(16)

            Divider()

            // Settings
            Form {
                Picker("Connection", selection: Binding(
                    get: { controller.connectionChoice },
                    set: { choice in Task { await controller.selectConnection(choice) } }
                )) {
                    ForEach(ConnectionChoice.allCases, id: \.self) { choice in
                        Text(choice.rawValue).tag(choice)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("connectionChoice")
                .disabled(controller.switchingConnection)

                if controller.connectionChoice != .sidecar {
                    Text("Auto：USB → Wi-Fi 直连 → Wi-Fi")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if controller.connectionChoice != .sidecar, !controller.sidecarStatus.isEmpty {
                    Text(controller.sidecarStatus).font(.caption).foregroundStyle(.secondary)
                }

                if controller.connectionChoice == .sidecar {
                    Section("随航 · Apple Sidecar") {
                        if let device = controller.sidecarDevice {
                            Label(device.name, systemImage: "ipad.landscape")
                        } else {
                            if let transport = controller.currentOpenDisplayConnectionLabel {
                                Text("Current OpenDisplay connection: \(transport)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(controller.sidecarDevices) { device in
                                HStack {
                                    Label(device.name, systemImage: "ipad.landscape")
                                    Spacer()
                                    Button("Connect") { Task { await controller.connectSidecar(device) } }
                                        .controlSize(.small)
                                }
                            }
                            Button("Refresh iPads") { controller.refreshSidecarDevices() }
                                .controlSize(.small)
                            Text("For wireless Sidecar, unplug USB first. If the Mac locks, unlock via Mac 登录 → 局域网.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !controller.sidecarStatus.isEmpty {
                            Text(controller.sidecarStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(controller.switchingConnection)
                } else {
                    Section(controller.connectionChoice == .wifi ? "Wi-Fi 设备" : "Devices") {
                        let entries = controller.visibleDeviceEntries
                        if entries.isEmpty {
                            if controller.connectionChoice == .wifi {
                                Text(controller.peerWiFiStatus.isEmpty
                                     ? "请在 iPad 上打开 OpenDisplay。可使用同一局域网，或在 Settings & Help 中开启 Wi-Fi 直连。"
                                     : controller.peerWiFiStatus)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("重新搜索") { controller.refreshPeerWiFi() }
                                    .controlSize(.small)
                            } else {
                                Text("No devices found — plug one in via USB, or open the OpenDisplay app on a device on this WiFi network.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(entries) { entry in
                            if let session = controller.session(for: entry) {
                                // Title from the entry, not the session: the
                                // session name was snapshotted at connect time,
                                // often before lockdown resolved the real name.
                                SessionRow(title: entry.name, session: session,
                                           controller: controller)
                            } else {
                                HStack(alignment: .firstTextBaseline) {
                                    Circle()
                                        .fill(.secondary.opacity(0.5))
                                        .frame(width: 9, height: 9)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.name)
                                        Text(entry.transportLabel)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let target = controller.connectionTarget(for: entry) {
                                        Button("Connect") {
                                            controller.connect(to: target, userInitiated: true)
                                        }
                                        .controlSize(.small)
                                    }
                                }
                            }
                        }
                    }

                    Picker("Mode", selection: $controller.mode) {
                        Text("Extend").tag(CaptureMode.extend)
                        Text("Mirror").tag(CaptureMode.mirror)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: controller.mode) { controller.restartAll() }

                    VStack(alignment: .leading, spacing: 4) {
                        Picker("Quality", selection: $controller.quality) {
                            ForEach(StreamQuality.allCases, id: \.self) { q in
                                Text(q.label).tag(q)
                            }
                        }
                        .onChange(of: controller.quality) { controller.restartAll() }
                        Text(controller.quality.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Adaptive bitrate (Wi-Fi)", isOn: $controller.adaptiveBitrateEnabled)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("adaptiveBitrateToggle")
                        Text("Automatically adjusts video quality on Wi-Fi. USB always uses a fixed bitrate.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Caps Lock switches input source", isOn: $controller.capsLockSwitchesInputSource)
                            .toggleStyle(.switch)
                            .accessibilityIdentifier("capsLockInputSourceToggle")
                        Text("Off: Caps Lock controls letter case. On: switch between input sources.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Picker("Show app in", selection: $controller.presentation) {
                        ForEach(AppPresentation.allCases, id: \.self) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    if controller.presentation == .background {
                        Text("No menu bar or Dock icon — streaming keeps running. Open the OpenDisplay app again (Spotlight/Finder) to show this window.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Display layout") {
                    Button("Arrange Displays…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                }
                .help("Opens System Settings → Displays, where you can position the extended displays relative to your Mac screen (Arrange…). Each device shows up as its own display, named after the device.")

                Section("Permissions") {
                    permissionRow(
                        "Screen Recording",
                        granted: permissions.screenRecording,
                        help: "Required to capture the display.",
                        anchor: "Privacy_ScreenCapture",
                        request: { permissions.requestScreenRecording() }
                    )
                    permissionRow(
                        "Accessibility",
                        granted: permissions.accessibility,
                        help: "Required for touch input from the device.",
                        anchor: "Privacy_Accessibility",
                        request: { permissions.requestAccessibility() }
                    )
                    // macOS offers no API to query Local Network access, so
                    // infer from discovery results and let the user check.
                    permissionRow(
                        "Local Network",
                        granted: !controller.discovered.isEmpty,
                        uncertain: controller.discovered.isEmpty,
                        help: "Required for WiFi mode. If no device appears in the Devices list, allow OpenDisplay under Privacy & Security → Local Network on this Mac AND on the device — and keep the OpenDisplay app open there.",
                        anchor: "Privacy_LocalNetwork"
                    )
                }
            }
            .formStyle(.grouped)
            // Scrollable + fixed panel height: MenuBarExtra windows mis-measure
            // grouped Forms (clipping on small displays), so size explicitly
            // and let the form scroll when it doesn't fit.

            Divider()

            // Status bar
            HStack(spacing: 8) {
                Circle()
                    .fill(controller.running ? .green : .secondary.opacity(0.5))
                    .frame(width: 9, height: 9)
                Text(controller.sidecarDevice != nil ? "Sidecar connected" : controller.running
                     ? "\(controller.sessions.count) device\(controller.sessions.count == 1 ? "" : "s") connected"
                     : "Idle")
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                // Support affordance: bug reports are much easier to act on
                // with the log attached, and users shouldn't have to be told a
                // filesystem path to find it.
                Button("Logs") { Log.revealInFinder() }
                    .controlSize(.small)
                    .help("Reveal the OpenDisplay log files in Finder")
                if let updater {
                    CheckForUpdatesView(updater: updater)
                }
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(width: 440, height: 540)
    }

    @ViewBuilder
    private func permissionRow(_ title: String, granted: Bool, uncertain: Bool = false,
                               help: String, anchor: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: uncertain ? "questionmark.circle.fill"
                            : granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(uncertain ? .orange : granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if uncertain || !granted {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if uncertain || !granted {
                if let request {
                    Button("Grant…") { request() }
                        .controlSize(.small)
                        .help("Ask macOS for this permission. If the system dialog was already dismissed once, this registers the app under \(title) in System Settings — flip the toggle there.")
                }
                Button("Open Settings") {
                    PermissionMonitor.openPrivacyPane(anchor)
                }
                .controlSize(.small)
            }
        }
    }
}

/// One connected device: live status, throughput, reconnect + disconnect.
@MainActor
struct SessionRow: View {
    let title: String
    @ObservedObject var session: DeviceSession
    let controller: SenderController
    @State private var confirmingShutdown = false
    @State private var choosingDisplaySize = false

    private var statusColor: Color {
        if session.status.hasPrefix("Extending") || session.status.hasPrefix("Mirroring")
            || session.status.hasPrefix("Connected") {
            return .green
        }
        if session.status.hasPrefix("Failed") || session.status.contains("stopped") {
            return .red
        }
        return .orange
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text("\(session.transportLabel) · \(session.status)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            // A live session recovers on its own (liveness watchdog, redial,
            // transport failover), so only a failed start gets a button.
            if session.failed {
                Button("Retry") { controller.retry(session) }
                    .controlSize(.small)
                    .help("Start this connection over")
            }
            if session.powerActions.contains(.shutdown) {
                Button {
                    confirmingShutdown = true
                } label: {
                    Image(systemName: "power")
                }
                .controlSize(.small)
                .help("Shut down \(title)")
                .confirmationDialog("Shut down \(title) now?", isPresented: $confirmingShutdown) {
                    Button("Shut Down", role: .destructive) { session.sender.requestPower(.shutdown) }
                } message: {
                    Text("Apps on it with unsaved changes can still stop the shutdown.")
                }
            }
            if !session.displaySizeOutcomes.isEmpty {
                Button {
                    choosingDisplaySize = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .controlSize(.small)
                .help("Display size of \(title)")
                .popover(isPresented: $choosingDisplaySize, arrowEdge: .bottom) {
                    DisplaySizePicker(session: session)
                }
            }
            Button("Disconnect") { controller.disconnect(session) }
                .controlSize(.small)
        }
    }
}

/// The per-device desktop size, macOS Displays style: each choice with the
/// exact desktop it gives underneath, and the stream when it is not 1:1.
@MainActor
struct DisplaySizePicker: View {
    @ObservedObject var session: DeviceSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Display size").font(.headline)
            Picker("Display size", selection: Binding(
                get: { session.displaySize },
                set: { session.setDisplaySize($0) })) {
                ForEach(session.displaySizeOutcomes, id: \.choice) { outcome in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(outcome.choice.title)
                        Text(caption(for: outcome))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(outcome.choice)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        .padding(14)
        .fixedSize()
        .onAppear { session.refreshDisplaySize() }
    }

    private func caption(for outcome: DisplaySizeOutcome) -> String {
        let sameAsDefault = outcome.choice != .default
            && outcome.desktop == session.displaySizeOutcomes.first(where: { $0.choice == .default })?.desktop
        return outcome.caption + (sameAsDefault ? " (same as Default)" : "")
    }
}

