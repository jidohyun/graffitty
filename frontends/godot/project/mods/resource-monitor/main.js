// Show resource samples for every pane in every window. Each row shows
// the program icon, pane title, and samples. A caption groups consecutive
// rows from the same server and session. Totals stay at the bottom.
//
// - Drag a column's right edge to resize it.
// - Drag the header to reorder columns. On touch, hold it before dragging.
// - Click a header to sort. Click again to reverse, or a third time to reset.
// - Use the Server and Session header funnels to filter by multiple values.
// - Scroll wide tables sideways with a trackpad, Shift+wheel, or touch.
//
// The host publishes `pane_resources`, grouped and validated in Rust.
// This view shares sorting, filters, and column layout across its copies.

import { View, div, svg, image, v_flex, h_flex } from "graffitty-ui";
import { paneResources, run, theme, props, shared, setShared, scrollOffset, scrollTo, tr } from "graffitty";

const ICONS = {
  claude: "claude-code.svg", pi: "pi.svg", codex: "codex.png", opencode: "opencode.svg",
  python: "python.svg", chromium: "chromium.svg", filetree: "folder-tree.svg",
};
// `first`: the direction the first click sorts; numbers start with the largest.
const COLUMNS = {
  title: { label: "Title", width: 180, min: 80, first: "asc" },
  // `%N`, as `gft` targets it; sorted by its number.
  pane: { label: "Pane", width: 52, min: 36, first: "asc", right: true },
  cpu: { label: "CPU", width: 60, min: 40, first: "desc", right: true },
  memory: { label: "RAM", width: 68, min: 44, first: "desc", right: true },
  // Intentional in every locale: the compact count header is always #procs.
  processes: { label: "#procs", tooltip: "Processes", width: 52, min: 36, first: "desc", right: true },
  pid: { label: "PID", width: 64, min: 40, first: "asc", right: true },
  server: { label: "Server", width: 120, min: 64, first: "asc", filter: "All servers" },
  session: { label: "Session", width: 100, min: 64, first: "asc", filter: "All sessions" },
};
const STORE = "resource-monitor.table";
const PAD = 4; // the table's left inset, where column 0 begins
const HEADER = 24;
const HANDLE = 6;
const DRAG = 4; // pixels before a header press becomes a reorder
const FRAME = 16; // animation step, ms
const EASE = 0.35; // share of the remaining distance a column moves per step

function icon(name, size) {
  const file = ICONS[name] ?? "square-terminal.svg";
  return file.endsWith(".png") || name === "pi" ? image(file).size(size).flex_none() : svg(file).size(size).flex_none().text_color("#ffffff");
}

const cpuText = (v) => (v == null ? "—" : `${v.toFixed(v < 10 ? 1 : 0)}%`);
function memoryText(bytes) {
  if (bytes == null) return "—";
  const mib = bytes / 1048576;
  return mib >= 1024 ? `${(mib / 1024).toFixed(1)}G` : `${mib.toFixed(0)}M`;
}
// Element ids: a row id carries its server URL, and `/` separates child keys.
const slug = (id) => String(id).replace(/[^A-Za-z0-9_%-]/g, "_");
const countText = (v) => (v == null ? "—" : String(v));

// Unknown values sort after every known one, in either direction.
function compare(a, b, column, dir) {
  const x = a[column], y = b[column];
  if (x == null || x === "") return y == null || y === "" ? 0 : 1;
  if (y == null || y === "") return -1;
  // QuickJS compares code units and ignores collation options; fold case first.
  const [p, q] = [String(x).toLowerCase(), String(y).toLowerCase()];
  const order = typeof x === "number" ? x - y : p < q ? -1 : p > q ? 1 : 0;
  return dir === "desc" ? -order : order;
}

// A filter is null (everything, including values that appear later) or the chosen values.
const passes = (filter, value) => filter == null || filter.includes(value);
const filterOf = (value) => (Array.isArray(value) ? value.map(String) : null);

export default class ResourceMonitor extends View {
  init() {
    this.panel = 0; // Panel width. The title column takes the remaining space.
    this.press = null; // {column, x, grab, moved, drop, at}
    this.resize = null; // {column, x, width}
    this.menu = null; // the column whose filter list is open
    this.shown = {}; // Current x position of each sliding column, in content coordinates.
    this.timer = null;
    this.folded = new Set();
    this.load();
  }

