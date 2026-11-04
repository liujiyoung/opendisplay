// The login view never opens a browser network connection. Its byte pipe is
// the app's explicit, bounded NWConnection to the selected Mac's Screen Sharing.
import '../../ThirdParty/LoginVNC/ard/ard-patch.js';
import RFB from '../../ThirdParty/LoginVNC/noVNC/core/rfb.js';
import { initLogging } from '../../ThirdParty/LoginVNC/noVNC/core/util/logging.js';

initLogging('none');
let rfb, channel, encryptionTimer;
let encrypted = false, connected = false;
let visible = true;
let inputOnly = true;
const post = (message) => window.webkit.messageHandlers.macLogin.postMessage(message);
const screen = document.getElementById('screen');
const guide = document.getElementById('guide');
const target = document.getElementById('guide-target');
const guideFrame = document.getElementById('guide-frame');
const guideNote = document.getElementById('guide-note');

function hasScreenSize() {
    return rfb && rfb._fbWidth > 0 && rfb._fbHeight > 0;
}

function updateGuide() {
    const shown = inputOnly && visible && encrypted && connected && !!rfb;
    guide.hidden = !shown;
    screen.classList.toggle('input-only', shown);
    target.disabled = !shown || !hasScreenSize();
    if (!shown) return;
    const area = screen.getBoundingClientRect();
    // Use the actual noVNC canvas after its fit-to-window scaling. This also
    // accounts for letterboxing, rotation, and the native toolbar's height.
    const canvas = hasScreenSize() ? rfb._canvas.getBoundingClientRect() : area;
    const left = canvas.left - area.left, top = canvas.top - area.top;
    Object.assign(guideFrame.style, { left: `${left}px`, top: `${top}px`,
        width: `${canvas.width}px`, height: `${canvas.height}px` });
    target.style.left = `${left + canvas.width * 0.5}px`;
    target.style.top = `${top + canvas.height * 0.9}px`;
    guideNote.textContent = hasScreenSize()
        ? '参考位置：远程屏幕中央、90% 高度。不同 Mac 登录布局可能偏移；这里不会显示或保存密码。'
        : '正在等待 Mac 屏幕尺寸，暂不能发送定位点击。可关闭开关恢复画面。';
}

// Resize also occurs in protocol messages without browser resize events.
const resizeFramebuffer = RFB.prototype._resize;
RFB.prototype._resize = function (width, height) {
    resizeFramebuffer.call(this, width, height);
    if (this === rfb) updateGuide();
};
window.addEventListener('resize', updateGuide);

function focusPasswordReference() {
    if (!visible || !inputOnly || !encrypted || !connected || !hasScreenSize()) return;
    const rect = rfb._canvas.getBoundingClientRect();
    // Go through noVNC's normal mouse path, including its scale conversion,
    // button bookkeeping and the existing encrypted socket. Never type or
    // cache a password here; the user's physical keyboard remains in control.
    rfb._handleMouseButton(rect.width * 0.5, rect.height * 0.9, 1);
    rfb._handleMouseButton(rect.width * 0.5, rect.height * 0.9, 0);
    rfb.focus({ preventScroll: true });
    post({ type: 'status', value: '已点击密码框参考位置；请直接输入 Mac 密码并按 Return（画面已暂停）' });
}
target.addEventListener('click', focusPasswordReference);

// ARD renews subscriptions on Tickles and display changes. Keep the hidden
// login authenticated without a second video stream competing with OpenDisplay.
const autoFBUpdate = RFB.messages.ardAutoFBUpdate;
RFB.messages.ardAutoFBUpdate = (sock, enabled, ...region) => {
    if (sock.openDisplayLoginPaused && enabled) return;
    autoFBUpdate(sock, enabled, ...region);
};
const fbUpdateRequest = RFB.messages.fbUpdateRequest;
RFB.messages.fbUpdateRequest = (sock, ...args) => {
    if (!sock.openDisplayLoginPaused) fbUpdateRequest(sock, ...args);
};

function stop() {
    clearTimeout(encryptionTimer);
    const old = rfb;
    rfb = null;
    channel = null;
    encrypted = connected = false;
    old?.disconnect();
    screen.replaceChildren();
    updateGuide();
}

