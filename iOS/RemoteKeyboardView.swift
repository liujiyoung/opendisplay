import UIKit
import GameController

/// Physical keys go to the Mac's input source without starting an iPad IME.
/// Only the explicit keyboard button focuses the native text input below.
final class RemoteKeyboardView: UIView, UITextViewDelegate {
    weak var receiver: StreamReceiver?
    private var softwareKeyboard = false
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
                DispatchQueue.main.async { self?.observeCapsLock() }
            })
        }
    }

    deinit {
        for token in keyboardObservers { NotificationCenter.default.removeObserver(token) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? { [] }

    override func becomeFirstResponder() -> Bool {
        let focused = super.becomeFirstResponder()
        if focused { observeCapsLock() }
        return focused
    }

    func focus() {
        if softwareKeyboard { textInput.becomeFirstResponder() }
        else { becomeFirstResponder() }
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
        guard !softwareKeyboard else { super.pressesBegan(presses, with: event); return }
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
        let local = finish(presses)
        if !local.isEmpty { super.pressesCancelled(local, with: event) }
    }

    private func finish(_ presses: Set<UIPress>) -> Set<UIPress> {
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
        guard isFirstResponder, !softwareKeyboard else { return }
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
        guard window != nil, isFirstResponder, !softwareKeyboard,
              UIApplication.shared.applicationState == .active,
              receiver?.supportsRemoteInput == true else {
            inputSourceSwitchKey.reset()
            return
        }
        guard inputSourceSwitchKey.update(down: down) else { return }
        receiver?.sendCapsLockPress()
        Log.info("Caps Lock: forwarded key press to Mac")
    }

    private func tapKey(_ hid: Int) {
        receiver?.sendKey(hid: hid, down: true)
        receiver?.sendKey(hid: hid, down: false)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard softwareKeyboard, textView.markedTextRange == nil, !textView.text.isEmpty else { return }
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
