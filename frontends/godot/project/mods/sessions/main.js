// Named sessions grouped by server. Ported from herdr-app
// defaults/mods/spaces/main.js (Apache-2.0): the grouped rows under a machine
// header, the avatar, click to switch, right-click for its menu, drag to
// reorder.
//
// Graffitty shows real named sessions on real servers instead of Herdr
// spaces; there is no git metadata and no invented folder.

import { View, div, svg, v_flex, h_flex } from "graffitty-ui";
import { sessions, live, run, theme, props, window, shared, setShared, tr } from "graffitty";

// A session row, and the "Add server" footer with its bottom margin.
const ROW_HEIGHT = 32;
const FOOTER_HEIGHT = 32;

const ICON = { macos: "os-macos.svg", windows: "os-windows.svg", linux: "os-linux.svg" };

// A session keeps its colour when its display name changes.
function mark(id) {
  let h = 0;
  for (const c of id) h = (h * 31 + c.codePointAt(0)) >>> 0;
  const hue = ((Math.imul(h, 2654435761) >>> 0) / 4294967296);
  // HSV (hue, .52, .72), as the native badge coloured it.
  const s = 0.52, v = 0.72, i = Math.floor(hue * 6), f = hue * 6 - i;
  const p = v * (1 - s), q = v * (1 - f * s), u = v * (1 - (1 - f) * s);
  const [r, g, b] = [[v, u, p], [q, v, p], [p, v, u], [p, q, v], [u, p, v], [v, p, q]][i % 6];
  const hex = (x) => Math.round(x * 255).toString(16).padStart(2, "0");
  return `#${hex(r)}${hex(g)}${hex(b)}`;
}

export default class Sessions extends View {
  init() {
    this.folded = new Set(JSON.parse(localStorage.getItem("folded") ?? "[]"));
    this.pressed = null;
    this.over = null;
    this.sessionPress = null;
    this.sessionOver = null;
    this.suppressClick = false;
  }

  ordered(groups) {
    const orders = shared("sessions.order") ?? {};
    return groups.map((g) => {
      const ids = orders[g.id] ?? [];
      const rank = (s) => { const i = ids.indexOf(s.id); return i < 0 ? ids.length : i; };
      return { ...g, sessions: [...g.sessions].sort((a, b) => rank(a) - rank(b)) };
    });
  }

  sessionEvents(el, group, s) {
    el = el.on_mouse_down("right", (_e, cx) => {
      this.sessionPress = null;
      this.sessionOver = null;
      cx.stop_propagation();
      run("SessionContextMenu", { server: group.id, session: s.id });
    });
    // Touch keeps its existing list scrolling and tap-to-select behavior.
    if (window()?.touch) return el.on_click(() => run("SelectSession", { server: group.id, session: s.id }));
    const drop = live("sessions_drop") ?? {};
    const active = drop.server === group.id && drop.session === s.id;
    const press = this.sessionPress;
    const over = press?.server === group.id && this.sessionOver === s.id && press.session !== s.id;
    return el.relative()
      .when(active, (e) => e.bg(theme().hover))
      .when(press?.server === group.id && press.session === s.id && this.sessionOver !== s.id, (e) => e.opacity(0.5))
      .when(over, (e) => e.child(div().absolute().left(0).right(0).h(2).bg(theme().accent)
        .when(group.sessions.findIndex((r) => r.id === press.session) < group.sessions.findIndex((r) => r.id === s.id), (l) => l.bottom(0))
        .when(group.sessions.findIndex((r) => r.id === press.session) > group.sessions.findIndex((r) => r.id === s.id), (l) => l.top(0))))
      .on_mouse_down("left", () => {
        this.sessionPress = { server: group.id, session: s.id };
        this.sessionOver = s.id;
        this.suppressClick = false;
      })
      .on_hover((on, cx) => {
        if (!this.sessionPress) return;
        if (!on && (this.sessionPress.server !== group.id || this.sessionOver !== s.id)) return;
        const over = on && this.sessionPress.server === group.id ? s.id : null;
        if (this.sessionOver !== over) {
          this.sessionOver = over;
          this.suppressClick = true;
          cx.notify();
        }
      })
      .on_mouse_up("left", (_e, cx) => {
        const from = this.sessionPress;
        const over = this.sessionOver;
        if (from?.server === group.id && over !== null && from.session !== over) {
          const ids = group.sessions.map((r) => r.id);
          const before = ids.indexOf(from.session) > ids.indexOf(over);
          ids.splice(ids.indexOf(from.session), 1);
          ids.splice(ids.indexOf(over) + (before ? 0 : 1), 0, from.session);
          setShared("sessions.order", { ...(shared("sessions.order") ?? {}), [group.id]: ids });
          this.suppressClick = true;
        }
        this.sessionPress = null;
        this.sessionOver = null;
        cx.notify();
      })
      .on_click(() => {
        if (!this.suppressClick) run("SelectSession", { server: group.id, session: s.id });
        this.suppressClick = false;
      });
  }

