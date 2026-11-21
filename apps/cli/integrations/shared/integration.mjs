// Graffitty's native plugins run inside their agent. No child process or server.
import { connect } from "node:net";
import { createHash, randomUUID } from "node:crypto";
import { accessSync, appendFileSync, constants, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { delimiter, dirname, isAbsolute, join } from "node:path";

const MAX_REQUEST = 4 * 1024 * 1024;
const MAX_RESPONSE = MAX_REQUEST + 68 * 1024;
export const methods = ["graph.adjacent", "graph.list", "graph.inbox", "graph.read", "graph.send"];
export const hash = (text) => createHash("sha256").update(text).digest("hex");
export const newId = randomUUID;

export function client(socket = process.env.GRAFFITTY_SOCKET, token = process.env.GRAFFITTY_TOKEN) {
  if (!socket || !token) throw new Error("No Graffitty pane capability");
  let address = { path: socket.replace(/^ipc:\/\//, "") };
  if (socket.startsWith("tcp://")) {
    const url = new URL(socket);
    const host = url.hostname.replace(/^\[|\]$/g, "");
    if (!/^127(?:\.\d{1,3}){3}$/.test(host) && host !== "::1") throw new Error("Graph TCP endpoint must be loopback");
    address = { host, port: Number(url.port) };
  }
  const rpc = (method, params = {}, signal) => new Promise((resolve, reject) => {
    const id = randomUUID();
    const request = JSON.stringify({ id, version: 1, token, method, params });
    if (Buffer.byteLength(request) > MAX_REQUEST) return reject(new Error("Graph request too large"));
    if (signal?.aborted) return reject(new Error("Graph request aborted"));
    const stream = connect(address);
    let chunks = [], size = 0, settled = false;
    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      stream.destroy();
      error ? reject(error) : resolve(value);
    };
    const abort = () => finish(new Error("Graph request aborted"));
    const timer = setTimeout(() => finish(new Error("Graffitty server timed out")), 3000);
    signal?.addEventListener("abort", abort, { once: true });
    stream.on("error", error => finish(error));
    stream.on("end", () => finish(new Error("Graffitty server closed the connection")));
    stream.on("connect", () => stream.write(request + "\n"));
    stream.on("data", chunk => {
      size += chunk.length;
      if (size > MAX_RESPONSE) return finish(new Error("Graph response too large"));
      chunks.push(chunk);
      if (!chunk.includes(10)) return;
      try {
        const reply = JSON.parse(Buffer.concat(chunks).toString("utf8").split("\n", 1)[0]);
        if (reply.id !== id) throw new Error("Graph response ID mismatch");
        if (reply.error) throw new Error(reply.error.message || "Graph request failed");
        finish(null, reply.result);
      } catch (error) { finish(error); }
    });
  });
  rpc.watch = handlers => subscribe(address, token, handlers);
  return rpc;
}

// The persistent channel carries invalidations only. Inbox reads still pass
// through the ordinary recipient-filtered API at delivery time.
function subscribe(address, token, { changed, ready, failed }) {
  const id = randomUUID();
  const stream = connect(address);
  let buffer = Buffer.alloc(0), acknowledged = false, closed = false;
  const fail = error => {
    if (closed) return;
    closed = true; stream.destroy(); failed(error);
  };
  stream.setTimeout(acknowledged ? 15000 : 3000);
  stream.on("timeout", () => fail(new Error("Graffitty subscription timed out")));
  stream.on("error", fail);
  stream.on("end", () => fail(new Error("Graffitty server closed the connection")));
  stream.on("connect", () => stream.write(JSON.stringify({ id, version: 1, token,
    method: "graph.watch", params: {} }) + "\n"));
  stream.on("data", chunk => {
    buffer = Buffer.concat([buffer, chunk]);
    if (buffer.length > MAX_RESPONSE) return fail(new Error("Graph response too large"));
    try {
      let end;
      while (!closed && (end = buffer.indexOf(10)) >= 0) {
        const value = JSON.parse(buffer.subarray(0, end).toString("utf8"));
        buffer = buffer.subarray(end + 1);
        if (value.version !== 1) throw new Error("Unsupported graph subscription version");
        if (!acknowledged) {
          if (value.id !== id) throw new Error("Graph response ID mismatch");
          if (value.error) throw new Error(value.error.message || "Subscription failed");
          if (value.result?.watching !== true) throw new Error("Invalid graph subscription response");
          acknowledged = true; stream.setTimeout(15000); ready();
        } else {
          if (!value.params || typeof value.params !== "object" || Array.isArray(value.params))
            throw new Error("Invalid graph notification params");
          if (value.method === "graph.changed") changed();
          else if (value.method !== "graph.keepalive") throw new Error("Invalid graph notification");
        }
      }
    } catch (error) { fail(error); }
  });
  return { close() { closed = true; stream.destroy(); } };
}

export async function tool(rpc, input, signal) {
  if (!methods.includes(input.method)) throw new Error("Unsupported graph tool method");
  return JSON.stringify(await rpc(input.method, input.params ?? {}, signal));
}

export async function graphContext(rpc, guide, provider) {
  const routing = provider === "opencode"
    ? "For OpenCode use the graffitty tool with method and params instead of shell gft commands: this binds calls to this session even with a shared server."
    : "Use the graffitty tool with method and params, or shell gft commands.";
  return `${guide}\n${routing} Current graph (replaces previous snapshots): ${JSON.stringify(await rpc("graph.adjacent"))}`;
}

export function privateFile(path, data) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporary, data, { flag: "wx", mode: 0o600 });
    renameSync(temporary, path);
  } finally { rmSync(temporary, { force: true }); }
}