  // Shared, not localStorage: a copy's store follows its props (window, dock
  // side), and the column layout is the user's in every window.
  //
  // Reading it in render also re-renders the other windows' copies when it
  // changes.
  load() {
    const saved = shared(STORE) ?? {};
    const known = Object.keys(COLUMNS);
    const order = Array.isArray(saved.order) ? saved.order.filter((c) => known.includes(c)) : [];
    this.order = [...order, ...known.filter((c) => !order.includes(c))];
    this.widths = {};
    for (const c of known) this.widths[c] = Math.max(COLUMNS[c].min, Number(saved.widths?.[c]) || COLUMNS[c].width);
    this.sort = saved.sort && COLUMNS[saved.sort.column] ? saved.sort : null;
    this.filters = { server: filterOf(saved.filters?.server), session: filterOf(saved.filters?.session) };
  }

  save() {
    setShared(STORE, { order: this.order, widths: this.widths, sort: this.sort, filters: this.filters });
  }

  // Title takes the room the other columns leave, never less than its own width.
  widthOf(column) {
    if (column !== "title") return this.widths[column];
    const others = this.order.reduce((sum, c) => (c === "title" ? sum : sum + this.widths[c]), 0);
    return Math.max(this.widths.title, this.panel - 2 * PAD - others);
  }

  // Every column side by side, which may be wider than the panel.
  contentWidth() {
    return this.order.reduce((sum, c) => sum + this.widthOf(c), 2 * PAD);
  }

  maxScroll() {
    return Math.max(0, this.contentWidth() - this.panel);
  }

  // The order drawn now: mid-drag, the dragged column sits where it would land.
  drawnOrder() {
    const p = this.press;
    if (!p?.moved || p.drop == null) return this.order;
    const rest = this.order.filter((c) => c !== p.column);
    rest.splice(p.drop, 0, p.column);
    return rest;
  }

  // Where each column's slot begins in content coordinates (before scrolling).
  slots(order = this.drawnOrder()) {
    const result = {};
    let x = PAD;
    for (const c of order) {
      result[c] = x;
      x += this.widthOf(c);
    }
    return result;
  }

  // The dragged column, in content coordinates, held under the pointer.
  dragX() {
    const p = this.press;
    const max = this.contentWidth() - PAD - this.widthOf(p.column);
    return Math.min(max, Math.max(PAD, p.at + scrollOffset("columns").x - p.grab));
  }

  // How far a column is drawn from its slot: the dragged one follows the
  // pointer, the others slide toward their new slot.
  offset(column, slots) {
    if (this.press?.moved && this.press.column === column) return this.dragX() - slots[column];
    const shown = this.shown[column];
    return shown == null ? 0 : shown - slots[column];
  }

  // Insert by pointer position, not the dragged column's centre. A wide header
  // grabbed near either edge must still be able to reach the first/last slot.
  dropIndex(column) {
    const rest = this.order.filter((c) => c !== column);
    const slots = this.slots(rest);
    const pointer = this.press.at + scrollOffset("columns").x;
    return rest.filter((c) => slots[c] + this.widthOf(c) / 2 < pointer).length;
  }

  // Columns keep drawing where they are while their slots change, then ease over.
  remember() {
    const slots = this.slots();
    for (const c of this.order) this.shown[c] = slots[c] + this.offset(c, slots);
  }

  animate(cx) {
    if (this.timer != null) return;
    this.timer = cx.timer.every(FRAME, (cx) => {
      const slots = this.slots();
      let moving = false;
      for (const c of Object.keys(this.shown)) {
        if (this.press?.moved && this.press.column === c) continue;
        const left = slots[c] - this.shown[c];
        if (Math.abs(left) < 0.5) delete this.shown[c];
        else {
          this.shown[c] += left * EASE;
          moving = true;
        }
      }
      if (!moving) {
        cx.timer.cancel(this.timer);
        this.timer = null;
      }
      cx.notify();
    });
  }

