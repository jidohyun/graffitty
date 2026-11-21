import { connect } from "node:net";
import { randomUUID } from "node:crypto";
import { chromium as playwrightChromium, type Browser, type BrowserContext, type Page } from "playwright-core";

export interface AttachOptions {
  /** Explicit %N; defaults to GRAFFITTY_CHROMIUM. Never guesses by focus. */
  chromium?: string;
  /** Defaults to the terminal's inherited GRAFFITTY_SOCKET. */
  socket?: string;
  /** Defaults to the terminal's inherited GRAFFITTY_TOKEN. */
  token?: string;
  timeout?: number;
}

export type Side = "left" | "right" | "above" | "below";

export interface LaunchOptions extends Omit<AttachOptions, "chromium"> {
  /** Initial page: http(s) or about:blank (default). */
  url?: string;
  /**
   * Put the new pane beside another pane of this tab. Defaults to "right" of
   * this terminal unless `position`/`size` or `hidden` is given.
   */
  side?: Side;
  /** The pane `side` refers to (%N or :tab.pane); defaults to this terminal. */
  of?: string;
  /** Workspace-pixel position; floating tabs only. */
  position?: { x: number; y: number };
  /** Workspace-pixel size; floating tabs only. */
  size?: { width: number; height: number };
  /** Create it hidden (revealed later by the terminal's Chromium toggle). */
  hidden?: boolean;
  /** Persistent profile directory; mutually exclusive with `profileTemplate`. */
  profile?: string;
  /** Directory copied into a temporary profile. */
  profileTemplate?: string;
}

export interface Launched extends Attachment {
  /** The new pane's handle (%N), usable with `gft chromium ... --target`. */
  handle: string;
  /** Detach, then close the pane this launch created. */
  close(): Promise<void>;
}

export interface Attachment {
  chromium: Browser;
  context: BrowserContext;
  page: Page;
  /** Disconnects automation and releases the lease; keeps the chromium alive. */
  detach(): Promise<void>;
}

interface Lease {
  endpoint: string;
  lease: string;
  target_id: string;
}

/**
 * GRAFFITTY_SOCKET forms, matching the gft CLI: `ipc://PATH` (session server),
 * `tcp://127.0.0.1:PORT` (Windows, loopback only) or a plain Unix socket path.
 */
export function endpoint(socket: string): { path: string } | { host: string; port: number } {
  if (socket.startsWith("ipc://")) return { path: socket.slice("ipc://".length) };
  if (socket.startsWith("tcp://")) {
    const match = /^tcp:\/\/(127\.\d+\.\d+\.\d+|\[::1\]):(\d+)$/.exec(socket);
    const port = Number(match?.[2]);
    if (!match || !Number.isInteger(port) || port < 1 || port > 65535)
      throw new Error("Graffitty TCP endpoint must be loopback tcp://127.0.0.1:PORT");
    return { host: match[1].replace(/^\[|\]$/g, ""), port };
  }
  return { path: socket };
}

function request<T>(socket: string, token: string, method: string,
  params: Record<string, unknown>, timeout: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const id = randomUUID();
    let stream: ReturnType<typeof connect>;
    try {
      stream = connect(endpoint(socket));
    } catch (error) {
      return reject(error);
    }
    let response = "";
    let done = false;
    const finish = (error?: Error, value?: T) => {
      if (done) return;
      done = true;
      stream.destroy();
      error ? reject(error) : resolve(value as T);
    };
    stream.setEncoding("utf8");
    stream.setTimeout(timeout, () => finish(new Error("Graffitty API request timed out")));
    stream.once("error", () => finish(new Error("Cannot connect to the Graffitty host socket")));
    stream.once("end", () => finish(new Error("Graffitty host closed without a response")));
    stream.once("connect", () => {
      stream.write(JSON.stringify({ version: 1, id, token, method, params }) + "\n");
    });
    stream.on("data", (chunk: string) => {
      response += chunk;
      if (response.length > 4 * 1024 * 1024) return finish(new Error("Graffitty response exceeds limit"));
      const newline = response.indexOf("\n");
      if (newline < 0) return;
      try {
        const value = JSON.parse(response.slice(0, newline));
        if (value.id !== id || value.version !== 1) throw new Error("Invalid Graffitty response");
        if (value.error) return finish(new Error(`Graffitty ${value.error.code}: ${value.error.message}`));
        finish(undefined, value.result);
      } catch {
        finish(new Error("Invalid Graffitty API response"));
      }
    });
  });
}

function connection(options: Omit<AttachOptions, "chromium">) {
  const socket = options.socket ?? process.env.GRAFFITTY_SOCKET;
  const token = options.token ?? process.env.GRAFFITTY_TOKEN;
  const timeout = options.timeout ?? 20_000;
  if (!socket || !token)
    throw new Error("Run inside Graffitty or supply its socket and workspace token");
  if (!Number.isFinite(timeout) || timeout <= 0)
    throw new Error("timeout must be a positive number of milliseconds");
  return { socket, token, timeout };
}

const SIDES: readonly Side[] = ["left", "right", "above", "below"];

