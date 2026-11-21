// The `graffitty` module: what a mod may ask of Graffitty.
// Written by Graffitty next to your mods; do not edit.
//
// Live functions are tracked: a mod re-renders when a key it read changes.
// Read each once per render and keep the result, rather than calling in a loop.

export type AgentStatus = "working" | "blocked" | "done" | "idle";

export interface SessionInfo {
  /** `$name` as the server knows it. */
  id: string;
  /** The display name, or the id without `$` when nobody named it. */
  name: string;
  /** The session a window is showing now: one per window, even when that
   *  window is connected to several servers. */
  viewing: boolean;
}

export interface ServerInfo {
  /** The connection URL; `shared://local` for this computer. */
  id: string;
  name: string;
  local: boolean;
  connected: boolean;
  /** `macos`, `windows`, `linux` or "". */
  platform: string;
  /** Saved in the client's connections, so it can be reordered. */
  saved: boolean;
  sessions: SessionInfo[];
}

/** Servers and their named sessions, in the saved order. Live. */
export function sessions(): ServerInfo[];

export interface AgentRow {
  id: string;
  /** `%N` in its window. */
  key: string;
  title: string;
  provider: string;
  status: AgentStatus;
  /** "Pinned", "Needs you", "Done", "Working", "Idle". */
  section: string;
  pinned: boolean;
  focused: boolean;
  /** Unix seconds when its status last changed. */
  at: number;
  /** The server name for a remote agent, "" here. */
  remote: string;
  /** Its session's label. */
  session: string;
  /** Panes connected to it, each with its tree lines (`│`, `├`, `└`). */
  subs: AgentSub[];
}

export interface AgentSub {
  key: string;
  kind: "agent" | "terminal" | "chromium" | "filetree";
  title: string;
  status: AgentStatus | "offline" | "";
  icon: string;
  lines: string[];
  host_id: number;
}

/** Agents by priority, the way the Agents window lists them. Live. */
export function agents(): AgentRow[];

export interface PaneInfo {
  key: string;
  kind: "terminal" | "chromium";
  title: string;
  focused: boolean;
}

/** Every pane in this window's tabs. Live. */
export function panes(): PaneInfo[];

/** The focused pane (`%N`) and tab. Live. */
export function focused(): { pane: string; tab: number } | null;

export interface ResourceMetric {
  /** `cpu`, `memory`, `peak` or `processes`. */
  id: string;
  /** An icon file in the mod asset roots. */
  icon: string;
  value: string;
  /** What the value measures, translated; the processes row also names the root PID. */
  tooltip: string;
}

export interface ResourceSample {
  pane: string;
  /** `terminal` or `chromium`. */
  kind: string;
  /** `Pane %N` or `Chromium N`, translated. */
  label: string;
  /** The monitor's state: `running`, `starting`, `paused`, `disabled` or `unavailable`. */
  status: string;
  status_label: string;
  /** Why nothing is measured, when it is not; otherwise empty. */
  message: string;
  /** Compact CPU and memory for a rail or band. */
  cpu: string;
  memory: string;
  /** One icon row per reading; empty while the monitor is not measuring. */
  metrics: ResourceMetric[];
  /** The whole readout as text, for a compact view's tooltip. */
  tooltip: string;
  /** Empty for a plain shell. */
  agent: {
    provider: string; status: string; name: string; label: string; since: number;
    session_id: string; session: string; queued: number; queued_label: string; detail: string;
  } | Record<string, never>;
}

/** Resource samples for the focused pane, as the Pane Status window shows them. Live. */
export function resources(): ResourceSample | null;

export interface PaneResourceRow {
  /** The same for every window that shows this pane. */
  id: string;
  /** The window that shows it: pass with `key` to `FocusPane`. */
  host: number;
  /** `%N` in that window. */
  key: string;
  /** A provider name, `terminal`, `python`, `chromium` or `filetree`. */
  icon: string;
  title: string;
  focused: boolean;
  /** `running`, `starting`, `paused`, `disabled`, `exited` or `unavailable`. */
  status: string;
  /** Percent as the server scales it; null until measured, never a stand-in zero. */
  cpu: number | null;
  /** Bytes, in the backend's memory measure; null when unknown. */
  memory: number | null;
  processes: number | null;
  /** The pane's root process: its shell, or the Chromium host. */
  pid: number | null;
}

export interface PaneResourceGroup {
  /** The computer's name; "" for this computer. */
  server: string;
  local: boolean;
  /** The session's label. */
  session: string;
  rows: PaneResourceRow[];
}

/** Every pane of every window with its samples, grouped by computer and session, as the Resource Monitor lists them. Live. */
export function paneResources(): PaneResourceGroup[];