  sortBy(column) {
    const first = COLUMNS[column].first;
    if (this.sort?.column !== column) this.sort = { column, dir: first };
    else if (this.sort.dir === first) this.sort = { column, dir: first === "asc" ? "desc" : "asc" };
    else this.sort = null;
  }

  // Pointer moves and releases anywhere in the panel drive a resize or reorder.
  move(e, cx) {
    if (this.resize) {
      const r = this.resize;
      this.widths[r.column] = Math.max(COLUMNS[r.column].min, Math.round(r.width + e.x - r.x));
      cx.notify();
    } else if (this.press) {
      const p = this.press;
      if (!p.moved && Math.abs(e.x - p.x) < DRAG) return;
      p.moved = true;
      p.at = e.x;
      this.startEdgeScroll(cx);
      const drop = this.dropIndex(p.column);
      if (drop !== p.drop) {
        this.remember();
        p.drop = drop;
        this.animate(cx);
      }
      cx.notify();
    }
  }

  // Keep scrolling while a held header is at an edge, even without further
  // mouse motion. This lets a title wider than the viewport reach hidden columns.
  startEdgeScroll(cx) {
    if (this.edgeTimer != null) return;
    this.edgeTimer = cx.timer.every(FRAME, (cx) => {
      const p = this.press;
      if (!p?.moved) return;
      const edge = 36;
      const speed = p.at < edge ? -24 * Math.min(1, (edge - p.at) / edge)
        : p.at > this.panel - edge ? 24 * Math.min(1, (p.at - this.panel + edge) / edge) : 0;
      const offset = scrollOffset("columns").x;
      const next = Math.min(this.maxScroll(), Math.max(0, offset + speed));
      if (next === offset) return;
      this.remember();
      scrollTo("columns", { x: next });
      p.drop = this.dropIndex(p.column);
      this.animate(cx);
      cx.notify();
    });
  }

  release(cx) {
    if (this.edgeTimer != null) {
      cx.timer.cancel(this.edgeTimer);
      this.edgeTimer = null;
    }
    const p = this.press;
    if (p && !p.moved) this.sortBy(p.column);
    else if (p && p.drop != null) {
      // The dropped column eases from under the pointer into its slot.
      this.remember();
      this.order = this.drawnOrder();
      this.animate(cx);
    }
    if (p || this.resize) this.save();
    this.press = null;
    this.resize = null;
    cx.notify();
  }

  headerCell(t, column, slots) {
    const spec = COLUMNS[column];
    const sorted = this.sort?.column === column ? this.sort.dir : null;
    const filtered = spec.filter && this.filters[column] != null;
    const dragging = this.press?.moved && this.press.column === column;
    const shift = this.offset(column, slots);
    return h_flex()
      .id(`col-${column}`).relative().w(this.widthOf(column)).h_full().flex_none().px(6).gap(3).cursor_pointer()
      .when(shift !== 0, (el) => el.left(shift))
      .when(spec.right, (el) => el.justify_end())
      .text_color(sorted || filtered || dragging ? t.foreground : t.dim)
      .when(dragging, (el) => el.bg(t.raised).rounded(4).shadow_md())
      .when(!dragging, (el) => el.hover((s) => s.bg(t.hover)))
      .tooltip(tr(spec.tooltip ?? spec.label))
      .on_mouse_down("left", (e, cx) => {
        this.press = { column, x: e.x, at: e.x, grab: e.x + scrollOffset("columns").x - this.slots(this.order)[column], moved: false, drop: null };
        this.menu = null;
        cx.stop_propagation();
        cx.notify();
      })
      .child(div().min_w(0).truncate().when(Boolean(spec.filter), (el) => el.flex_1()).child(tr(spec.label)))
      .when(Boolean(sorted), (el) => el.child(svg(sorted === "asc" ? "arrow-up.svg" : "arrow-down.svg").size(12).flex_none()))
      .when(Boolean(spec.filter), (el) => el.child(this.filterButton(t, column, filtered)))
      .child(div().id(`resize-${column}`).absolute().top(0).right(0).w(HANDLE).h_full().cursor_ew_resize()
        .hover((s) => s.bg(t.input))
        .tooltip(tr("Drag to resize"))
        .on_mouse_down("left", (e, cx) => {
          this.resize = { column, x: e.x, width: this.widthOf(column) };
          this.menu = null;
          cx.stop_propagation();
        }));
  }

