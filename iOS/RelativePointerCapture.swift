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
        didSet {
            guard oldValue != enabled else { return }
            if enabled {
                // A keyboard case can retain its GCMouse identity while its
                // input profile is replaced across app suspension/resumption.
                refreshMice()
                synchronizeLock()
            } else { releaseInput() }
        }
    }
    var wantsLock: Bool { enabled && hasMouse }
    var isCapturing: Bool { wantsLock && locked }

    private var mice: [ObjectIdentifier: GCMouse] = [:]
    private var mouseInputs: [ObjectIdentifier: GCMouseInput] = [:]
    private var observers: [NSObjectProtocol] = []
    private var lockObserver: NSObjectProtocol?
    private weak var observedScene: UIWindowScene?
    private var clicks = RemoteClickTracker()
    private var travel = CGPoint.zero
    private var loggedMotion = false
    private var stateMonitor: Timer?
    private var rawMotionCount = 0
    private var forwardedMotionCount = 0
    private var lastReport = ProcessInfo.processInfo.systemUptime
    private var reportIdleWindow = false
    var requestLockUpdate: (() -> Void)?

    init() {
        for name in [Notification.Name.GCMouseDidConnect, .GCMouseDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                DispatchQueue.main.async { self?.refreshMice() }
            })
        }
        refreshMice()
        stateMonitor = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.reconcileCapture() }
        }
    }

    deinit {
        stateMonitor?.invalidate()
        for token in observers { NotificationCenter.default.removeObserver(token) }
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
    }

    func observeLock(in scene: UIWindowScene?) {
        guard observedScene !== scene else { return }
        if let lockObserver { NotificationCenter.default.removeObserver(lockObserver) }
        observedScene = scene
        synchronizeLock()
        guard scene != nil else { return }
        lockObserver = NotificationCenter.default.addObserver(
            forName: UIPointerLockState.didChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            // UIKit documents the scene in userInfo. Read the current state
            // when handling the notification instead of applying a queued,
            // potentially obsolete lock value after a foreground transition.
            let changedScene = note.userInfo?[UIPointerLockState.sceneUserInfoKey] as? UIScene
            DispatchQueue.main.async {
                guard let self,
                      changedScene == nil || changedScene === self.observedScene else { return }
                self.synchronizeLock()
            }
        }
    }

    private func synchronizeLock() {
        setLocked(observedScene?.pointerLockState?.isLocked ?? false)
    }

    private func reconcileCapture() {
        let active = UIApplication.shared.applicationState == .active
        if enabled && active {
            let current = GCMouse.mice()
            let ids = Set(current.map(ObjectIdentifier.init))
            if ids != Set(mice.keys) || current.contains(where: {
                $0.mouseInput !== mouseInputs[ObjectIdentifier($0)]
            }) {
                refreshMice()
            }
            synchronizeLock()
            // A transient system UI can release the lock without changing
            // our preference. Ask UIKit to reconsider once it is gone.
            if wantsLock && !locked { requestLockUpdate?() }
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReport >= 5 else { return }
        if rawMotionCount > 0 || reportIdleWindow {
            Log.info("pointer input: raw=\(rawMotionCount) forwarded=\(forwardedMotionCount)"
                     + " enabled=\(enabled) locked=\(locked) active=\(active) mice=\(mice.count)")
        }
        reportIdleWindow = rawMotionCount > 0
        rawMotionCount = 0
        forwardedMotionCount = 0
        lastReport = now
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
            mice.removeValue(forKey: id)
            if let input = mouseInputs.removeValue(forKey: id) {
                input.mouseMovedHandler = nil
                input.leftButton.pressedChangedHandler = nil
                input.rightButton?.pressedChangedHandler = nil
                input.middleButton?.pressedChangedHandler = nil
            }
            releaseInput()
        }
        for mouse in current {
            guard let input = mouse.mouseInput else { continue }
            let id = ObjectIdentifier(mouse)
            if let old = mouseInputs[id], old !== input {
                old.mouseMovedHandler = nil
                old.leftButton.pressedChangedHandler = nil
                old.rightButton?.pressedChangedHandler = nil
                old.middleButton?.pressedChangedHandler = nil
                releaseInput()
            }
            mice[id] = mouse
            mouseInputs[id] = input
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
        if hasMouse != !mice.isEmpty { hasMouse = !mice.isEmpty }
        Log.info("raw pointing devices: \(mice.count)")
    }

    private func move(dx: Double, dy: Double) {
        rawMotionCount += 1
        guard isCapturing, dx.isFinite, dy.isFinite else { return }
        forwardedMotionCount += 1
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
        capture.requestLockUpdate = { [weak self] in self?.setNeedsUpdateOfPrefersPointerLocked() }
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