export const messageText = message => typeof message?.content === "string" ? message.content
  : (message?.content ?? []).filter(part => part.type === "text").map(part => part.text).join("\n");
export const messagePrompt = event => `[Graffitty message from ${event.source ?? ""}; event ${event.event_id ?? ""}; run ${event.run_id ?? ""}]\n${event.text ?? ""}\nPayload (JSON): ${JSON.stringify(event)}`;

// A checkpoint relaunches the agent in this process's own locations, so an
// alias that chose another account still reopens it; null removes one this
// process did not have from the restoring shell.
export const locations = names => Object.fromEntries(names.map(name => [name, process.env[name] ?? null]));

// A checkpoint relaunches the agent this process found on its PATH, which
// survives package upgrades; otherwise the restored shell looks it up.
export function program(name) {
  for (const dir of (process.env.PATH ?? "").split(delimiter)) {
    if (!isAbsolute(dir)) continue;
    const candidate = join(dir, name);
    try {
      accessSync(candidate, constants.X_OK);
      if (statSync(candidate).isFile()) return candidate;
    } catch {}
  }
  return name;
}

export class Session {
  constructor(rpc, provider, id, home, header) {
    this.rpc = rpc;
    this.provider = provider;
    this.id = id;
    this.records = new Map();
    this.path = join(home, ".graffitty/transcripts", `${randomUUID()}.jsonl`);
    privateFile(this.path, header ? JSON.stringify(header) + "\n" : "");
    this.home = home;
    this.status = "idle";
  }
  async start(fields) {
    this.started = fields;
    await this.announce();
  }
  // SessionStart is a registration the server holds in memory.
  //
  // A restarted server rediscovers this pane as a plain process until it
  // hears it again, so re-announce whenever a reply shows the registration is
  // gone, then restore the status SessionStart reset to idle.
  announce() {
    this.announcing ??= (async () => {
      await this.rpc("agent.event", { kind: "agent", provider: this.provider, session_id: this.id,
        event: "SessionStart", transport: "inbox", integrated: true,
        transcript_path: this.path, provider_home: this.home, ...this.started });
      if (this.status !== "idle") await this.rpc("agent.event", { kind: "agent", provider: this.provider,
        session_id: this.id, event: STATUS_EVENTS[this.status] });
    })().finally(() => { this.announcing = undefined; });
    return this.announcing;
  }
  async ensureRegistered(reply) {
    if (this.started && !this.closed && reply?.transport !== "inbox") await this.announce();
  }
  async event(event, fields = {}) {
    const reply = await this.rpc("agent.event", { kind: "agent", provider: this.provider, session_id: this.id, event, ...fields });
    if (event !== "SessionEnd") await this.ensureRegistered(reply);
    return reply;
  }
  record(entry) {
    if (!entry.id) throw new Error(`${this.provider} record has no ID`);
    const text = JSON.stringify(entry);
    if (this.records.get(entry.id) === text) return;
    appendFileSync(this.path, text + "\n");
    this.records.set(entry.id, text);
  }
  async observeStatus(status) {
    if (status === this.status) return;
    // Record the intent first so a re-announcement during the call restores it.
    const previous = this.status;
    this.status = status;
    try { await this.event(STATUS_EVENTS[status]); }
    catch (error) { this.status = previous; throw error; }
  }
  async take() {
    const result = await this.rpc("graph.take");
    if (!Array.isArray(result?.events)) throw new Error("Invalid host inbox response");
    return result.events;
  }
  async deliveryReady(event_id) {
    const result = await this.rpc("agent.delivery", { event_id });
    if (typeof result?.ready !== "boolean") throw new Error("Invalid delivery readiness response");
    return result.ready;
  }
  ack(event_id) { return this.rpc("graph.ack", { event_id, status: "delivered" }); }
  progress(event_id, status, message) { return this.rpc("graph.progress", { event_id, status, message, details: {} }); }
  close() { this.closed = true; return this.event("SessionEnd"); }
}
const STATUS_EVENTS = { waiting: "AwaitingInput", busy: "PreToolUse", idle: "Ready" };