function setVisible(value) {
    visible = !!value;
    updateGuide();
    if (!rfb) return;
    // Release held VNC keys while input is still enabled, before ungrabbing.
    if (!visible) rfb._keyboard.ungrab();
    rfb.viewOnly = !visible || !encrypted || !connected;
    if (visible && !rfb.viewOnly) rfb.focus();
    else rfb.blur();
    if (!encrypted || !connected) return;
    const sock = rfb._sock;
    const showVideo = visible && !inputOnly;
    sock.openDisplayLoginPaused = !showVideo;
    RFB.messages.ardAutoFBUpdate(sock, showVideo ? 1 : 0,
        0, 0, rfb._fbWidth, rfb._fbHeight);
    if (showVideo) RFB.messages.fbUpdateRequest(sock, false,
        0, 0, rfb._fbWidth, rfb._fbHeight);
}

function setInputOnly(value) {
    inputOnly = !!value;
    // Keep initial ARD setup and full-encryption negotiation intact. Pausing
    // before it finishes can suppress the control rectangles carrying keys.
    setVisible(visible);
    if (encrypted && connected) post({ type: 'status', value: inputOnly
        ? '已连接并加密 · 仅键鼠控制，请点击密码框参考位置'
        : '已连接并加密，请在画面中登录 Mac' });
}

function enableControl() {
    if (!encrypted || !connected || !rfb) return;
    clearTimeout(encryptionTimer);
    // No input is accepted until the Mac has enabled full tunnel encryption.
    rfb._rfbCredentials = {};
    post({ type: 'authenticated' });
    setInputOnly(inputOnly);
}

window.openDisplayLogin = {
    start(credentials, options = {}) {
        stop();
        visible = true;
        inputOnly = options.inputOnly !== false;
        channel = {
            readyState: 'connecting', binaryType: 'arraybuffer', protocol: '',
            onopen() {}, onmessage() {}, onerror() {}, onclose() {},
            send(bytes) {
                if (channel !== this || this.readyState !== 'open') return;
                const data = bytes instanceof ArrayBuffer ? new Uint8Array(bytes) : bytes;
                // Send queue chunks are small; avoid a spread-call stack overflow.
                let binary = '';
                for (let i = 0; i < data.length; i += 8192) {
                    binary += String.fromCharCode(...data.subarray(i, i + 8192));
                }
                post({ type: 'send', data: btoa(binary) });
            },
            close() {
                if (this.readyState === 'closed') return;
                this.readyState = 'closed';
                if (channel === this) post({ type: 'close' });
            },
        };
        rfb = new RFB(screen, channel, { credentials, shared: true });
        const client = rfb;
        rfb._ardVirtualLogin = 0; // Login to the console, never a separate background user.
        rfb._ardQualityPreset = 'millions';
        rfb.scaleViewport = true;
        rfb.resizeSession = false;
        rfb.viewOnly = true;
        rfb.addEventListener('connect', () => {
            if (rfb !== client) return;
            connected = true;
            enableControl();
        });
        rfb.addEventListener('ardencryptionstate', (event) => {
            if (rfb !== client) return;
            encrypted = event.detail.state === 'full';
            enableControl();
        });
        rfb.addEventListener('credentialsrequired', () => {
            if (rfb !== client) return;
            post({ type: 'failure', value: 'Mac 需要重新认证，请返回后重新输入用户名和密码。' });
            stop();
        });
        rfb.addEventListener('securityfailure', () => {
            if (rfb !== client) return;
            post({ type: 'failure', value: 'Mac 拒绝了认证，请核对 Mac 用户名、登录密码和屏幕共享权限。' });
            stop();
        });
        rfb.addEventListener('disconnect', () => {
            if (rfb === client) post({ type: 'close' });
        });
        encryptionTimer = setTimeout(() => {
            if (!encrypted) {
                post({ type: 'failure', value: 'Mac 未能建立加密登录连接，已停止；请核对屏幕共享和网络。' });
                stop();
            }
        }, 20000);
        // RFB finishes attaching its handlers in its constructor.
        channel.readyState = 'open';
        channel.onopen();
    },
    receive(base64) {
        if (!channel || channel.readyState !== 'open') return;
        const binary = atob(base64);
        const data = Uint8Array.from(binary, (c) => c.charCodeAt(0));
        channel.onmessage({ data: data.buffer });
    },
    key(keysym) {
        if (!visible || !encrypted || !connected || !rfb) return;
        rfb.sendKey(keysym, null, true);
        rfb.sendKey(keysym, null, false);
        rfb.focus();
    },
    setVisible,
    setInputOnly,
    focusPasswordReference,
    stop,
};
post({ type: 'ready' });
