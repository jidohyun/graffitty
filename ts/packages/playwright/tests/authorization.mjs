import assert from "node:assert/strict";
import { connect } from "node:net";
import { writeFile } from "node:fs/promises";
import { once } from "node:events";

function rpc(method, params = {}) {
  return new Promise((resolve, reject) => {
    const stream = connect(process.env.GRAFFITTY_SOCKET);
    let text = "";
    stream.setTimeout(5000, () => stream.destroy(new Error("RPC timeout")));
    stream.on("error", reject);
    stream.on("connect", () => stream.write(JSON.stringify({ version: 1, id: 1,
      token: process.env.GRAFFITTY_TOKEN, method,
      params: { chromium: process.env.GRAFFITTY_CHROMIUM, ...params } }) + "\n"));
    stream.on("data", chunk => {
      text += chunk;
      if (!text.includes("\n")) return;
      stream.destroy();
      resolve(JSON.parse(text.split("\n")[0]));
    });
  });
}

const response = await rpc("chromium.attach");
assert.ok(response.result);
const lease = response.result;
if (process.argv[2] !== "revoke") {
  const wrong = new WebSocket(lease.endpoint.replace(lease.lease, "incorrect-secret"));
  let received = false;
  wrong.addEventListener("message", () => { received = true; });
  const [closed] = await once(wrong, "close");
  assert.equal(closed.code, 1008);
  assert.equal(received, false, "Unauthenticated clients receive no CDP data");
}
const socket = new WebSocket(lease.endpoint);
await once(socket, "open");
const version = once(socket, "message");
socket.send(JSON.stringify({ id: 1, method: "Browser.getVersion" }));
assert.ok(JSON.parse((await version)[0].data).result.product.startsWith("Chrome/"));
if (process.argv[2] === "revoke") {
  const closed = once(socket, "close");
  await writeFile(process.env.GRAFFITTY_PLAYWRIGHT_TEST_DIR + "/revoke", "");
  await closed;
  assert.equal((await rpc("chromium.attach")).error.code, "unauthorized");
  console.log("PASS: workspace revocation disconnects CDP and invalidates attachment authority");
} else {
  const result = once(socket, "message");
  socket.send(JSON.stringify({ id: 2, method: "Browser.close" }));
  assert.match(JSON.parse((await result)[0].data).error.message, /Graffitty owns/);
  const closed = once(socket, "close");
  socket.close(); // No chromium.detach API call: host observes transport departure.
  await closed;
  let next;
  for (let i = 0; i < 30; i++) {
    next = await rpc("chromium.attach");
    if (next.result) break;
    assert.equal(next.error.code, "chromium_busy");
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  assert.ok(next.result, "Disconnect releases the lease without a helper cleanup call");
  assert.notEqual(next.result.lease, lease.lease);
  await rpc("chromium.detach", { lease: lease.lease });
  assert.equal((await rpc("chromium.attach")).error.code, "chromium_busy", "Old lease cannot revoke a newer attachment");
  await rpc("chromium.detach", { lease: next.result.lease });
  console.log("PASS: WebSocket authentication, owner shutdown protection, disconnect cleanup, lease isolation");
}
