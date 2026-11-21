import { test } from "node:test";
import assert from "node:assert/strict";
import { createServer } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { attach, endpoint, launch, placement } from "@graffitty/playwright";

async function host(t, handle) {
  const directory = await mkdtemp(join(tmpdir(), "gpw-"));
  const socket = process.platform === "win32"
    ? `\\\\.\\pipe\\graffitty-playwright-${directory.split(/[\\/]/).pop()}`
    : join(directory, "api.sock");
  const server = createServer(stream => {
    let input = "";
    stream.setEncoding("utf8");
    stream.on("data", data => {
      input += data;
      if (!input.includes("\n")) return;
      const request = JSON.parse(input.split("\n")[0]);
      input = "";
      const response = handle(request);
      if (response === undefined) return;
      stream.end(JSON.stringify({ version: 1, id: request.id, ...response }) + "\n");
    });
  });
  await new Promise(resolve => server.listen(socket, resolve));
  t.after(async () => {
    await new Promise(resolve => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  return { chromium: "%7", socket, token: "workspace-secret", timeout: 500 };
}

test("rejects invalid identity and timeout without launching a chromium", async () => {
  await assert.rejects(attach({ chromium: "focused" }), /%N/);
  await assert.rejects(attach({ chromium: "%1", socket: "/absent", token: "x", timeout: 0 }), /positive/);
});

test("propagates host authorization errors", async t => {
  const options = await host(t, request => {
    assert.equal(request.token, "workspace-secret");
    assert.equal(request.method, "chromium.attach");
    assert.equal(request.params.chromium, "%7");
    return { error: { code: "forbidden", message: "Chromium belongs to another workspace" } };
  });
  await assert.rejects(attach(options), /forbidden.*another workspace/);
});

test("checks response identity and request timeout", async t => {
  let mismatch = true;
  const options = await host(t, () => mismatch ? { id: "wrong", result: {} } : undefined);
  await assert.rejects(attach(options), /Invalid Graffitty/);
  mismatch = false;
  await assert.rejects(attach({ ...options, timeout: 20 }), /timed out/);
});

test("failed CDP attachment releases lease and redacts its bearer URL", async t => {
  const lease = "never-print-this-lease";
  const endpoint = `ws://127.0.0.1:1/${lease}`;
  let released = false;
  const options = await host(t, request => {
    if (request.method === "chromium.attach") return { result: { endpoint, lease, target_id: "page" } };
    assert.equal(request.method, "chromium.detach");
    assert.equal(request.params.lease, lease);
    released = true;
    return { result: { detached: true } };
  });
  await assert.rejects(attach(options), error => {
    assert.equal(error.message.includes(lease), false);
    assert.equal(error.message.includes(endpoint), false);
    return true;
  });
  assert.equal(released, true);
});

test("placement defaults to the right of this terminal and validates combinations", () => {
  assert.deepEqual(placement({}), { side: "right" });
  assert.deepEqual(placement({ side: "below", of: "%2" }), { side: "below", of: "%2" });
  assert.deepEqual(placement({ position: { x: 10, y: 20 }, size: { width: 640, height: 480 } }),
    { x: 10, y: 20, width: 640, height: 480 });
  assert.equal(placement({ hidden: true }), undefined);
  assert.throws(() => placement({ hidden: true, side: "left" }), /hidden/);
  assert.throws(() => placement({ side: "left", position: { x: 1, y: 2 } }), /not both/);
  assert.throws(() => placement({ of: "%2" }), /of requires side/);
  assert.throws(() => placement({ side: "diagonal" }), /side must be/);
  assert.throws(() => placement({ size: { width: 10, height: 480 } }), /40 by 40/);
});

test("launch creates, places, retries a not-ready page, then cleans up on failure", async t => {
  const calls = [];
  let attempts = 0;
  const options = await host(t, request => {
    calls.push([request.method, request.params]);
    switch (request.method) {
      case "chromium.create": return { result: { chromium: "%9" } };
      case "pane.place": return { result: { pane: "%9", rect: [0, 0, 1, 1] } };
      case "chromium.attach":
        attempts += 1;
        if (attempts < 3) return { error: { code: "chromium_error", message: "Chromium page is not ready" } };
        // An unreachable endpoint fails CDP after the retries, exercising cleanup.
        return { result: { endpoint: "ws://127.0.0.1:1/x", lease: "lease", target_id: "page" } };
      case "chromium.detach": return { result: { detached: true } };
      case "chromium.close": return { result: { closed: true } };
    }
  });
  const { chromium, ...connection } = options;
  await assert.rejects(launch({ ...connection, timeout: 2000, url: "http://localhost:3000", side: "below", of: "%2" }));
  assert.deepEqual(calls[0], ["chromium.create", { url: "http://localhost:3000" }]);
  assert.deepEqual(calls[1], ["pane.place", { target: "%9", side: "below", of: "%2" }]);
  assert.equal(attempts, 3, "not-ready attachment is retried");
  assert.deepEqual(calls.at(-1), ["chromium.close", { chromium: "%9" }], "a failed launch removes its pane");
});

test("hidden launch skips placement and invalid options create nothing", async t => {
  const calls = [];
  const options = await host(t, request => {
    calls.push(request.method);
    if (request.method === "chromium.create") return { result: { chromium: "%9" } };
    if (request.method === "chromium.attach") return { error: { code: "forbidden", message: "no" } };
    return { result: {} };
  });
  const { chromium, ...connection } = options;
  await assert.rejects(launch({ ...connection, hidden: true }), /forbidden/);
  assert.deepEqual(calls, ["chromium.create", "chromium.attach", "chromium.close"]);
  calls.length = 0;
  await assert.rejects(launch({ ...connection, side: "left", position: { x: 1, y: 2 } }), /not both/);
  await assert.rejects(launch({ ...connection, profile: "/a", profileTemplate: "/b" }), /either/);
  assert.deepEqual(calls, [], "validation happens before creating a pane");
});

test("accepts the session server's ipc:// and loopback tcp:// endpoints like gft", async t => {
  assert.deepEqual(endpoint("ipc:///tmp/graffitty/session.sock"), { path: "/tmp/graffitty/session.sock" });
  assert.deepEqual(endpoint("/tmp/api.sock"), { path: "/tmp/api.sock" });
  assert.deepEqual(endpoint("tcp://127.0.0.1:7183"), { host: "127.0.0.1", port: 7183 });
  assert.throws(() => endpoint("tcp://10.0.0.5:7183"), /loopback/);
  assert.throws(() => endpoint("tcp://127.0.0.1:99999"), /loopback/);
  // A real request over an ipc:// endpoint reaches the host.
  const options = await host(t, () => ({ error: { code: "forbidden", message: "reached" } }));
  await assert.rejects(attach({ ...options, socket: "ipc://" + options.socket }), /forbidden: reached/);
});