  filterButton(t, column, filtered) {
    const open = this.menu === column;
    return div().id(`filter-${column}`).flex_none().p(3).rounded(4)
      .text_color(filtered ? t.accent : t.dim)
      .when(filtered || open, (el) => el.bg(filtered ? t.accent + "33" : t.raised))
      .hover((s) => s.bg(t.raised).text_color(t.foreground))
      .tooltip(filtered ? this.filters[column].join(", ") : tr(COLUMNS[column].filter))
      .on_mouse_down("left", (_e, cx) => {
        this.menu = open ? null : column;
        if (this.menuTimer != null) cx.timer.cancel(this.menuTimer);
        this.menuTimer = null;
        if (this.menu) {
          // Native scrolling moves the menu with the table. Keep it inside the panel at either edge.
          let left = this.menuLeft(column);
          this.menuTimer = cx.timer.every(FRAME, (cx) => {
            if (this.menu !== column) {
              cx.timer.cancel(this.menuTimer);
              this.menuTimer = null;
              return;
            }
            const next = this.menuLeft(column);
            if (next !== left) cx.notify();
            left = next;
          });
        }
        cx.stop_propagation();
        cx.notify();
      })
      .child(svg("funnel.svg").size(12));
  }

  // Ticks the chosen values. All covers every value, including ones that
  // appear later; unticking one value from All keeps the rest.
  choose(column, value, choices) {
    const current = this.filters[column];
    let next;
    if (value === null) next = current == null ? [] : null;
    else {
      const chosen = current ?? [...choices];
      next = chosen.includes(value) ? chosen.filter((v) => v !== value) : [...chosen, value];
      if (choices.every((v) => next.includes(v))) next = null;
    }
    this.filters[column] = next;
    // Other servers have other sessions.
    if (column === "server") this.filters.session = null;
    this.save();
  }

  menuLeft(column) {
    const offset = scrollOffset("columns").x;
    return offset + Math.max(PAD, Math.min(this.slots(this.order)[column] - offset, this.panel - 200 - PAD));
  }

  // The open filter's choices, an opaque list under its header that stays
  // open while values are ticked.
  filterMenu(t, column, choices) {
    const current = this.filters[column];
    const all = current == null;
    const item = (value, label, ticked) => h_flex()
      .id(`pick-${column}-${value ?? ""}`).px(6).h(24).flex_none().gap(6).items_center().rounded(6).cursor_pointer()
      .hover((s) => s.bg(t.hover))
      .on_mouse_down("left", (_e, cx) => {
        this.choose(column, value, choices);
        cx.stop_propagation();
        cx.notify();
      })
      .child(div().id(`${ticked ? "tick" : "box"}-${column}-${value ?? ""}`).size(14).flex_none().rounded(3).border(1).border_color(ticked ? t.accent : t.border)
        .when(ticked, (el) => el.bg(t.accent).text_color(t.background).flex().items_center().justify_center().child(svg("check.svg").size(11)))
        .when(!ticked, (el) => el.bg(t.surface)))
      .child(div().min_w(0).truncate().child(label));
    return v_flex()
      .id(`menu-${column}`).absolute().top(HEADER).left(this.menuLeft(column)).w(200).max_h(260).p(4)
      .bg(t.popover).border(1).border_color(t.border).rounded(8).shadow_lg()
      .text_size(12).font_normal().text_color(t.foreground)
      .child(item(null, tr(COLUMNS[column].filter), all))
      .child(div().h(1).my(3).flex_none().bg(t.border))
      .child(v_flex().id(`choices-${column}`).min_h(0).overflow_y_scrollbar()
        .children(choices.map((value) => item(value, value, all || current.includes(value)))));
  }

  // One cell, shifted with its column while columns slide.
  cell(column, content, slots, t) {
    const shift = this.offset(column, slots);
    const dragging = this.press?.moved && this.press.column === column;
    return div().w(this.widthOf(column)).flex_none().px(6).min_w(0).truncate()
      .when(shift !== 0, (el) => el.relative().left(shift))
      .when(dragging, (el) => el.bg(t.raised))
      .when(Boolean(COLUMNS[column].right), (el) => el.text_right())
      .child(content);
  }

