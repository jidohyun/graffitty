// Exercise the bundled plugin transport, including Windows' loopback endpoint.
import { strict as assert } from "node:assert";
import { load } from "../../apps/cli/integrations/shared/loader.mjs";
import { createServer } from "node:net";
import { once } from "node:events";
import { test } from "node:test";

const binary = process.env.GRAFFITTY_TEST_CLI || new URL("../../dist/bin/gft", import.meta.url).pathname;
const { client } = await load(binary, "pi", "main");

async function endpoint(t, responder) {
  const server = createServer(socket => {
    let input = "";
    socket.on("error", () => {});
    socket.on("data", chunk => {
      input += chunk;
      if (!input.includes("\n")) return;
      const request = JSON.parse(input.split("\n")[0]);
      responder(socket, request);
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(() => new Promise(resolve => server.close(resolve)));
  return client(`tcp://127.0.0.1:${server.address().port}`, "test-capability");
}

test("loopback transport preserves framing, UTF-8 and pane capability", async t => {
  const rpc = await endpoint(t, (socket, request) => {
    assert.equal(request.version, 1);
    assert.equal(request.token, "test-capability");
    assert.equal(request.method, "graph.adjacent");
    const reply = Buffer.from(JSON.stringify({ id: request.id, result: { text: "완료" } }) + "\n");
    const split = reply.indexOf(Buffer.from("완")) + 1;
    socket.write(reply.subarray(0, split));
    setTimeout(() => socket.end(reply.subarray(split)), 10);
  });
  assert.deepEqual(await rpc("graph.adjacent"), { text: "완료" });
  assert.throws(() => client("tcp://192.0.2.1:99", "test"), /loopback/);
});

test("mismatched response IDs cannot satisfy a request", async t => {
  const rpc = await endpoint(t, socket => socket.end(JSON.stringify({ id: "wrong", result: {} }) + "\n"));
  await assert.rejects(rpc("graph.list"), /ID mismatch/);
});

test("server permission errors and cancellation reach the caller", async t => {
  const rpc = await endpoint(t, (socket, request) => socket.end(JSON.stringify({ id: request.id,
    error: { message: "Read permission denied" } }) + "\n"));
  await assert.rejects(rpc("graph.read", { node: "%2" }), /Read permission denied/);
  await assert.rejects(rpc("graph.list", {}, AbortSignal.abort()), /aborted/);
  await assert.rejects(rpc("graph.send", { text: "x".repeat(4 * 1024 * 1024) }), /too large/);
});
