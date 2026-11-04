import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

// Exercise the native bridge's lifecycle without a Mac password or network.
function loginClient() {
    const clients = [], posts = [], updates = [], keys = [], clicks = [];
    const elements = new Map();
    function element(id) {
        if (!elements.has(id)) elements.set(id, {
            style: {}, classList: { toggle() {} }, replaceChildren() {},
            addEventListener(type, listener) { this[type] = listener; },
            getBoundingClientRect() { return { left: 0, top: 0, width: 1000, height: 600 }; },
        });
        return elements.get(id);
    }
    class RFB {
        static messages = {
            ardAutoFBUpdate(sock, enabled) { updates.push(['auto', enabled]); },
            fbUpdateRequest() { updates.push(['full']); },
        };
        constructor(target, pipe, options) {
            this.pipe = pipe;
            this._rfbCredentials = options.credentials;
            this._sock = {};
            this._fbWidth = 800;
            this._fbHeight = 600;
            this._canvas = { getBoundingClientRect: () => ({ left: 100, top: 0, width: 800, height: 600 }) };
            this._keyboard = { ungrab: () => { this.keysReleased = true; } };
            this.handlers = new Map();
            clients.push(this);
        }
        addEventListener(type, handler) { this.handlers.set(type, handler); }
        emit(type, detail = {}) { this.handlers.get(type)?.({ detail }); }
        disconnect() { this.disconnected = true; this.pipe.close(); this.emit('disconnect'); }
        focus() { this.focused = true; }
        blur() { this.focused = false; }
        sendKey(...args) { keys.push(args); }
        _handleMouseButton(...args) { clicks.push(args); }
        _resize(width, height) { this._fbWidth = width; this._fbHeight = height; }
    }
    const context = vm.createContext({
        RFB, initLogging() {}, setTimeout() { return 1; }, clearTimeout() {},
        window: { addEventListener() {}, webkit: { messageHandlers: { macLogin: { postMessage: m => posts.push(m) } } } },
        document: { getElementById: element },
    });
    const source = readFileSync(new URL('../../iOS/LoginResources/login.js', import.meta.url), 'utf8');
    vm.runInContext(source.replace(/^import .*;\n/gm, ''), context);
    return { api: context.window.openDisplayLogin, clients, posts, updates, keys, clicks, elements, RFB };
}

test('handoff retains authentication, disables hidden input and framebuffer renewals, then resumes', () => {
    const { api, clients, posts, updates, keys, RFB } = loginClient();
    api.start({ username: 'test', password: 'test-only' }, { inputOnly: false });
    const client = clients[0];
    client.emit('connect');
    api.key(0xff0d);
    assert.equal(keys.length, 0);
    assert.equal(posts.some(p => p.type === 'authenticated'), false);
    client.emit('ardencryptionstate', { state: 'full' });
    assert.equal(posts.some(p => p.type === 'authenticated'), true);
    assert.equal(Object.keys(client._rfbCredentials).length, 0);

    api.setVisible(false);
    assert.equal(client.disconnected, undefined);
    assert.equal(client.keysReleased, true);
    assert.equal(client.viewOnly, true);
    assert.equal(client.focused, false);
    assert.deepEqual(updates.at(-1), ['auto', 0]);
    const count = updates.length;
    // ARD Tickle and DisplayInfo2 must not restart the hidden video stream.
    RFB.messages.ardAutoFBUpdate(client._sock, 1, 0, 0, 800, 600);
    RFB.messages.fbUpdateRequest(client._sock, false, 0, 0, 800, 600);
    api.key(0xff0d);
    assert.equal(updates.length, count);
    assert.equal(keys.length, 0);

    api.setVisible(true);
    assert.equal(clients.length, 1);
    assert.equal(client.viewOnly, false);
    assert.equal(client.focused, true);
    assert.deepEqual(updates.slice(-2), [['auto', 1], ['full']]);
    api.key(0xff0d);
    assert.equal(keys.length, 2);
    api.stop();
    assert.equal(client.disconnected, true);
});

