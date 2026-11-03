import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

// Exercise the native bridge's lifecycle without a Mac password or network.
function loginClient() {
    const clients = [], posts = [], updates = [], keys = [];
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
    }
    const context = vm.createContext({
        RFB, initLogging() {}, setTimeout() { return 1; }, clearTimeout() {},
        window: { webkit: { messageHandlers: { macLogin: { postMessage: m => posts.push(m) } } } },
        document: { getElementById() { return { replaceChildren() {} }; } },
    });
    const source = readFileSync(new URL('../../iOS/LoginResources/login.js', import.meta.url), 'utf8');
    vm.runInContext(source.replace(/^import .*;\n/gm, ''), context);
    return { api: context.window.openDisplayLogin, clients, posts, updates, keys, RFB };
}

test('handoff retains authentication, disables hidden input and framebuffer renewals, then resumes', () => {
    const { api, clients, posts, updates, keys, RFB } = loginClient();
    api.start({ username: 'test', password: 'test-only' });
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