  fold(id, cx) {
    this.folded.has(id) ? this.folded.delete(id) : this.folded.add(id);
    localStorage.setItem("folded", JSON.stringify([...this.folded]));
    cx.notify();
  }

  // A row reads "avatar  name  id"; the id alone when nobody named it.
  row(t, group, s) {
    const name = s.name || s.id;
    const on = s.viewing;
    return this.sessionEvents(h_flex()
      .id(`session-${group.id}-${s.id}`)
      .px(4).h(ROW_HEIGHT).flex_none().gap(6).items_center().rounded(8).text_size(14)
      .when(on, (el) => el.bg(t.selected))
      .when(!on, (el) => el.hover((h) => h.bg(t.hover)))
      .child(h_flex().size(24).flex_none().rounded(8).bg(mark(group.id + "/" + s.id)).items_center().justify_center().text_size(14).text_color("#ffffff").child([...name][0]?.toUpperCase() ?? "?"))
      .child(div().id(`name-session-${group.id}-${s.id}`).flex_1().min_w(0).truncate().tooltip_on_truncate().text_color(t.foreground).child(name))
      .when(Boolean(s.name), (el) => el.child(div().flex_none().text_size(11).text_color(t.dim).child(s.id))), group, s);
  }

  action(t, id, text, go) {
    return h_flex().id(id).px(8).h(28).flex_none().items_center().rounded(8).text_size(14).text_color(t.foreground)
      .hover((h) => h.bg(t.hover)).cursor_pointer().on_click(go).child(div().truncate().child(text));
  }

  // A server's header: its OS, name, a + for a new session, the connection dot, the fold chevron.
  header(t, group, groups) {
    const name = group.local ? tr("This Computer") : group.name;
    const folded = this.folded.has(group.id);
    const fromIndex = this.pressed === null ? -1 : groups.findIndex((g) => g.id === this.pressed);
    const index = groups.findIndex((g) => g.id === group.id);
    return h_flex()
      .id(`server-${group.id}`).relative()
      .when((live("sessions_drop") ?? {}).key === `server-${group.id}`, (el) => el.bg(t.hover))
      .h(28).flex_none().px(4).gap(6).items_center().rounded(8).text_size(14).text_color(t.dim)
      .hover((h) => h.bg(t.hover))
      .when(this.pressed === group.id && this.over !== group.id, (el) => el.opacity(0.5))
      .when(this.pressed !== null && this.over === group.id && this.pressed !== group.id, (el) => el.child(
        div().absolute().left(0).right(0).h(2).bg(t.accent).when(fromIndex < index, (l) => l.bottom(0)).when(fromIndex > index, (l) => l.top(0))))
      .on_mouse_down("left", () => {
        if (!group.saved) return;
        this.pressed = group.id;
        this.over = group.id;
      })
      .on_mouse_move((_e, cx) => {
        const over = this.pressed !== null && group.saved ? group.id : null;
        if (this.pressed !== null && this.over !== over) {
          this.over = over;
          cx.notify();
        }
      })
      .on_mouse_up("left", (_e, cx) => {
        const from = this.pressed, over = this.over;
        this.pressed = null;
        this.over = null;
        if (from !== null && over === group.id && from !== group.id) run("MoveServer", { server: from, target: group.id, before: fromIndex > index });
        else if (from === group.id || from === null) this.fold(group.id, cx);
        cx.notify();
      })
      .child(svg(ICON[group.platform] ?? "monitor.svg").size(16).flex_none())
      .child(div().flex_1().min_w(0).truncate().child(name))
      .when(group.connected || group.local, (el) => el.child(div().id(`new-${group.id}`).w(36).h(24).flex().items_center().justify_center().rounded(6).text_color(t.foreground)
        .hover((h) => h.bg(t.raised)).tooltip(tr("New session on %s").replace("%s", name))
        .on_click((_e, cx) => { cx.stop_propagation(); run("NewSession", { server: group.id }); }).child("+")))
      .child(div().size(8).rounded(4).flex_none().bg(group.connected ? t.connected : "#666873").tooltip(tr(group.connected ? "Connected" : "Not connected")))
      .child(svg(folded ? "chevron-right.svg" : "chevron-down.svg").size(12).flex_none().mx(6));
  }

