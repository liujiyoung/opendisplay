// The login view never opens a browser network connection. Its byte pipe is
// the app's explicit, bounded NWConnection to the selected Mac's Screen Sharing.
import '../../ThirdParty/LoginVNC/ard/ard-patch.js';
import RFB from '../../ThirdParty/LoginVNC/noVNC/core/rfb.js';
import { initLogging } from '../../ThirdParty/LoginVNC/noVNC/core/util/logging.js';

initLogging('none');
let rfb, channel, encryptionTimer;
let encrypted = false, connected = false;
const post = (message) => window.webkit.messageHandlers.macLogin.postMessage(message);

function stop() {
    clearTimeout(encryptionTimer);
    rfb?.disconnect();
    rfb = null;
    channel = null;
    encrypted = connected = false;
    document.getElementById('screen').replaceChildren();
}

function enableControl() {
    if (!encrypted || !connected || !rfb) return;
    clearTimeout(encryptionTimer);
    // No input is accepted until the Mac has enabled full tunnel encryption.
    rfb.viewOnly = false;
    rfb._rfbCredentials = {};
    rfb.focus();
    post({ type: 'status', value: '已连接并加密，请在画面中登录 Mac' });
}

window.openDisplayLogin = {
    start(credentials) {
        stop();
        channel = {
            readyState: 'connecting', binaryType: 'arraybuffer', protocol: '',
            onopen() {}, onmessage() {}, onerror() {}, onclose() {},
            send(bytes) {
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
                post({ type: 'close' });
            },
        };
        rfb = new RFB(document.getElementById('screen'), channel, { credentials, shared: true });
        rfb._ardVirtualLogin = 0; // Login to the console, never a separate background user.
        rfb._ardQualityPreset = 'millions';
        rfb.scaleViewport = true;
        rfb.resizeSession = false;
        rfb.viewOnly = true;
        rfb.addEventListener('connect', () => { connected = true; enableControl(); });
        rfb.addEventListener('ardencryptionstate', (event) => {
            encrypted = event.detail.state === 'full';
            enableControl();
        });
        rfb.addEventListener('credentialsrequired', () => {
            post({ type: 'failure', value: 'Mac 需要重新认证，请返回后重新输入用户名和密码。' });
            stop();
        });
        rfb.addEventListener('securityfailure', () => {
            post({ type: 'failure', value: 'Mac 拒绝了认证，请核对 Mac 用户名、登录密码和屏幕共享权限。' });
            stop();
        });
        rfb.addEventListener('disconnect', () => post({ type: 'close' }));
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
        if (!encrypted || !connected || !rfb) return;
        rfb.sendKey(keysym, null, true);
        rfb.sendKey(keysym, null, false);
        rfb.focus();
    },
    stop,
};
post({ type: 'ready' });
