// The element builder the scripts chain on.
//
// Forked from gpui-kit's prelude (crates/shell/src/engine/quickjs/mod.rs,
// Apache-2.0, Longbridge).
//
// One prototype carries every style and behaviour method; a call records an
// operation into the Rust spec arena and returns the same object, so
// `div().flex().gap(6).child("x")` reads like GPUI Rust.
//
// gpui-kit keeps a fast prototype and re-runs a failed render against a Proxy
// to name a mistyped method.
//
// Our mods are a few hundred elements, so the diagnostic prototype is simply
// the prototype: a typo names itself at once.
globalThis.__gft_ui = (() => {
  const methods = {};

  const diagnostic = new Proxy(methods, {
    get(target, name, receiver) {
      const found = Reflect.get(target, name, receiver);
      if (found !== undefined) return found;
      if (typeof name !== "string" || name.startsWith("__") || name === "then") return undefined;
      return () => {
        throw new TypeError(__gft_unknown(name));
      };
    },
  });

  const element = (id) => {
    const object = Object.create(diagnostic);
    object.__id = id;
    return object;
  };

  // Behaviours: the argument shapes vary, so they cross as an array.
  const define = (name) => {
    methods[name] = function (...args) {
      __gft_apply(this.__id, name, args);
      return this;
    };
  };

  // Styles close over their table index: two integers across the boundary
  // instead of a method name that would be looked up again on arrival.
  for (const [name, index] of __gft_nullary_styles()) {
    methods[name] = function () {
      __gft_nullary(this.__id, index);
      return this;
    };
  }
  const params = __gft_param_styles();
  for (let i = 0; i < params.length; i += 1) {
    const index = i;
    methods[params[i]] = function (value) {
      __gft_param(this.__id, index, value);
      return this;
    };
  }
  for (const name of __gft_behaviors()) define(name);

  // A string is an element, as `&str: IntoElement` in GPUI: `.child("hello")`
  // is how text is written, and the style comes from the element holding it.
  const childId = (child) => {
    const id = child?.__id;
    if (id !== undefined) return id;
    const kind = typeof child;
    if (kind === "string" || kind === "number" || kind === "boolean") return __gft_text(String(child));
    throw new TypeError("child(value) expects an element or a string; got " + (child === null ? "null" : kind));
  };
  methods.child = function (child) {
    __gft_attach(this.__id, childId(child));
    return this;
  };
  methods.children = function (list) {
    for (const child of list) __gft_attach(this.__id, childId(child));
    return this;
  };

  // State styles reuse the ordinary style methods on a detached element, so
  // there is no second grammar for "what a style is".
  const state = (name) =>
    function (declare) {
      const target = element(__gft_state(this.__id, name));
      declare(target);
      return this;
    };
  methods.hover = state("hover");
  methods.active = state("active");
  methods.focus = state("focus");

  methods.map = function (transform) {
    return transform(this);
  };
  methods.when = function (condition, branch) {
    if (!condition) return this;
    const produced = branch(this);
    if (produced === undefined || produced === null) throw new Error("when(...) must return the element");
    return produced;
  };

  // Motion that never re-enters the script: the frontend's clock drives it.
  const finiteDuration = (value, name) => {
    if (typeof value !== "number" || !Number.isFinite(value) || value < 0) throw new TypeError(name + " must be a finite non-negative number");
    return value;
  };
  methods.frames = function (list, ms) {
    if (!Array.isArray(list) || list.length === 0 || !list.every((s) => typeof s === "string")) throw new TypeError("frames(list, ms) expects a non-empty array of strings");
    const step = finiteDuration(ms ?? 100, "frames interval");
    if (step < 16) throw new RangeError("frames interval must be at least 16 milliseconds");
    __gft_apply(this.__id, "frames", [step, ...list]);
    return this;
  };
  methods.spin = function (ms) {
    const period = finiteDuration(ms ?? 1000, "spin period");
    if (period < 100) throw new RangeError("spin period must be at least 100 milliseconds");
    __gft_apply(this.__id, "spin", [period]);
    return this;
  };
  methods.mode = function (value) {
    value = String(value);
    if (!["auto", "scrolling", "hover", "always"].includes(value)) throw new TypeError("mode(value) must be auto, scrolling, hover or always; got " + JSON.stringify(value));
    __gft_apply(this.__id, "mode", [value]);
    return this;
  };
  methods.on_mouse_down = function (button, handler) {
    button = String(button);
    if (!["left", "right", "middle"].includes(button)) throw new TypeError("on_mouse_down(button, handler): button must be left, right or middle");
    __gft_apply(this.__id, "on_mouse_down", [button, handler]);
    return this;
  };
  methods.on_mouse_up = function (button, handler) {
    button = String(button);
    if (!["left", "right", "middle"].includes(button)) throw new TypeError("on_mouse_up(button, handler): button must be left, right or middle");
    __gft_apply(this.__id, "on_mouse_up", [button, handler]);
    return this;
  };

  return {
    div: () => element(__gft_div()),
    text: (value) => element(__gft_text(String(value))),
    svg: (path) => element(__gft_svg(String(path))),
    image: (path) => element(__gft_image(String(path))),
  };
})();

// The context a view's `init`, `render` and every handler receive. A copy's
// `cx.notify()` redraws that copy, even when another copy woke it.
globalThis.__gft_cx = (copy) => {
  const cx = {
    notify() {
      __gft_notify(copy);
    },
    stop_propagation() {
      __gft_stop();
    },
    propagate() {},
    spawn(body) {
      const task = Promise.resolve().then(() => body(cx));
      task.catch((error) => __gft_log("error", String(error?.stack ?? error)));
      return {
        detach() {},
        cancel() {},
      };
    },
    timer: {
      every(ms, body) {
        if (typeof ms !== "number" || !Number.isFinite(ms) || ms < 16) throw new TypeError("timer.every(ms, body) needs at least 16 ms");
        if (typeof body !== "function") throw new TypeError("timer.every(ms, body) needs a function");
        return __gft_timer_every(copy, ms, body);
      },
      // Stops a timer `every` returned, as an animation does when it settles.
      cancel(id) {
        __gft_timer_cancel(copy, Number(id) >>> 0);
      },
    },
    focus_handle() {
      return {
        __handle: 0,
        focus() {},
        is_focused() {
          return false;
        },
        release() {},
      };
    },
  };
  return cx;
};

// Per copy, kept as one JSON file by the host.
globalThis.localStorage = {
  getItem: (key) => __gft_storage("get", String(key), null),
  setItem: (key, value) => {
    __gft_storage("set", String(key), String(value));
  },
  removeItem: (key) => {
    __gft_storage("remove", String(key), null);
  },
};

const __gft_join = (args) => args.map((a) => (typeof a === "string" ? a : JSON.stringify(a))).join(" ");
globalThis.console = {
  log: (...args) => __gft_log("info", __gft_join(args)),
  info: (...args) => __gft_log("info", __gft_join(args)),
  warn: (...args) => __gft_log("warn", __gft_join(args)),
  error: (...args) => __gft_log("error", __gft_join(args)),
  debug: (...args) => __gft_log("debug", __gft_join(args)),
};