test('input-only mode retains encrypted keyboard and a scaled reference click while stopping video', () => {
    const { api, clients, updates, keys, clicks, elements, RFB } = loginClient();
    api.start({ username: 'test', password: 'test-only' });
    const client = clients[0];
    client.emit('connect');
    api.focusPasswordReference();
    assert.equal(clicks.length, 0);
    // Encryption setup may itself arrive in framebuffer control rectangles.
    RFB.messages.ardAutoFBUpdate(client._sock, 1, 0, 0, 800, 600);
    assert.deepEqual(updates.at(-1), ['auto', 1]);
    client.emit('ardencryptionstate', { state: 'full' });
    assert.equal(client.viewOnly, false);
    assert.deepEqual(updates.at(-1), ['auto', 0]);
    assert.equal(elements.get('guide').hidden, false);
    assert.equal(elements.get('guide-target').style.left, '500px'); // canvas's 100px letterbox + center
    assert.equal(elements.get('guide-target').style.top, '540px');
    elements.get('guide-target').click();
    assert.deepEqual(clicks, [[400, 540, 1], [400, 540, 0]]);
    assert.equal(client.focused, true);
    api.key(0xff0d);
    assert.equal(keys.length, 2);
    const count = updates.length;
    RFB.messages.ardAutoFBUpdate(client._sock, 1, 0, 0, 800, 600);
    RFB.messages.fbUpdateRequest(client._sock, false, 0, 0, 800, 600);
    assert.equal(updates.length, count);

    api.setVisible(false);
    api.focusPasswordReference();
    api.key(0xff0d);
    assert.equal(clicks.length, 2);
    assert.equal(keys.length, 2);
    api.setVisible(true);
    assert.equal(client.disconnected, undefined);
    assert.equal(client.viewOnly, false);
    assert.deepEqual(updates.at(-1), ['auto', 0]);

    api.setInputOnly(false);
    assert.equal(elements.get('guide').hidden, true);
    assert.deepEqual(updates.slice(-2), [['auto', 1], ['full']]);
    api.focusPasswordReference();
    assert.equal(clicks.length, 2);
});

test('reference click waits for real screen dimensions and follows canvas layout changes', () => {
    const { api, clients, clicks, elements } = loginClient();
    api.start({ username: 'test', password: 'test-only' });
    const client = clients[0];
    client._resize(0, 0);
    client.emit('connect');
    client.emit('ardencryptionstate', { state: 'full' });
    assert.equal(elements.get('guide-target').disabled, true);
    api.focusPasswordReference();
    assert.equal(clicks.length, 0);
    client._canvas.getBoundingClientRect = () => ({ left: 300, top: 25, width: 400, height: 550 });
    client._resize(1200, 1650);
    assert.equal(elements.get('guide-target').disabled, false);
    assert.equal(elements.get('guide-target').style.left, '500px');
    assert.equal(elements.get('guide-target').style.top, '520px');
    api.focusPasswordReference();
    assert.deepEqual(clicks, [[200, 495, 1], [200, 495, 0]]);
    api.stop();
    assert.equal(elements.get('guide').hidden, true);
    api.focusPasswordReference();
    assert.equal(clicks.length, 2);
});

test('callbacks from a replaced RFB client cannot close or authenticate its replacement', () => {
    const { api, clients, posts } = loginClient();
    api.start({ username: 'test', password: 'first' });
    const old = clients[0];
    api.start({ username: 'test', password: 'second' });
    old.emit('disconnect');
    old.emit('connect');
    old.emit('ardencryptionstate', { state: 'full' });
    old.emit('securityfailure');
    old.pipe.send(new Uint8Array([1, 2, 3]));
    assert.equal(posts.some(p => ['close', 'authenticated', 'failure'].includes(p.type)), false);
    assert.equal(posts.some(p => p.type === 'send'), false);
    assert.equal(clients[1].disconnected, undefined);
    api.stop();
});