/** What the pane strip shows for one pane; the host publishes it per pane. */
export interface PaneStatus {
  /** The pane key, `%N`. */
  pane: string;
  /** `.1 (%N)` with the pane's position in its tab, or `%N`. */
  label: string;
  /** `37%`, `128M`, `1.2G`, or `—` when there is no live sample. */
  cpu: string;
  memory: string;
  agent: {
    provider: string;
    /** The provider's logo file, the node's own inline SVG source, or null when `name` is shown instead. */
    logo: string | null;
    /** The name to show when there is no logo. */
    name: string;
    /** A node icon's text glyph, or "". */
    symbol: string;
    status: string;
    /** The status in the user's language. */
    status_label: string;
    /** The status glyph file and its colour. */
    icon: string;
    tint: string;
    spinning: boolean;
    /** When the current status began, Unix seconds, or null. */
    since: number | null;
    /** The hover text: identity, status and the server's recent status changes. */
    tooltip: string;
  } | null;
}

/** The pane a pane-host copy sits over (`props().pane`). Live. */
export function pane(): PaneStatus | null;

/**
 * Describe browser video transport for a remote connection.
 * Local sessions return an empty value.
 *
 * `transport` is `"datagram"` (UDP alongside the WebSocket) or
 * `"websocket"`. For WebSocket video, `reason` gives the cause:
 *
 * - `"unoffered"` — the server did not offer UDP video.
 * - `"unavailable"` — the device has no UDP socket.
 * - `"no_reply"` — UDP to `address` got no answer.
 * - `"stopped"` — replies stopped.
 *
 * `streaming` is true while browser panes are subscribed.
 */
export interface VideoTransport {
  transport?: "datagram" | "websocket";
  reason?: "unoffered" | "unavailable" | "no_reply" | "stopped";
  streaming?: boolean;
  address?: string;
  round_trip_ms?: number;
  frames?: number;
  /** Frames rebuilt from parity (forward error correction). */
  recovered?: number;
  nacked?: number;
  abandoned?: number;
}

/** The named session this window shows. `name` is "" when nobody named it. Live. */
export function session(): { id: string; name: string; platform: string; server: string; local: boolean; connected: boolean; video: VideoTransport } | null;

/**
 * The window's effects profile, the names it can switch to, and the effects the
 * user switched off with `ToggleEffect` (names from graffitty/effects.gd, such as
 * `camera.zoom`, `camera.tilt`, `pane_zoom`). Live.
 */
export function effects(): { profile: string; profiles: { name: string; label: string }[]; disabled: string[] } | null;
/**
 * Read live state for the workspace's tmux-style prefix key.
 *
 * - `active` means the next key is interpreted as a prefix command.
 * - `key` is the platform's label for the prefix key.
 * - `available` means a prefix key is configured.
 *
 * `TogglePrefix` arms or cancels the prefix.
 */
export function prefix(): { active: boolean; available: boolean; key: string } | null;

/** The window: platform, whether touch controls are on, size. Live. */
export function window(): { platform: "macos" | "windows" | "linux" | "android"; touch: boolean; active: boolean } | null;

/** Any published key. */
export function live(key: string): unknown;

/** Every theme colour by name, as `#rrggbb`. */
export function theme(): Record<string, string>;

/** The user's language for a string in Graffitty's catalog; unknown strings come back unchanged. */
export function tr(text: string): string;

/** The props this copy was opened with. */
export function props(): any;
/** Scroll offsets of the element with this `.id()`: `x` for `overflow_x_scroll`, `y` for `overflow_y_scroll`. */
export function scrollOffset(id: string): { x: number; y: number };
/** Scrolls the element with this `.id()` to the given offsets, clamped to its content; returns the new offsets. */
export function scrollTo(id: string, offset: { x?: number; y?: number }): { x: number; y: number };

/**
 * Run an action by name and pass its arguments as an object.
 *
 * This accepts the PascalCase names used in bindings and menus, including
 * `Agents`, `AllSessions`, `PaneStatus`, and `ResourceMonitor`.
 * `SetEffectsProfile` takes `profile`. `ToggleEffect` takes `effect`.
 *
 * Mod actions and their arguments:
 *
 * - `SelectSession`, `SessionContextMenu`, and `RenameSession`: `server`, `session`.
 * - `NewSession` and `ConnectServer`: `server`.
 * - `OpenServers`: no arguments.
 * - `FocusPane`: `key` and optional `host`.
 * - `FocusAgent`: `id`.
 * - `PinAgent`: `id`, `pinned`.
 * - `MoveServer`: `server`, `index`.
 */
export function run(name: string, args?: Record<string, unknown>): null;

/** Reads a value every mod can see (persisted). */
export function shared(key: string): unknown;
/** Sets a shared value; every mod re-renders so it can react. */
export function setShared(key: string, value: unknown): null;

export function openOverlay(spec: { mod: string; props?: Record<string, unknown>; kind?: "dialog" | "popup" | "window"; width?: number; height?: number }): string;
export function closeOverlay(id: string): null;
export function notify(spec: { title: string; body?: string; level?: "info" | "success" | "warning" | "error" }): string;

export function home(): string;
export function appHome(): string;

/** Not available: Graffitty mods draw mods and run actions; they do not run programs. */
export function exec(command: string, args?: string[], options?: Record<string, unknown>): Promise<never>;
export function hc(args: string[]): Promise<never>;
export function readTextFile(path: string): Promise<never>;
export function writeTextFile(path: string, text: string, expected: string | null): Promise<never>;
export function watchFolder(path: string): Promise<never>;
export function nextCommand(): Promise<string>;
