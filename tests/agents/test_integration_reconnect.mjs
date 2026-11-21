import { strict as assert } from "node:assert";
import { test } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { createServer } from "node:net";
import { once } from "node:events";
import { client, observe } from "../../apps/cli/integrations/shared/integration.mjs";

async function until(check) {
  const deadline = Date.now() + 3000;
  while (!check()) {
    assert.ok(Date.now() < deadline, "observer did not reach the expected state");
    await delay(5);
  }
}
function fixture() {
  let handlers, connections = 0;
  const rpc = async () => {};
  rpc.watch = callbacks => {
    handlers = callbacks; connections++;
    queueMicrotask(() => callbacks.ready());
    return { close() {} };
  };
  return { rpc, get handlers() { return handlers; }, get connections() { return connections; } };
}

test("idle has no updates; local events and push notifications wake it", async t => {
  const f = fixture();
  let updates = 0;
  const observer = observe(f.rpc, () => { updates++; }, { failed: assert.fail, recovered: assert.fail });
  t.after(() => observer.stop());
  await observer.ready;
  await delay(600);
  assert.equal(updates, 1);
  assert.equal(f.connections, 1);
  observer.changed();
  await until(() => updates === 2);
  f.handlers.changed();
  await until(() => updates === 3);
});

test("coalesces events without concurrent updates", async t => {
  const f = fixture();
  let updates = 0, active = 0, maximum = 0;
  const observer = observe(f.rpc, async () => {
    updates++; active++; maximum = Math.max(maximum, active);
    await delay(20); active--;
  }, { failed: assert.fail, recovered: assert.fail });
  t.after(() => observer.stop());
  await until(() => updates === 1);
  for (let i = 0; i < 20; i++) observer.changed();
  await observer.ready;
  assert.equal(updates, 2);
  assert.equal(maximum, 1);
});

test("one disconnect/recovery per outage; resynchronizes after reconnect", async t => {
  const f = fixture();
  let errors = 0, recovered = 0, updates = 0;
  const observer = observe(f.rpc, () => { updates++; }, {
    failed: () => errors++, recovered: () => recovered++,
  });
  t.after(() => observer.stop());
  await observer.ready;
  assert.equal(recovered, 0);
  for (let outage = 1; outage <= 2; outage++) {
    f.handlers.failed(new Error("closed"));
    f.handlers.failed(new Error("missing socket"));
    assert.equal(errors, outage);
    await until(() => recovered === outage);
    assert.equal(updates, outage + 1);
  }
});

test("stop cancels reconnect and suppresses late recovery", async () => {
  const f = fixture();
  let recovered = 0;
  const observer = observe(f.rpc, () => {}, { failed: () => {}, recovered: () => recovered++ });
  await observer.ready;
  f.handlers.failed(new Error("closed"));
  await observer.stop();
  await delay(300);
  assert.equal(f.connections, 1);
  assert.equal(recovered, 0);
});

test("delivery deadline is a single event, not polling", async t => {
  const f = fixture();
  let updates = 0;
  const observer = observe(f.rpc, () => { updates++; }, { failed: assert.fail, recovered: assert.fail,
    wakeAt: () => updates === 1 ? Date.now() + 20 : null });
  t.after(() => observer.stop());
  await until(() => updates === 2);
  await delay(80);
  assert.equal(updates, 2);
});

test("real loopback subscription reconnects and preserves capability validation", async t => {
  let subscription, watchRequests = 0, updates = 0, errors = 0, recovered = 0, observer;
  const sockets = new Set();
  const server = createServer(socket => {
    sockets.add(socket); socket.on("close", () => sockets.delete(socket)); socket.on("error", () => {});
    let input = "";
    socket.on("data", chunk => {
      input += chunk;
      if (!input.includes("\n")) return;
      const request = JSON.parse(input.split("\n")[0]);
      assert.equal(request.token, "test-pane-capability");
      assert.equal(request.version, 1);
      if (request.method === "graph.watch") {
        watchRequests++; subscription = socket;
        socket.write(JSON.stringify({ id: request.id, version: 1, result: { watching: true } }) + "\n");
      } else socket.end(JSON.stringify({ id: request.id, version: 1, result: { ok: true } }) + "\n");
    });
  });
  t.after(async () => {
    await observer?.stop();
    for (const socket of sockets) socket.destroy();
    if (server.listening) await new Promise(resolve => server.close(resolve));
  });
  server.listen(0, "127.0.0.1"); await once(server, "listening");
  const port = server.address().port;
  const rpc = client(`tcp://127.0.0.1:${port}`, "test-pane-capability");
  observer = observe(rpc, async () => { await rpc("graph.take"); updates++; }, {
    failed: () => errors++, recovered: () => recovered++,
  });
  await observer.ready;
  assert.equal(updates, 1);
  subscription.write('{"version":1,"method":"graph.changed","params":{}}\n');
  await until(() => updates === 2);
  subscription.destroy();
  await new Promise(resolve => server.close(resolve));
  await until(() => errors === 1);
  await delay(300);
  assert.equal(errors, 1);
  server.listen(port, "127.0.0.1"); await once(server, "listening");
  await until(() => recovered === 1);
  assert.equal(updates, 3);
  assert.equal(watchRequests, 2);
});
