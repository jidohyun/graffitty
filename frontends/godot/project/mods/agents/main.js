// Show agents by priority. The view comes from herdr-app's
// defaults/mods/agents/main.js (Apache-2.0).
//
// The port keeps the sections, row sizes, pin controls that replace the
// time on hover, fold chevrons, tree lines, and status glyphs.
//
// Rust (client-core) decides grouping and status. Each row has a `section`
// and connected panes in `subs`. Consecutive rows from the same server
// and session share a caption.

import { View, div, svg, image, v_flex, h_flex } from "graffitty-ui";
import { agents, run, theme, props, tr } from "graffitty";

// Translucent so the panel's blurred backdrop shows through. The focused row
// is clearly brighter than a hovered one, and does not change under the pointer.
const SELECTED = "#ffffff1f";
const HOVER = "#ffffff0a";
const RANK = { blocked: 3, working: 2, done: 1, idle: 0 };
const SECTION_COLOR = { "Needs you": "blocked", Done: "done", Working: "working" };
const ICONS = {
  claude: "claude-code.svg", pi: "pi.svg", codex: "codex.png", opencode: "opencode.svg",
  python: "python.svg", chromium: "chromium.svg", filetree: "folder-tree.svg",
};

function duration(seconds) {
  const m = Math.floor(Math.max(seconds, 0) / 60);
  if (m < 1) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// Provider artwork keeps its own colors; interface glyphs follow the tint.
function icon(name, size, status) {
  const file = ICONS[name] ?? "square-terminal.svg";
  return (file.endsWith(".png") || name === "pi" ? image(file) : svg(file).text_color("#ffffff"))
    .size(size).flex_none().when(status === "offline", el => el.grayscale().opacity(0.55));
}

// Local agents show only their session; remote agents show server · session.
const compactTitle = (row, title) => [row.remote || tr("This Computer"), row.session, title].filter(Boolean).join(" · ");
const context = (row) => [row.remote, row.session].filter(Boolean).join(" · ");

export default class Agents extends View {
  init(_props, cx) {
    this.folded = new Set();
    this.foldedRows = new Set();
    this.hovered = null;
    // Elapsed times are whole minutes; refresh them every 30 s, as herdr does.
    cx.timer.every(30000, (cx) => cx.notify());
  }

  // compact: a ! for blocked where a header already says "Needs you".
  status(t, status, compact = false) {
    const color = t[status] ?? t.dim;
    if (status === "offline") return svg("circle-x.svg").size(14).flex_none().text_color(t.dim).grayscale();
    if (status === "working") return svg("loader-circle.svg").size(12).mx(1).flex_none().text_color("#8ab4f8").spin(2000);
    if (status === "blocked" && compact) return div().size(14).flex_none().rounded(4).bg(t.blocked + "26").text_size(10.5).font_bold().text_color(t.blocked).flex().items_center().justify_center().child("!");
    if (status === "blocked") return div().flex_none().px(6).h(18).rounded(5).bg(t.blocked + "26").text_size(10.5).font_semibold().text_color(t.blocked).flex().items_center().child(tr("Needs you"));
    // Idle: a ring; done: a dot.
    if (status === "idle") return div().size(7).mx(3).flex_none().rounded(4).border(1.5).border_color(t.idle);
    return div().size(7).mx(3).flex_none().rounded(4).bg(status === "done" ? color : t.dim + "00");
  }

  subRow(t, row, sub) {
    const key = `${row.id}|${sub.key}`;
    return h_flex()
      .id(`sub-${key}`)
      .pl(20).pr(8).h(26).flex_none().items_center().gap(0).text_size(12).rounded(8)
      .hover((s) => s.bg(HOVER))
      .on_click(() => run("FocusPane", { host: sub.host_id, key: sub.key }))
      .children(sub.lines.map((l) => div().self_start().mt(-4).w(9).h(17).mr(4).flex_none()
        .when(Boolean(l), (el) => el.border_l(1.5).border_color(t.input))
        .when(l === "└" || l === "├", (el) => el.border_b(1.5).rounded_bl(6))))
      .child(div().mr(8).child(icon(sub.icon, 14, sub.status)))
      .child(div().flex_1().min_w(0).truncate().tooltip_on_truncate().text_color(t.idle).child(sub.title))
      .when(sub.kind === "agent" && Boolean(sub.status), (el) => el.child(this.status(t, sub.status, true)));
  }

  row(t, a, now) {
    const subs = a.subs ?? [];
    const open = !this.foldedRows.has(a.id);
    const hovered = this.hovered === a.id;
    const top = subs.reduce((m, s) => ((RANK[s.status] ?? -1) > (RANK[m] ?? -1) ? s.status : m), "idle");
    const pin = div()
      .id(`pin-${a.id}`).flex_none().p(2).rounded(4).text_color(t.dim).cursor_pointer()
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .tooltip(tr(a.pinned ? "Unpin" : "Pin to the top"))
      .on_click((_e, cx) => {
        cx.stop_propagation();
        run("PinAgent", { id: a.id, pinned: !a.pinned });
        // The row moves away from under the pointer, and no hover-out comes.
        this.hovered = null;
        cx.notify();
      })
      .child(svg(a.pinned ? "pin-off.svg" : "pin.svg").size(13));
    const fold = div()
      .id(`fold-${a.id}`).h(18).px(3).gap(3).flex().items_center().rounded(4).text_size(11)
      .text_color(open ? t.idle : (t[top] ?? t.idle)).cursor_pointer()
      .tooltip(tr(open ? "Hide connected panes" : "Show connected panes"))
      .hover((s) => s.bg(t.hover).text_color(t.foreground))
      .on_click((_e, cx) => {
        cx.stop_propagation();
        open ? this.foldedRows.add(a.id) : this.foldedRows.delete(a.id);
        cx.notify();
      })
      .child(svg(open ? "chevron-down.svg" : "chevron-right.svg").size(11).flex_none())
      .when(!open, (el) => el.child(String(subs.length)));
    return h_flex()
      .id(`ag-${a.id}`)
      .px(4).h(28).flex_none().rounded(8).items_center().gap(6).text_size(13)
      .when(a.focused, (el) => el.bg(SELECTED))
      .when(!a.focused, (el) => el.hover((s) => s.bg(HOVER)))
      .on_hover((on, cx) => {
        if (on) this.hovered = a.id;
        else if (this.hovered === a.id) this.hovered = null;
        cx.notify();
      })
      .on_click(() => run("FocusAgent", { id: a.id }))
      .child(icon(a.provider, 16, a.status))
      .child(div().flex_1().min_w(0).truncate().tooltip_on_truncate().text_color(a.status === "idle" && !a.focused ? t.idle : t.foreground).child(a.title))
      .when(subs.length > 0, (el) => el.child(fold))
      .when(!hovered, (el) => el.child(div().id(`time-${a.id}`).flex_none().text_size(11).text_color(t.idle).child(duration(now - a.at))))
      .when(hovered, (el) => el.child(pin))
      .child(div().id(`status-${a.id}`).flex_none().flex().items_center()
        .child(a.status === "blocked" && !a.pinned ? this.status(t, "blocked", true) : this.status(t, a.status)));
  }

  compactRow(t, a, number) {
    return h_flex()
      .id(`ag-${a.id}`).h(26).px(4).flex_none().items_center().gap(2)
      .when(a.focused, (el) => el.bg(SELECTED))
      .when(!a.focused, (el) => el.hover((s) => s.bg(HOVER)))
      .tooltip(compactTitle(a, a.title))
      .on_click(() => run("FocusAgent", { id: a.id }))
      .child(div().flex_1().min_w(0).whitespace_nowrap().text_right().text_size(12).text_color(t.idle).child(String(number)))
      .child(h_flex().w(14).flex_none().items_center().justify_center().child(this.status(t, a.status, true)));
  }

  // A connected agent gets its own compact row too: grouping it under the
  // lead would hide that it exists and whether it is working.
  compactSubRow(t, row, sub, number) {
    return h_flex()
      .id(`ag-sub-${row.id}|${sub.key}`).h(26).px(4).flex_none().items_center().gap(2)
      .hover((s) => s.bg(HOVER))
      .tooltip(compactTitle(sub.row_id ? sub : row, sub.title))
      .on_click(() => run("FocusPane", { host: sub.host_id, key: sub.key }))
      .child(div().flex_1().min_w(0).whitespace_nowrap().text_right().text_size(12).text_color(t.idle).child(String(number)))
      .child(h_flex().w(14).flex_none().items_center().justify_center().child(this.status(t, sub.status, true)));
  }

  render() {
    const t = theme();
    const list = agents();
    const now = Date.now() / 1000;
    if (props()?.compact) {
      const rows = [];
      for (const a of list) {
        rows.push(this.compactRow(t, a, rows.length + 1));
        for (const sub of a.subs ?? []) {
          if (sub.kind === "agent") rows.push(this.compactSubRow(t, a, sub, rows.length + 1));
        }
      }
      return v_flex().id("ag-list").size_full().min_h(0).overflow_y_scrollbar().children(rows);
    }
    // Groups in list order: the Rust model already orders sections.
    const groups = [];
    for (const a of list) {
      if (groups.at(-1)?.label === a.section) groups.at(-1).members.push(a);
      else groups.push({ label: a.section, members: [a] });
    }
    const header = (g) => {
      const open = !this.folded.has(g.label);
      return h_flex()
        .id(`sec-${g.label}`).px(4).h(26).flex_none().gap(6).items_center().text_size(11).cursor_pointer()
        .text_color(t[SECTION_COLOR[g.label]] ?? t.idle)
        .hover((s) => s.text_color(t.foreground))
        .on_click((_e, cx) => {
          open ? this.folded.add(g.label) : this.folded.delete(g.label);
          cx.notify();
        })
        .child(div().child(`${tr(g.label)}  ${g.members.length}`))
        .when(!open, (el) => el.child(div().child("›")));
    };
    const rows = [];
    for (const g of groups) {
      rows.push(header(g));
      if (this.folded.has(g.label)) continue;
      let caption = "";
      for (const a of g.members) {
        // Consecutive rows from the same server/session share one small caption.
        const next = context(a);
        if (next && next !== caption) {
          // Natural text height, so descenders and tall scripts are not cropped;
          // the negative bottom margin tucks it against its row's top padding.
          // flex_none: the scrolling column must not shrink it once rows overflow.
          rows.push(div().id(`ctx-${a.id}`).flex_none().pl(26).pr(4).mt(3).mb(-4).text_size(10).text_color(t.idle + "bf").truncate().tooltip_on_truncate().child(next));
        }
        caption = next;
        rows.push(this.row(t, a, now));
        if (this.foldedRows.has(a.id)) continue;
        for (const sub of a.subs ?? []) rows.push(this.subRow(t, a, sub));
      }
    }
    return v_flex().size_full().min_h(0).text_size(13)
      .when(list.length === 0, (el) => el.child(div().px(8).py(6).text_size(12).text_color(t.foreground).child(tr("No agent status yet. Agents show up here when they report their status."))))
      .child(v_flex().id("ag-list").flex_1().min_h(0).px(4).overflow_y_scrollbar().children(rows));
  }
}