  compact(t, groups) {
    const rows = [];
    for (const group of groups) {
      rows.push(h_flex().id(`server-${group.id}`).h(26).flex_none().justify_center().items_center().tooltip(group.local ? tr("This Computer") : group.name)
        .when((live("sessions_drop") ?? {}).key === `server-${group.id}`, (el) => el.bg(t.hover))
        .child(svg(ICON[group.platform] ?? "monitor.svg").size(16).text_color(t.dim)));
      for (const s of group.sessions) {
        rows.push(this.sessionEvents(h_flex().id(`session-${group.id}-${s.id}`).h(26).flex_none().justify_center().items_center().rounded(8).text_size(14)
          .when(s.viewing, (el) => el.bg(t.selected)).when(!s.viewing, (el) => el.hover((h) => h.bg(t.hover)))
          .tooltip(s.name || s.id)
          .child(s.id.replace(/^\$/, "")), group, s));
      }
    }
    return rows;
  }

  render() {
    const t = theme();
    const p = props() ?? {};
    const groups = this.ordered(sessions() ?? []);
    const status = live("sessions_status") ?? "";
    const touch = Boolean(window()?.touch);
    if (p.compact) {
      return v_flex().id("list").size_full().min_h(0).overflow_y_scrollbar().children(this.compact(t, groups));
    }
    const rows = [];
    for (const group of groups) {
      rows.push(this.header(t, group, groups));
      if (this.folded.has(group.id)) continue;
      if (!group.connected && !group.local) rows.push(this.action(t, `connect-${group.id}`, tr("Connect"), () => run("ConnectServer", { server: group.id })));
      else if (group.sessions.length === 0) rows.push(this.action(t, `empty-${group.id}`, tr("New Session"), () => run("NewSession", { server: group.id })));
      else for (const s of group.sessions) rows.push(this.row(t, group, s));
    }
    if (groups.length === 0) rows.push(this.action(t, "connect", tr("Connect to a server…"), () => run("OpenServers")));
    // The footer only earns its row when the list above it still shows five
    // session rows; a shorter panel gives all of its height to the list.
    const roomy = this.height === undefined || this.height >= 5 * ROW_HEIGHT + FOOTER_HEIGHT;
    return v_flex().id("panel").size_full().min_h(0).text_size(14)
      .on_size_change((size, cx) => {
        const height = Math.round(size.height);
        if (height === this.height) return;
        this.height = height;
        cx.notify();
      })
      .child(v_flex().id("list").flex_1().min_h(0).px(4).overflow_y_scrollbar()
        .when((live("sessions_drop") ?? {}).key === "list", (el) => el.bg(t.hover))
        .on_mouse_up("left", (_e, cx) => { this.pressed = null; this.over = null; this.sessionPress = null; this.sessionOver = null; cx.notify(); })
        .children(rows))
      .when(Boolean(status), (el) => el.child(div().id("status").px(8).h(18).text_size(11).text_color(t.dim).truncate().child(status)))
      .when(!touch && roomy, (el) => el.child(h_flex().id("add-server").mx(4).mb(4).h(28).flex_none().items_center().justify_center().rounded(8).text_size(14)
        .text_color(t.foreground).hover((h) => h.bg(t.hover)).cursor_pointer().tooltip(tr("Add server"))
        .on_click(() => run("OpenServers")).child(`+ ${tr("Add server")}`)));
  }
}
