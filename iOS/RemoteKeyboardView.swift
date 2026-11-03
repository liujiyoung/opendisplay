import UIKit
import GameController

/// Physical keys go to the Mac's input source without starting an iPad IME.
/// Only the explicit keyboard button focuses the native text input below.
final class RemoteKeyboardView: UIView, UITextViewDelegate {
    weak var receiver: StreamReceiver?
    private var softwareKeyboard = false
    private var forwardingEnabled = true
    private var forwardedKeys = Set<Int>()
    private let textInput = RemoteTextView()
    private var inputSourceSwitchKey = InputSourceSwitchKey()
    private var rawCapsLock: GCControllerButtonInput?
    private var keyboardObservers: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        accessibilityElementsHidden = true
        textInput.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        textInput.delegate = self
        textInput.backgroundColor = .clear
        textInput.textColor = .clear
        textInput.tintColor = .clear
        textInput.autocorrectionType = .no
        textInput.autocapitalizationType = .none
        textInput.spellCheckingType = .no
        textInput.smartQuotesType = .no
        textInput.smartDashesType = .no
        textInput.smartInsertDeleteType = .no
        textInput.isScrollEnabled = false
        textInput.onEmptyDelete = { [weak self] in self?.tapKey(42) }
        addSubview(textInput)
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
            keyboardObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async { self?.releaseKeys(); self?.observeCapsLock() }
            })
        }
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.didBecomeActiveNotification, UIScene.willDeactivateNotification,
                     UIScene.didActivateNotification] {
            keyboardObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] note in
                guard let self else { return }
                if let scene = note.object as? UIScene, scene !== self.window?.windowScene { return }
                self.releaseKeys()
                if name == UIApplication.didBecomeActiveNotification || name == UIScene.didActivateNotification {
                    if self.inputSceneIsActive { self.focus() }
                }
            })
        }
    }

    deinit {
        for token in keyboardObservers { NotificationCenter.default.removeObserver(token) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var canBecomeFirstResponder: Bool { forwardingEnabled }
    override var keyCommands: [UIKeyCommand]? { [] }

    private var inputSceneIsActive: Bool {
        UIApplication.shared.applicationState == .active
            && window?.windowScene?.activationState == .foregroundActive
    }

    static func pointerModifiers(fallback: UInt64) -> UInt64 {
        guard let keyboard = GCKeyboard.coalesced?.keyboardInput else {
            return RemoteInput.iPadModifiers(fallback)
        }
        let keys: [(GCKeyCode, Int)] = [
            (.leftControl, 224), (.leftShift, 225), (.leftAlt, 226), (.leftGUI, 227),
            (.rightControl, 228), (.rightShift, 229), (.rightAlt, 230), (.rightGUI, 231),
        ]
        var observed = Set<Int>(), pressed = Set<Int>()
        for (key, hid) in keys {
            guard let button = keyboard.button(forKeyCode: key) else { continue }
            observed.insert(hid)
            if button.isPressed { pressed.insert(hid) }
        }
        return RemoteInput.pointerModifiers(fallback: fallback, observedHIDs: observed, pressedHIDs: pressed)
    }

    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused { observeCapsLock() }
        return focused
    }

    func focus() {
        guard forwardingEnabled else { return }
        if softwareKeyboard { textInput.becomeFirstResponder() }
        else { becomeFirstResponder() }
    }

    func setForwardingEnabled(_ enabled: Bool) {
        guard forwardingEnabled != enabled else { return }
        forwardingEnabled = enabled
        if enabled { focus() }
        else {
            textInput.resignFirstResponder()
            resignFirstResponder()
            releaseKeys()
        }
    }

    func setSoftwareKeyboard(_ enabled: Bool) {
        guard softwareKeyboard != enabled else { return }
        releaseKeys()
        softwareKeyboard = enabled
        if !enabled { textInput.resignFirstResponder() }
        focus()
    }

    func releaseKeys() {
        receiver?.resetRemoteInput()
        forwardedKeys.removeAll()
        inputSourceSwitchKey.reset()
    }

    override func resignFirstResponder() -> Bool {
        releaseKeys()
        let resigned = super.resignFirstResponder()
        if resigned {
            rawCapsLock?.pressedChangedHandler = nil
            rawCapsLock = nil
        }
        return resigned
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard forwardingEnabled, !softwareKeyboard, inputSceneIsActive else {
            super.pressesBegan(presses, with: event); return
        }
        var local = Set<UIPress>()
        for press in presses {
            guard let key = press.key, RemoteInput.macKeyCode(forHID: key.keyCode.rawValue) != nil else {
                local.insert(press)
                continue
            }
            if key.keyCode == .keyboardCapsLock {
                // GameController also sees Caps Lock when iPadOS consumes its
                // UIKit event. Use one source to avoid switching twice.
                if rawCapsLock == nil { capsLockChanged(down: true) }
                continue
            }
            receiver?.sendKey(hid: key.keyCode.rawValue, down: true,
                              modifiers: RemoteInput.iPadModifiers(UInt64(key.modifierFlags.rawValue)))
            forwardedKeys.insert(key.keyCode.rawValue)
        }
        if !local.isEmpty { super.pressesBegan(local, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let local = finish(presses)
        if !local.isEmpty { super.pressesEnded(local, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // iPadOS owns Command-Tab and can cancel without delivering its final
        // key-up. Cancellation ends the whole remote press epoch.
        releaseKeys()
        super.pressesCancelled(presses, with: event)
    }

    private func finish(_ presses: Set<UIPress>) -> Set<UIPress> {
        guard forwardingEnabled, inputSceneIsActive else { releaseKeys(); return presses }
        var local = Set<UIPress>()
        for press in presses {
            if press.key?.keyCode == .keyboardCapsLock, !softwareKeyboard {
                if rawCapsLock == nil { capsLockChanged(down: false) }
                continue
            }
            if let key = press.key, forwardedKeys.remove(key.keyCode.rawValue) != nil {
                receiver?.sendKey(hid: key.keyCode.rawValue, down: false,
                                  modifiers: RemoteInput.iPadModifiers(UInt64(key.modifierFlags.rawValue)))
            } else { local.insert(press) }
        }
        return local
    }

    private func observeCapsLock() {
        // Only the focused responder owns this global callback. Retired video
        // views must not replace or clear a new view's keyboard handler.
        guard forwardingEnabled, isFirstResponder, !softwareKeyboard else { return }
        rawCapsLock?.pressedChangedHandler = nil
        inputSourceSwitchKey.reset()
        let keyboard = GCKeyboard.coalesced
        keyboard?.handlerQueue = .main
        rawCapsLock = keyboard?.keyboardInput?.button(forKeyCode: .capsLock)
        rawCapsLock?.pressedChangedHandler = { [weak self] _, _, down in
            DispatchQueue.main.async { self?.capsLockChanged(down: down) }
        }
        Log.info("Caps Lock key capture: \(rawCapsLock == nil ? "UIKit" : "raw keyboard")")
    }

    private func capsLockChanged(down: Bool) {
        guard forwardingEnabled, inputSceneIsActive, isFirstResponder, !softwareKeyboard,
              receiver?.supportsRemoteInput == true else {
            inputSourceSwitchKey.reset()
            return
        }
        guard inputSourceSwitchKey.update(down: down) else { return }
        receiver?.sendCapsLockPress()
        Log.info("Caps Lock: forwarded key press to Mac")
    }

    private func tapKey(_ hid: Int) {
        guard forwardingEnabled else { return }
        receiver?.sendKey(hid: hid, down: true)
        receiver?.sendKey(hid: hid, down: false)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard forwardingEnabled, softwareKeyboard, textView.markedTextRange == nil, !textView.text.isEmpty else { return }
        receiver?.sendText(textView.text)
        textView.text = ""
    }

    func textViewDidEndEditing(_ textView: UITextView) { releaseKeys() }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                  replacementText text: String) -> Bool {
        if textView.markedTextRange == nil && (text == "\n" || text == "\t") {
            tapKey(text == "\n" ? 40 : 43)
            return false
        }
        return true
    }
}

private final class RemoteTextView: UITextView {
    var onEmptyDelete: (() -> Void)?
    override func deleteBackward() {
        if text.isEmpty { onEmptyDelete?() }
        else { super.deleteBackward() }
    }
}
