// The `graffitty` module: what a mod may ask of Graffitty.
//
// Ported from Herdr's `herdr` module (defaults/herdr.d.ts, Apache-2.0). Live
// data is read synchronously and tracked: a copy re-renders only when a key it
// read changed. `graffitty.d.ts` beside the mods folder documents every call.

// Each read copies the snapshot into JS; read once per render, as Herdr's mods do.
const read = (key) => JSON.parse(__gft_read(String(key)));

/** Named sessions by server, as the Sessions window shows them. Live. */
export const sessions = () => read("sessions");
/** Agents in the graph with their status, pins and connected panes. Live. */
export const agents = () => read("agents");
/** Every pane in this window's tabs. Live. */
export const panes = () => read("panes");
/** The focused pane and tab. Live. */
export const focused = () => read("focused");
/** Resource samples for the focused pane. Live. */
export const resources = () => read("resources");
/** Every pane of every window with its samples, grouped by computer and session. Live. */
export const paneResources = () => read("pane_resources");
/** The named session this window shows: id, name, server. Live. */
export const session = () => read("session");
/** The pane a pane-host copy sits over (`props().pane`): label, CPU, memory, agent. Live. */
export const pane = () => read("pane/" + props().pane);
/** The window's effects profile, the names it can switch to, and the effects switched off. Live. */
export const effects = () => read("effects");
/** The workspace prefix: `active` while armed, the `key` that arms it, `available` when one is configured. Live. */
export const prefix = () => read("prefix");
/** The window: platform, size class, active. Live. */
export const window = () => read("window");
/** Any published key; the ones above are the common names. Live. */
export const live = read;

/** Every theme colour by name: chrome, surface, raised, hover, selected, border,
 *  foreground, muted, dim, accent, working, blocked, done, idle, ansi0..15. */
export const theme = () => JSON.parse(__gft_theme());
/** The user's language for a catalog string; `%s` placeholders are kept. */
export const tr = (text) => __gft_tr(String(text));
/** The props this copy was given when it was opened. */
export const props = () => JSON.parse(__gft_props());
// An element's scroll offsets by its id, and scrolling it to given offsets.
export const scrollOffset = (id) => ({ x: __gft_scroll(String(id), true, null), y: __gft_scroll(String(id), false, null) });
export const scrollTo = (id, offset = {}) => {
  const result = scrollOffset(id);
  if (offset.x != null) result.x = __gft_scroll(String(id), true, Number(offset.x));
  if (offset.y != null) result.y = __gft_scroll(String(id), false, Number(offset.y));
  return result;
};

/** Runs an action: the PascalCase names `[bindings]` and menus use, plus the
 *  mod-facing ones (SelectSession, NewSession, RenameSession, FocusPane, PinAgent, SetEffectsProfile, …). */
export const run = (name, args) => {
  __gft_run(String(name), JSON.stringify(args ?? null));
  return null;
};

/** Reads a value every mod can see (persisted). */
export const shared = (key) => JSON.parse(__gft_shared(String(key)));
/** Sets a shared value; every mod re-renders so it can react. */
export const setShared = (key, value) => {
  __gft_set_shared(String(key), JSON.stringify(value ?? null));
  return null;
};

export const openOverlay = (spec) => __gft_overlay("open", JSON.stringify(spec ?? {}));
export const closeOverlay = (id) => {
  __gft_overlay("close", JSON.stringify(String(id)));
  return null;
};
export const notify = (spec) => __gft_overlay("notify", JSON.stringify(spec ?? {}));

export const home = () => __gft_path("home");
export const appHome = () => __gft_path("app");

const unavailable = (what) => Promise.reject(new Error(what + " is not available to Graffitty mods"));
export const exec = () => unavailable("exec");
export const hc = () => unavailable("hc");
export const readTextFile = () => unavailable("readTextFile");
export const writeTextFile = () => unavailable("writeTextFile");
export const watchFolder = () => unavailable("watchFolder");
export const knownAgents = () => Promise.resolve([]);
export const pickFolder = () => Promise.resolve(null);
/** Key commands addressed to this mod; none are routed yet, so this waits. */
export const nextCommand = () => new Promise(() => {});
export const playSound = () => null;
export const setAgentOrder = () => null;
export const placement = () => null;
export const layout = () => null;
export const layouts = () => [];
export const machines = () => read("machines");
export const terminals = () => read("terminals");
export const keys = () => [];
export const commands = () => [];
export const settings = () => ({});
export const fonts = () => [];
