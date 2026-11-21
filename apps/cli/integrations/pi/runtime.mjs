import { Session, locations, messageText, messagePrompt, program } from "./integration.mjs";

function deliveryIdentity(text) {
  const header = text.split("\n", 1)[0];
  return /^\[Graffitty message from .*; event .*; run .*\]$/.test(header) ? header : undefined;
}

export class PiIntegration {
  constructor(rpc, home, prompt) {
    this.rpc = rpc; this.home = home; this.prompt = prompt;
  }
  async update(snapshot) {
    if (this.session?.id !== snapshot.sessionID) {
      await this.close();
      if (!snapshot.sessionID) throw new Error("Pi has no active session");
      const session = new Session(this.rpc, "pi", snapshot.sessionID, this.home, snapshot.header);
      // A checkpoint reopens this exact session file, with this agent directory's
      // account and settings; a --no-session run has none.
      const restore = snapshot.sessionFile ? { command: [program("pi"), "--session", snapshot.sessionFile],
        cwd: process.cwd(), env: locations(["PI_CODING_AGENT_DIR", "PI_CODING_AGENT_SESSION_DIR"]) } : undefined;
      await session.start({ pid: snapshot.pid, session_file: snapshot.sessionFile, restore });
      this.session = session;
      this.prompts = new Set(); this.pending = new Map(); this.handled = new Set();
      this.lastText = ""; this.outcome = "completed";
    }
    const session = this.session;
    for (const entry of snapshot.entries ?? []) {
      session.record(entry);
      if (entry.message?.role === "user") this.remember(messageText(entry.message));
    }
    for (const event of snapshot.events ?? []) {
      if (event.id && this.handled.has(event.id)) continue;
      if (event.type === "before_agent_start") {
        this.lastText = ""; this.outcome = "completed";
      } else if (event.type === "message_end" && event.message.role === "user") {
        const prompt = messageText(event.message);
        this.remember(prompt);
        this.lastText = ""; this.outcome = "completed";
        await session.event("UserPromptSubmit", { prompt });
      } else if (event.type === "message_end" && event.message.role === "assistant") {
        this.outcome = event.message.stopReason === "error" ? "error"
          : event.message.stopReason === "aborted" ? "interrupted" : "completed";
        this.lastText = this.outcome === "error" ? (event.message.errorMessage || messageText(event.message))
          : messageText(event.message);
      } else if (event.type === "agent_settled") {
        session.status = "idle";
        await session.event("Stop", { text: this.lastText, completion_id: event.id,
          outcome: event.aborted ? "interrupted" : this.outcome });
      }
      if (event.id) this.handled.add(event.id);
    }
    await session.observeStatus(snapshot.waiting ? "waiting" : snapshot.idle ? "idle" : "busy");
    if (snapshot.closing) return;
    const events = await session.take();
    for (const id of this.pending.keys()) if (!events.some(event => event.event_id === id)) this.pending.delete(id);
    for (const event of events) {
      const id = event.event_id;
      const prompt = messagePrompt(event);
      // Permission changes can redact the payload. The event/run header remains
      // stable, so admission still acknowledges exactly the original message.
      if (this.prompts.has(deliveryIdentity(prompt))) {
        await session.ack(id);
        this.pending.delete(id);
        continue;
      }
      if (this.pending.has(id)) {
        if (Date.now() - this.pending.get(id) < 30000 || !snapshot.idle) break;
        await session.progress(id, "failed", "Pi did not admit the message; retrying");
        this.pending.delete(id);
      }
      // Pi cannot cancel a queued individual message. Leave work in Graffitty's
      // revocable inbox until idle; the adapter rechecks immediately at dispatch.
      if (!snapshot.idle || snapshot.waiting || snapshot.pending) break;
      // Like herdr's type_in prepare: check quiet time and current permission
      // immediately before admitting new work. Existing acknowledgements stay live.
      if (!await session.deliveryReady(id)) break;
      const result = await this.prompt({ sessionID: session.id, text: prompt });
      if (result.accepted) {
        this.pending.set(id, Date.now());
        await session.progress(id, "pending", "waiting for Pi to admit the message");
      }
      break;
    }
  }
  remember(text) {
    const id = deliveryIdentity(text);
    if (id) this.prompts.add(id);
  }
  ensureRegistered(reply) { return this.session?.ensureRegistered(reply); }
  async close() {
    if (this.session) { await this.session.close(); this.session = undefined; }
  }
}