  row(t, r, slots, child = false) {
    const group = Boolean(r.members?.length);
    const open = !this.folded.has(r.id);
    const value = {
      cpu: cpuText(r.cpu), memory: memoryText(r.memory), processes: countText(r.processes),
      pid: r.pid == null ? "—" : String(r.pid), server: r.server, session: r.session, pane: r.key,
    };
    return h_flex()
      .id(`row-${slug(r.id)}`).h(26).flex_none().items_center().rounded(6).text_size(12).cursor_pointer()
      .when(r.focused, (el) => el.bg("#ffffff14"))
      .hover((s) => s.bg("#ffffff0f"))
      .when(group, (el) => el.bg(t.raised).font_semibold())
      .tooltip(group ? tr(open ? "Hide connected panes" : "Show connected panes") : `${r.title}\n${r.key} · ${tr(r.status)}`)
      .on_click((_e, cx) => {
        if (!group) { run("FocusPane", { host: r.host, key: r.key }); return; }
        open ? this.folded.add(r.id) : this.folded.delete(r.id);
        cx.stop_propagation();
        cx.notify();
      })
      .children(this.drawnOrder().map((c) => this.cell(c, c === "title"
        ? group
          ? h_flex().gap(6).items_center()
            .child(svg(open ? "chevron-down.svg" : "chevron-right.svg").size(12).flex_none())
            .child(String(r.members.length))
          : h_flex().w_full().gap(6).min_w(0).items_center().when(child, (el) => el.pl(16))
            .child(icon(r.icon, 14))
            .child(div().flex_1().min_w(0).truncate().text_color(r.focused ? t.foreground : t.muted).child(r.title || r.key))
        : div().text_color(value[c] === "—" ? t.dim : t.foreground).truncate().child(value[c]), slots, t)));
  }

  // CPU is the mean of each server's own total: 100% is all of one server, so
  // adding two servers' percentages means nothing. One server: its total.
  totals(t, rows, slots) {
    const servers = new Map();
    let memory = null, processes = null;
    for (const r of rows) {
      if (r.cpu != null) servers.set(r.server, (servers.get(r.server) ?? 0) + r.cpu);
      if (r.memory != null) memory = (memory ?? 0) + r.memory;
      if (r.processes != null) processes = (processes ?? 0) + r.processes;
    }
    const sums = [...servers.values()];
    const cpu = sums.length ? sums.reduce((a, b) => a + b, 0) / sums.length : null;
    const value = { cpu: cpuText(cpu), memory: memoryText(memory), processes: countText(processes), pid: "", server: "", session: "", pane: "" };
    return h_flex()
      .id("totals").h(26).flex_none().items_center().border_t(1).border_color(t.border).text_size(12).font_semibold().text_color(t.foreground)
      .child(h_flex().flex_none().ml(PAD).items_center().children(this.drawnOrder().map((c) => c === "title"
        ? this.cell(c, rows.length === 1 ? tr("Total · 1 pane") : tr("Total · %d panes").replace("%d", String(rows.length)), slots, t)
        : this.cell(c, value[c], slots, t).when(c === "cpu" && sums.length > 1, (el) => el.tooltip(tr("Average of each server's total CPU"))))));
  }

  compact(t, rows, row) {
    // No root background: the window paints the translucent surface (mod.json).
    return (row ? h_flex().gap(4).px(4) : v_flex().py(4)).id("panes").size_full().min_h(0)
      .when(!row, (el) => el.overflow_y_scrollbar())
      .children(rows.map((r) => h_flex()
        .id(`row-${slug(r.id)}`).h(26).flex_none().gap(4).px(4).items_center().justify_center().rounded(6).text_size(11).cursor_pointer()
        .when(r.focused, (el) => el.bg("#ffffff14"))
        .hover((s) => s.bg("#ffffff0f"))
        .tooltip(`${r.title}\n${r.server} · ${r.session}\nCPU ${cpuText(r.cpu)} · RAM ${memoryText(r.memory)}`)
        .on_click(() => run("FocusPane", { host: r.host, key: r.key }))
        .child(icon(r.icon, 14))
        .child(div().text_color(t.muted).child(cpuText(r.cpu)))));
  }