/** Validated `pane.place` parameters, or undefined to leave the pane hidden. */
export function placement(options: LaunchOptions): Record<string, unknown> | undefined {
  const absolute = options.position !== undefined || options.size !== undefined;
  if (options.hidden) {
    if (options.side || options.of || absolute) throw new Error("hidden cannot be combined with a placement");
    return undefined;
  }
  if (options.side && absolute) throw new Error("Use side/of or position/size, not both");
  if (options.of && !options.side) throw new Error("of requires side");
  const params: Record<string, unknown> = {};
  if (options.side || !absolute) {
    const side = options.side ?? "right";
    if (!SIDES.includes(side)) throw new Error(`side must be one of ${SIDES.join(", ")}`);
    params.side = side;
    if (options.of) params.of = options.of;
  }
  const finite = (...values: number[]) => values.every(Number.isFinite);
  if (options.position) {
    if (!finite(options.position.x, options.position.y)) throw new Error("position must be finite numbers");
    params.x = options.position.x;
    params.y = options.position.y;
  }
  if (options.size) {
    const { width, height } = options.size;
    if (!finite(width, height) || width < 40 || height < 40) throw new Error("size must be at least 40 by 40");
    params.width = width;
    params.height = height;
  }
  return params;
}

const sleep = (ms: number) => new Promise(resolve => setTimeout(resolve, ms));

/**
 * Create a Graffitty chromium pane in this terminal's tab, place it, and
 * attach Playwright to its page. `close()` removes the pane again.
 */
export async function launch(options: LaunchOptions = {}): Promise<Launched> {
  const { socket, token, timeout } = connection(options);
  const place = placement(options);
  if (options.profile !== undefined && options.profileTemplate !== undefined)
    throw new Error("Use either profile or profileTemplate");
  const create: Record<string, unknown> = { url: options.url ?? "about:blank" };
  if (options.profile !== undefined) create.profile = options.profile;
  if (options.profileTemplate !== undefined) create.profile_template = options.profileTemplate;
  const created = await request<{ chromium: string }>(socket, token, "chromium.create", create, timeout);
  const handle = created.chromium;
  const remove = () => request(socket, token, "chromium.close", { chromium: handle }, Math.min(timeout, 5000));
  try {
    if (place) await request(socket, token, "pane.place", { target: handle, ...place }, timeout);
    // A new browser may need a moment before its page accepts an attachment.
    const deadline = Date.now() + timeout;
    let attached: Attachment | undefined;
    while (!attached) {
      try {
        attached = await attach({ chromium: handle, socket, token, timeout: Math.max(1, deadline - Date.now()) });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        if (!/not ready/i.test(message) || Date.now() + 250 >= deadline) throw error;
        await sleep(250);
      }
    }
    const session = attached;
    let closed = false;
    return {
      ...session,
      handle,
      async close() {
        if (closed) return;
        closed = true;
        try {
          await session.detach();
        } finally {
          await remove();
        }
      },
    };
  } catch (error) {
    await remove().catch(() => {});
    throw error;
  }
}

/** Borrow the primary page of an existing Graffitty chromium. Never launches one. */
export async function attach(options: AttachOptions = {}): Promise<Attachment> {
  const chromiumRef = options.chromium ?? process.env.GRAFFITTY_CHROMIUM;
  if (!chromiumRef || !/^%(0|[1-9]\d*)$/.test(chromiumRef))
    throw new Error("Set chromium: '%N' or GRAFFITTY_CHROMIUM to the existing chromium ID");
  const { socket, token, timeout } = connection(options);
  const params = { chromium: chromiumRef };
  const lease = await request<Lease>(socket, token, "chromium.attach", params, timeout);
  let chromium: Browser | undefined;
  const release = async () => {
    await request(socket, token, "chromium.detach", { ...params, lease: lease.lease }, Math.min(timeout, 5000));
  };
  try {
    // noDefaults preserves the user's existing context preferences. Chromium
    // remains owned by Graffitty; closing this CDP connection just detaches.
    chromium = await playwrightChromium.connectOverCDP(lease.endpoint, { timeout, noDefaults: true });
    let selected: Page | undefined;
    for (const context of chromium.contexts()) {
      for (const page of context.pages()) {
        const session = await context.newCDPSession(page);
        try {
          const { targetInfo } = await session.send("Target.getTargetInfo");
          if (targetInfo.targetId === lease.target_id) selected = page;
        } finally {
          await session.detach();
        }
      }
    }
    if (!selected) throw new Error("The Graffitty primary page is no longer available");
    let detached = false;
    const attachedChromium = chromium;
    return {
      chromium, context: selected.context(), page: selected,
      async detach() {
        if (detached) return;
        detached = true;
        try {
          await attachedChromium.close();
        } finally {
          // Closing the socket also releases the host lease. Explicit release
          // covers connections that ended before the host observed disconnect.
          await release().catch(() => {});
        }
      },
    };
  } catch (error) {
    await chromium?.close().catch(() => {});
    await release().catch(() => {});
    // Playwright includes the WebSocket URL in connection errors. It contains
    // a bearer lease: never surface it in test reporters or application logs.
    const message = error instanceof Error ? error.message : String(error);
    throw new Error(message.split(lease.endpoint).join("[Graffitty attachment]")
      .split(lease.lease).join("[redacted]"));
  }
}
