// The login view never opens a browser network connection. Its byte pipe is
// the app's explicit, bounded NWConnection to the selected Mac's Screen Sharing.
import '../../ThirdParty/LoginVNC/ard/ard-patch.js';
import RFB from '../../ThirdParty/LoginVNC/noVNC/core/rfb.js';
import { initLogging } from '../../ThirdParty/LoginVNC/noVNC/core/util/logging.js';

initLogging('none');
let rfb, channel, encryptionTimer;
let encrypted = false, connected = false;
let visible = true;
const post = (message) => window.webkit.messageHandlers.macLogin.postMessage(message);

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
    document.getElementById('screen').replaceChildren();
}

function setVisible(value) {
    visible = !!value;
    if (!rfb) return;
    // Release held VNC keys while input is still enabled, before ungrabbing.
    if (!visible) rfb._keyboard.ungrab();
    rfb.viewOnly = !visible || !encrypted || !connected;
    if (visible && !rfb.viewOnly) rfb.focus();
    else rfb.blur();
    if (!encrypted || !connected) return;
    const sock = rfb._sock;
    sock.openDisplayLoginPaused = !visible;
    RFB.messages.ardAutoFBUpdate(sock, visible ? 1 : 0,
        0, 0, rfb._fbWidth, rfb._fbHeight);
    if (visible) RFB.messages.fbUpdateRequest(sock, false,
        0, 0, rfb._fbWidth, rfb._fbHeight);
}

function enableControl() {
    if (!encrypted || !connected || !rfb) return;
    clearTimeout(encryptionTimer);
    // No input is accepted until the Mac has enabled full tunnel encryption.
    rfb._rfbCredentials = {};
    setVisible(visible);
    post({ type: 'authenticated' });
    post({ type: 'status', value: '已连接并加密，请在画面中登录 Mac' });
}

window.openDisplayLogin = {
    start(credentials) {
        stop();
        visible = true;
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
        rfb = new RFB(document.getElementById('screen'), channel, { credentials, shared: true });
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
    stop,
};
post({ type: 'ready' });
