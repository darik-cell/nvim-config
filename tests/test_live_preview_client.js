const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sockets = [];
const events = {};
const timeouts = new Map();
const renders = [];
let reloads = 0;
class WebSocket {
  constructor(url) {
    this.url = url;
    sockets.push(this);
  }
  close() {
    this.closed = true;
  }
}
const context = {
  WebSocket,
  window: {
    location: {
      host: "127.0.0.1:1234",
      pathname: "/notes/2%20%D0%9F%D1%80.md",
      reload() { reloads++; },
    },
    addEventListener(name, callback) { events[name] = callback; },
  },
  document: { querySelectorAll() { return []; } },
  setTimeout(callback) {
    const id = timeouts.size + 1;
    timeouts.set(id, callback);
    return id;
  },
  clearTimeout(id) { timeouts.delete(id); },
  livepreview_render(content) { renders.push(content); },
};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../.config/nvim/static/livepreview/ws-client.js"), "utf8"), context);

assert.equal(sockets.length, 1, "Exactly one connection for the opened page");
assert.equal(sockets[0].url, "ws://127.0.0.1:1234");
sockets[0].onopen();
sockets[0].onmessage({ data: JSON.stringify({ type: "update", filepath: "/elsewhere/2 Пр.md", content: "wrong" }) });
sockets[0].onmessage({ data: JSON.stringify({ type: "update", filepath: "/notes/2 Пр.md", content: "right" }) });
assert.deepEqual(renders, ["right"], "Updates must match the full decoded source path");
events.pagehide();
assert.equal(sockets[0].closed, true);
events.pageshow({ persisted: true });
assert.equal(sockets.length, 2, "BFCache restore reconnects the page");
sockets[0].onclose();
assert.equal(timeouts.size, 0, "Late close from old page must not create another connection");
sockets[1].onopen();
assert.equal(reloads, 1, "Reconnect reloads content that could have changed while disconnected");
sockets[1].onclose();
assert.equal(timeouts.size, 1);
events.pagehide();
assert.equal(timeouts.size, 0, "Closing a tab cancels reconnect attempts");
console.log("Browser connection, source identity, BFCache and reconnect checks passed");