  render() {
    // Mid-drag, this copy's own widths and order lead until the release saves them.
    if (!this.press && !this.resize) this.load();
    const t = theme();
    const p = props() ?? {};
    const groups = paneResources() ?? [];
    const all = [];
    for (const g of groups) {
      // "This Computer" names the local server, as the Sessions list does.
      const server = g.local ? tr("This Computer") : g.server;
      // `pane` sorts %2 before %10; the cell shows the key itself.
      const decorate = (r) => ({ ...r, server, session: g.session, pane: Number(String(r.key).replace(/^%/, "")) || null });
      for (const r of g.rows) all.push({ ...decorate(r), members: (r.members ?? []).map(decorate) });
    }
    const servers = [...new Set(all.map((r) => r.server))];
    const filters = this.filters;
    const onServers = all.filter((r) => passes(filters.server, r.server));
    const sessions = [...new Set(onServers.map((r) => r.session))];
    const rows = onServers.filter((r) => passes(filters.session, r.session));
    if (this.sort) {
      const { column, dir } = this.sort;
      rows.sort((a, b) => compare(a, b, column, dir));
    }
    // Summary rows never participate in footer totals or compact pane lists:
    // each actual pane contributes exactly once, regardless of folded state.
    const leaves = rows.flatMap((r) => r.members?.length ? r.members : [r]);
    if (p.compact) return this.compact(t, leaves, Boolean(p.row));

    // A caption wherever the server or session changes; one chosen server is not repeated.
    const oneServer = filters.server?.length === 1;
    const slots = this.slots();
    const body = [];
    let caption = "";
    for (const r of rows) {
      const next = oneServer ? r.session : [r.server, r.session].filter(Boolean).join(" · ");
      if (next && next !== caption) body.push(div().id(`ctx-${slug(r.id)}`).pl(PAD + 6).pr(4).mt(3).mb(-2).text_size(10).text_color(t.idle + "bf").truncate().tooltip(next).child(next));
      caption = next;
      body.push(this.row(t, r, slots));
      if (r.members?.length && !this.folded.has(r.id)) {
        const members = [...r.members];
        if (this.sort) members.sort((a, b) => compare(a, b, this.sort.column, this.sort.dir));
        for (const member of members) body.push(this.row(t, member, slots, true));
      }
    }
    const header = h_flex()
      .id("header").relative().h(HEADER).flex_none().pl(PAD).items_center().text_size(11).font_semibold().border_b(1).border_color(t.border)
      .children(this.drawnOrder().map((c) => this.headerCell(t, c, slots)));
    const choices = this.menu === "server" ? servers : this.menu === "session" ? sessions : [];
    const empty = all.length === 0 ? tr("No panes.") : tr("No panes match the filters.");
    return v_flex()
      .id("table").relative().size_full().min_h(0).overflow_hidden().text_color(t.foreground)
      .on_size_change((size, cx) => {
        if (Math.round(size.width) === this.panel) return;
        this.panel = Math.round(size.width);
        cx.notify();
      })
      .on_mouse_move((e, cx) => this.move(e, cx))
      .on_mouse_up("left", (_e, cx) => this.release(cx))
      .on_mouse_down("left", (_e, cx) => {
        if (this.menu == null) return;
        this.menu = null;
        cx.notify();
      })
      .child(div().id("columns").flex_1().min_h(0).overflow_x_scrollbar()
        .child(v_flex().relative().w(this.contentWidth()).h_full()
          .child(header)
          .child(v_flex().id("rows").flex_1().min_h(0).px(PAD).overflow_y_scrollbar()
            .when(rows.length === 0, (el) => el.child(div().px(6).py(6).text_size(12).text_color(t.dim).child(empty)))
            .children(body))
          .child(this.totals(t, leaves, slots))
          .when(this.menu != null, (el) => el.child(this.filterMenu(t, this.menu, choices)))));
  }
}
