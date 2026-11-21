// The status line: the session this window shows, how many agents and who
// needs you, and switches for the workspace prefix and the adaptive zoom
// effect.
//
// Ported from herdr-app defaults/mods/workspace-status/main.js (Apache-2.0).
// Bundled; a user mod of another name lives in ~/.config/graffitty/mods/<name>/ (docs/developers/automation-and-extensions/mods.md).

import { View, div, svg, h_flex } from "graffitty-ui";
import { agents, effects, prefix, props, session, theme, run, tr } from "graffitty";

// Effect names from graffitty/effects.gd, with each switch's label and icon.
const PLATFORM_ICON = { macos: "os-macos.svg", windows: "os-windows.svg", linux: "os-linux.svg" };

const SWITCHES = [
  { effect: "camera.zoom", label: "Adaptive zoom effect", icon: "zoom-in.svg" },
];

// Why browser video uses the WebSocket, for the warning's tooltip.
const VIDEO_REASONS = {
  unoffered: "The server did not offer UDP video.",
  unavailable: "This device could not open a UDP socket.",
  no_reply: "No UDP reply from %s. A firewall, VPN, proxy or SSH tunnel may block it; allow UDP on that port.",
  stopped: "UDP replies from %s stopped, so video returned to the WebSocket.",
};

const videoTooltip = (video) => [
  tr("Browser video uses the WebSocket: a lost packet delays the whole connection until TCP resends it."),
  tr(VIDEO_REASONS[video.reason] ?? "").replace("%s", video.address ?? ""),
].filter(Boolean).join("\n");

// Roughly what a label takes at the line's 13 px text, to decide early
// whether the labelled layout fits; a clipped label is worse than an icon.
const textWidth = (text) => text.length * 7.3;

export default class StatusLine extends View {
  render() {
    const t = theme();
    const p = props() ?? {};
    const list = agents();
    const needs = list.filter((a) => a.status === "blocked").length;
    const current = session();
    const disabled = effects()?.disabled ?? [];
    const leader = prefix();
    const prefixLabel = leader?.available ? `${tr("Prefix")} ${leader.key}` : "";
    const agentsLabel = `${list.length} ${tr(list.length === 1 ? "agent" : "agents")}`;
    // A remote session's browser video fell back to the WebSocket.
    const video = current?.video ?? {};
    const videoWarning = video.streaming && video.transport === "websocket";
    const videoLabel = tr("WebSocket video");
    // Keep informational labels when they fit. Effect switches always use
    // icons, colored when on, with their names in tooltips.
    const labelled = 20 + 16 * 6
      + (current ? 19 + textWidth(current.name ?? "") + 6 + textWidth(current.id) : 0)
      + (videoWarning ? 16 + 19 + textWidth(videoLabel) : 0)
      + (list.length > 0 ? 12 + textWidth(agentsLabel) + (needs > 0 ? 6 + textWidth(`· ${needs} ${tr("needs you")}`) : 0) : 0)
      + (prefixLabel ? 20 + textWidth(leader.key) : 0)
      + SWITCHES.length * 28;
    const icons = (p.width ?? 0) > 0 && p.width < labelled;

    const toggle = (id, label, icon, on, action, args) => {
      let chip = h_flex().id(id).gap(6).items_center().px(6).h(22).rounded(5).cursor_pointer()
        .flex_none()
        .text_color(on ? t.foreground : t.dim)
        .hover((s) => s.bg(t.hover))
        .tooltip(label)
        .on_click(() => run(action, args));
      if (typeof icon !== "string") return chip.child(icon);
      return chip.child(svg(icon).size(16).flex_none().text_color(on ? t.accent : t.dim));
    };

    let line = h_flex().size_full().px(10).gap(icons ? 10 : 16).items_center().overflow_hidden().text_size(13).text_color(t.muted)
      // The session this window shows, as the Sessions window names it: "name  $id", or "$id".
      .when(Boolean(current), (el) => el.child(h_flex().id("session").gap(6).items_center().min_w(0).flex_shrink(1).overflow_hidden()
        .tooltip(current.local ? tr("This Computer") : current.server)
        .child(svg(PLATFORM_ICON[current.platform] ?? "monitor.svg").size(14).flex_none())
        .when(Boolean(current.name), (c) => c.child(div().min_w(0).truncate().text_color(t.foreground).child(current.name)))
        .child(div().flex_none().child(current.id))))
      .when(videoWarning, (el) => el.child(h_flex().id("video-transport").gap(6).items_center().flex_none()
        .text_color(t.working).tooltip(videoTooltip(video))
        .child(svg("triangle-alert.svg").size(14).flex_none().text_color(t.working))
        .when(!icons, (w) => w.child(div().whitespace_nowrap().child(videoLabel)))))
      .when(list.length > 0, (line) => line.child(h_flex().id("agents").flex_none().gap(6).items_center().tooltip(agentsLabel)
        .child(div().size(6).rounded(3).bg(t.dim))
        .child(div().whitespace_nowrap().child(icons ? String(list.length) : agentsLabel))
        .when(needs > 0, (el) => el.child(div().whitespace_nowrap().text_color(t.blocked)
          .child(icons ? `· ${needs}` : `· ${needs} ${tr("needs you")}`)))))
      .child(div().flex_1().min_w(0));
    // The workspace prefix: lit while armed (the next key is a prefix
    // command). Tapping arms or cancels it, which matters where the prefix
    // chord is hard to type.
    //
    // It is always the chord itself as a keycap, labelled only in its
    // tooltip: a glyph would read as one key (⌘ looks like Command) rather
    // than this window's prefix.
    if (leader?.available) {
      const keycap = h_flex().items_center().px(4).h(17).flex_none().rounded(3).border(1).border_color(leader.active ? t.accent : t.dim)
        .text_size(11).text_color(leader.active ? t.accent : t.dim).whitespace_nowrap().child(leader.key);
      line = line.child(toggle("prefix", prefixLabel, keycap, leader.active, "TogglePrefix")
        .bg(leader.active ? t.accent + "33" : "#00000000")
        .hover((s) => s.bg(leader.active ? t.accent + "4d" : t.hover)));
    }
    for (const item of SWITCHES) {
      const on = !disabled.includes(item.effect);
      line = line.child(toggle(item.effect, tr(item.label), item.icon, on, "ToggleEffect", { effect: item.effect }));
    }
    return line;
  }
}
