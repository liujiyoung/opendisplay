import UIKit
import SwiftUI
import Combine
import GameController

/// Own raw input only while the full-screen scene actually holds pointer lock.
/// UIKit remains available for the toolbar, sheets and older Mac senders.
@MainActor
final class RelativePointerCapture: ObservableObject {
    weak var receiver: StreamReceiver?
    @Published private(set) var hasMouse = false
    @Published private(set) var locked = false
    @Published var enabled = false {
        didSet { if oldValue && !enabled { releaseInput() } }
    }
    var wantsLock: Bool { enabled && hasMouse }
    var isCapturing: Bool { wantsLock && locked }

    private var mice: [ObjectIdentifier: GCMouse] = [:]
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private weak var observedScene: UIWindowScene?
    private var clicks = RemoteClickTracker()
    private var travel = CGPoint.zero
    private var loggedMotion = false

    init() {
        for name in [Notification.Name.GCMouseDidConnect, .GCMouseDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                DispatchQueue.main.async { self?.refreshMice() }
            })
        }
        refreshMice()
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    func observeLock(in scene: UIWindowScene?) {
        guard observedScene !== scene else { return }
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
        observedScene = scene
        guard let state = scene?.pointerLockState else { setLocked(false); return }
        setLocked(state.isLocked)
        lockObserver = NotificationCenter.default.addObserver(
            forName: UIPointerLockState.didChangeNotification, object: state, queue: .main
        ) { [weak self] note in
            guard let state = note.object as? UIPointerLockState else { return }
            let locked = state.isLocked
            DispatchQueue.main.async { self?.setLocked(locked) }
        }
    }

    private func setLocked(_ value: Bool) {
        guard locked != value else { return }
        locked = value
        Log.info("pointer lock: \(value ? "locked" : "released")")
        if !value { releaseInput() }
    }

    private func releaseInput() {
        receiver?.resetRemoteInput()
        clicks = RemoteClickTracker()
        loggedMotion = false
    }

    private func refreshMice() {
        let current = GCMouse.mice()
        let ids = Set(current.map(ObjectIdentifier.init))
        for id in Array(mice.keys) where !ids.contains(id) {
            if let input = mice.removeValue(forKey: id)?.mouseInput {
                input.mouseMovedHandler = nil
                input.leftButton.pressedChangedHandler = nil
                input.rightButton?.pressedChangedHandler = nil
                input.middleButton?.pressedChangedHandler = nil
            }
            releaseInput()
        }
        for mouse in current where mice[ObjectIdentifier(mouse)] == nil {
            guard let input = mouse.mouseInput else { continue }
            mice[ObjectIdentifier(mouse)] = mouse
            mouse.handlerQueue = .main
            input.mouseMovedHandler = { [weak self] _, dx, dy in
                DispatchQueue.main.async { self?.move(dx: Double(dx), dy: -Double(dy)) }
            }
            input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
                DispatchQueue.main.async { self?.button(0, down: pressed) }
            }
            input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                DispatchQueue.main.async { self?.button(1, down: pressed) }
            }
            input.middleButton?.pressedChangedHandler = { [weak self] _, _, pressed in
                DispatchQueue.main.async { self?.button(2, down: pressed) }
            }
        }
        hasMouse = !mice.isEmpty
        Log.info("raw pointing devices: \(mice.count)")
    }

    private func move(dx: Double, dy: Double) {
        guard isCapturing, dx.isFinite, dy.isFinite else { return }
        if !loggedMotion { Log.info("relative pointer input active"); loggedMotion = true }
        travel.x += dx
        travel.y += dy
        receiver?.sendRelativePointer(phase: "move", dx: dx, dy: dy)
    }

    private func button(_ button: Int, down: Bool) {
        guard isCapturing else { return }
        let time = ProcessInfo.processInfo.systemUptime
        let count = down ? clicks.down(button: button, time: time, point: travel)
            : clicks.up(button: button, time: time, point: travel)
        receiver?.sendRelativePointer(phase: down ? "down" : "up", button: button, clicks: count)
    }
}

/// Pointer lock is a top-level view-controller preference. Host SwiftUI here
/// instead of changing the controller hierarchy after streaming has started.
@MainActor
final class ReceiverHostingController: UIHostingController<ReceiverScreen> {
    private let pointerCapture: RelativePointerCapture
    private var subscription: AnyCancellable?

    init() {
        let capture = RelativePointerCapture()
        pointerCapture = capture
        super.init(rootView: ReceiverScreen(pointerCapture: capture))
        subscription = capture.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.setNeedsUpdateOfPrefersPointerLocked() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersPointerLocked: Bool { pointerCapture.wantsLock }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pointerCapture.observeLock(in: view.window?.windowScene)
        setNeedsUpdateOfPrefersPointerLocked()
    }
}

final class ReceiverSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        Log.info("receiver window scene connected")
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = ReceiverHostingController()
        self.window = window
        window.makeKeyAndVisible()
    }
}