// A shared OpenCode server must resolve the actual session's frontend, never its
// own inherited environment. Private expiring leases are data, not processes.
export class Binding {
  constructor(home, id) {
    this.path = join(home, ".graffitty/bindings", hash(id), `${process.pid}-${randomUUID()}.json`);
  }
  refresh() {
    privateFile(this.path, JSON.stringify({ updated: Date.now() / 1000,
      socket: process.env.GRAFFITTY_SOCKET, token: process.env.GRAFFITTY_TOKEN }));
  }
  close() { rmSync(this.path, { force: true }); }
}
export function boundClient(home, id) {
  if (!id) return;
  const dir = join(home, ".graffitty/bindings", hash(id));
  let files;
  try { files = readdirSync(dir); } catch (error) { if (error.code === "ENOENT") return; throw error; }
  const live = [];
  for (const file of files.filter(name => name.endsWith(".json"))) {
    let lease;
    try { lease = JSON.parse(readFileSync(join(dir, file), "utf8")); } catch { continue; }
    if (Date.now() / 1000 - lease.updated < 15 && lease.updated <= Date.now() / 1000 + 1) live.push(lease);
  }
  if (live.length > 1) throw new Error("OpenCode session is open in multiple Graffitty panes; close the duplicate before using graph tools");
  if (live.length) return client(live[0].socket, live[0].token);
}

// Serialized, coalesced event work. Idle has no inbox/status polling. The only
// periodic work renews liveness/leases; delivery deadlines are one-shot timers.
export function observe(rpc, update, { failed, recovered, keepalive = () => {}, heartbeat: onHeartbeat = () => {}, wakeAt = () => null }) {
  let stopped = false, connected = false, dirty = true, outage = false, attempts = 0;
  let channel, retry, deadline, task, heartbeatTask;
  let initial;
  const ready = new Promise(resolve => { initial = resolve; });
  const fail = error => {
    if (stopped) return;
    connected = false; channel?.close(); clearTimeout(deadline);
    if (!outage) failed(error);
    outage = true; initial();
    if (!retry) {
      const wait = Math.min(10000, 250 * 2 ** Math.min(attempts++, 6));
      retry = setTimeout(() => { retry = undefined; open(); }, wait);
      retry.unref?.();
    }
  };
  const drain = () => {
    if (stopped || !connected || task) return;
    task = (async () => {
      while (dirty && connected && !stopped) {
        dirty = false;
        await update();
        if (outage && !stopped && connected) { await recovered(); outage = false; }
        attempts = 0;
      }
    })().catch(fail).finally(() => {
      task = undefined; initial(); clearTimeout(deadline);
      if (dirty && connected && !stopped) drain();
      else if (connected && !stopped) {
        const at = wakeAt();
        if (at !== null && Number.isFinite(at)) {
          deadline = setTimeout(changed, Math.max(1, at - Date.now())); deadline.unref?.();
        }
      }
    });
  };
  const changed = () => { dirty = true; drain(); };
  const open = () => {
    if (stopped) return;
    channel = rpc.watch({ changed, failed: fail, ready() { connected = true; changed(); } });
  };
  const heartbeat = setInterval(() => {
    if (!connected || stopped || heartbeatTask) return;
    heartbeatTask = Promise.resolve().then(keepalive).then(() => rpc("agent.heartbeat")).then(onHeartbeat)
      .catch(fail).finally(() => { heartbeatTask = undefined; });
  }, 5000);
  heartbeat.unref?.();
  open();
  return { ready, changed, async stop() {
    stopped = true; connected = false; channel?.close();
    clearInterval(heartbeat); clearTimeout(retry); clearTimeout(deadline);
    await Promise.all([task, heartbeatTask]); initial();
  } };
}
