// Test-only host API driver. Production plugins run this runtime in-process.
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { join } from "node:path";

const [provider, directory, mode = "observe"] = process.argv.slice(2);
const moduleAt = file => import(pathToFileURL(join(directory, file)).href);
const { home, binary } = await moduleAt("config.js");
const { load } = await moduleAt("loader.mjs");
const common = await load(binary, provider, provider === "pi" ? "main" : "tui");
const { guide } = common;
const lines = createInterface({ input: process.stdin });
const input = lines[Symbol.asyncIterator]();
let sequence = 0;
const call = async (op, fields = {}) => {
  const id = ++sequence;
  process.stdout.write(JSON.stringify({ id, op, ...fields }) + "\n");
  const line = await input.next();
  if (line.done) throw new Error("EOF");
  const reply = JSON.parse(line.value);
  if (reply.id !== id) throw new Error("Test driver ID mismatch");
  if (reply.error) throw new Error(reply.error);
  return reply.result;
};

if (mode !== "observe") {
  try {
    const value = JSON.parse((await input.next()).value || "{}");
    const rpc = provider === "opencode" ? common.boundClient(home, value.sessionID) : common.client();
    if (!rpc && mode !== "context") throw new Error("This OpenCode session is not attached to a Graffitty pane");
    if (rpc) console.log(mode === "context" ? await common.graphContext(rpc, guide, provider) : await common.tool(rpc, value));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
  lines.close();
} else {
  const module = common;
  const runtime = provider === "pi"
    ? new module.PiIntegration(common.client(), home, fields => call("prompt", fields))
    : new module.OpenCodeIntegration(common.client(), home, {
      prompt: fields => call("prompt", fields), cancel: fields => call("cancel", fields),
    });
  try {
    while (true) {
      const snapshot = await call("snapshot");
      await runtime.update(snapshot);
      if (snapshot.closing) break;
    }
  } catch (error) {
    if (error.message !== "EOF") { console.error(error); process.exitCode = 1; }
  } finally { await runtime.close(); lines.close(); }
}
