import { Binding, Session, hash, locations, messageText, messagePrompt, program } from "./integration.mjs";

// OpenCode keeps its accounts and sessions under XDG_DATA_HOME (or OPENCODE_DB)
// and its configuration under the others.
const LOCATIONS = ["XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_CACHE_HOME",
  "OPENCODE_CONFIG_DIR", "OPENCODE_CONFIG", "OPENCODE_DB"];

export class OpenCodeIntegration {
  constructor(rpc, home, api) {
    this.rpc = rpc; this.home = home; this.api = api;
    this.since = Date.now(); this.pending = new Map();
  }
  async update(snapshot) {
    const sampledAt = Date.now();
    const id = snapshot.sessionID;
    if (this.session && this.session.id !== id) await this.close();
    if (!id) {
      if (!this.homeScreen) {
        if (!(snapshot.pid > 0)) throw new Error("Missing OpenCode TUI process");
        this.homeScreen = { pid: snapshot.pid };
        await this.announceHomeScreen();
      }
      this.since = sampledAt;
      return;
    }
    if (!this.session) {
      await this.close();
      if (!Array.isArray(snapshot.messages)) throw new Error("Missing OpenCode history");
      const session = new Session(this.rpc, "opencode", id, this.home);
      // OpenCode v2 continues the session with --session; a checkpoint reopens it.
      await session.start({ pid: snapshot.pid, restore: { command: [program("opencode"), "--session", id],
        cwd: process.cwd(), env: locations(LOCATIONS) } });
      this.session = session;
      this.binding = new Binding(this.home, id);
      this.handled = new Set();
      this.attachedAt = this.since;
      const baseline = snapshot.messages.findLastIndex(message => message.type === "idle"
        && (message.time?.created === undefined || message.time.created < this.since));
      for (const message of snapshot.messages.slice(0, baseline + 1)) this.handled.add(message.id);
    }
    this.binding.refresh();
    const session = this.session;
    let lastText = "";
    let lastAssistant;
    let settled = false;
    for (const message of snapshot.messages ?? []) {
      session.record(message);
      if (message.type === "user") { lastText = ""; lastAssistant = undefined; settled = false; }
      if (message.type === "assistant") { lastText = messageText(message); lastAssistant = message; settled = false; }
      if (message.type === "idle") settled = true;
      if (this.handled.has(message.id)) continue;
      if (message.type === "user") {
        await session.event("UserPromptSubmit", { prompt: message.text });
        session.status = "busy";
        this.handled.add(message.id);
      } else if (message.type === "idle") {
        // The runner marks a user cancellation with this exact assistant error.
        const interrupted = message.outcome === "interrupted"
          || lastAssistant?.error?.message === "Provider turn interrupted";
        const outcome = interrupted ? "interrupted" : message.outcome === "failed" ? "error" : message.outcome;
        await session.event("Stop", { text: outcome === "error" ? (lastAssistant?.error?.message || lastText) : lastText,
          outcome, completion_id: message.id });
        session.status = "idle";
        this.handled.add(message.id);
      }
    }
    // Current native exports also carry provider failures on assistant records.
    // The runner uses this exact message for cancellation, not a provider error.
    if (!settled && snapshot.status !== "running" && lastAssistant?.error
        && lastAssistant.error.message !== "Provider turn interrupted"
        && !this.handled.has(lastAssistant.id)
        && lastAssistant.time?.created >= this.attachedAt) {
      await session.event("Error", { text: lastAssistant.error.message, outcome: "error",
        completion_id: lastAssistant.id });
      this.handled.add(lastAssistant.id);
    }
    await session.observeStatus(snapshot.waiting ? "waiting" : snapshot.status === "running" ? "busy" : "idle");
    const events = await session.take();
    for (const [event, messageID] of this.pending) {
      if (events.some(item => item.event_id === event)) continue;
      await this.api.cancel({ sessionID: id, messageID });
      this.pending.delete(event);
    }
    for (const event of events) {
      const eventID = event.event_id;
      const messageID = `msg_graffitty_${hash(eventID)}`;
      if (session.records.has(messageID)) {
        await session.ack(eventID);
        this.pending.delete(eventID);
        continue;
      }
      if (this.pending.has(eventID)) continue;
      if (!(snapshot.pending ?? []).some(message => message.id === messageID)) {
        if (!await session.deliveryReady(eventID)) break;
        // Track before the request: a timeout may still have queued the input.
        // Retrying the deterministic ID is safe, and revocation can cancel it.
        this.pending.set(eventID, messageID);
        try { await this.api.prompt({ sessionID: id, messageID, text: messagePrompt(event) }); }
        catch (error) {
          await session.progress(eventID, "failed", `OpenCode queue: ${error.message}`);
          // Cancel an ambiguously admitted request before allowing a retry.
          await this.api.cancel({ sessionID: id, messageID });
          this.pending.delete(eventID);
          continue;
        }
      }
      this.pending.set(eventID, messageID);
      await session.progress(eventID, "pending", "queued in OpenCode");
    }
    this.since = sampledAt;
  }
  announceHomeScreen() {
    return this.rpc("agent.event", { kind: "agent", provider: "opencode", event: "SessionStart",
      transport: "native", integrated: true, pid: this.homeScreen.pid });
  }
  // A restarted server forgets both registrations; the heartbeat reply says so.
  async ensureRegistered(reply) {
    if (this.session) await this.session.ensureRegistered(reply);
    else if (this.homeScreen && reply?.transport !== "native") await this.announceHomeScreen();
  }
  async close() {
    if (this.session) {
      for (const [event, messageID] of this.pending) {
        await this.api.cancel({ sessionID: this.session.id, messageID });
        this.pending.delete(event);
      }
      try { await this.session.close(); }
      finally { this.binding?.close(); this.binding = undefined; this.session = undefined; }
    }
    if (this.homeScreen) {
      await this.rpc("agent.event", { kind: "agent", provider: "opencode", event: "SessionEnd" });
      this.homeScreen = undefined;
    }
  }
}
