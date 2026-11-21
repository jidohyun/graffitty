// Pane Status: the focused pane's CPU, memory, processes and agent.
//
// Expanded, one icon row per reading, each naming itself in its tooltip; in a
// compact rail or a one-row band, the pane id, CPU, memory and the agent
// badge.
//
// Written for Graffitty in the shape of a herdr-app mod (Apache-2.0).

import { View, div, svg, image, h_flex, v_flex } from "graffitty-ui";
import { resources, theme, props, tr } from "graffitty";

const LOGOS = { claude: "claude-code.svg", codex: "codex.png", opencode: "opencode.svg", pi: "pi.svg" };
const STATUS = {
  running: ["loader-circle.svg", "#8ab4f8", true], busy: ["loader-circle.svg", "#8ab4f8", true],
  idle: ["circle-check.svg", "#89ddbd", false], waiting: ["circle-pause.svg", "#ffd078", false], blocked: ["circle-pause.svg", "#ffd078", false],
  offline: ["circle-x.svg", "#a0a0a0", false], error: ["circle-alert.svg", "#ff8080", false], failed: ["circle-alert.svg", "#ff8080", false],
};

// The monitor's own state, drawn only when it is not measuring.
const MONITOR = {
  starting: ["loader-circle.svg", "#8ab4f8", true], paused: ["circle-pause.svg", "#ffd078", false],
  unavailable: ["circle-x.svg", "#aab3c2", false], disabled: ["circle-x.svg", "#aab3c2", false],
};
const KIND = { terminal: "square-terminal.svg", chromium: "chromium.svg" };

function duration(seconds) {
  const m = Math.floor(Math.max(seconds, 0) / 60);
  if (m < 1) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

// Provider identity plus status, as the status strip's badge draws it.
function badge(agent, t, row, tooltip) {
  if (!agent) return null;
  const provider = (agent.provider || "").toLowerCase();
  const logo = LOGOS[provider];
  const [icon, tint, spins] = STATUS[agent.status] ?? ["circle-question-mark.svg", "#aab3c2", false];
  const name = agent.name || (agent.provider ? agent.provider[0].toUpperCase() + agent.provider.slice(1) : tr("Node"));
  const since = agent.since != null && agent.since >= 0 ? duration(Date.now() / 1000 - agent.since) : null;
  return h_flex().id("agent").gap(6).items_center().flex_none()
    .when(!row, (el) => el.flex_wrap())
    .tooltip(tooltip ?? `${name} · ${agent.label}`)
    .when(Boolean(logo), (el) => el.child((logo.endsWith(".png") || provider === "pi" ? image(logo) : svg(logo).text_color(t.foreground)).size(20).flex_none().when(agent.status === "offline", icon => icon.grayscale().opacity(0.55))))
    .when(!logo, (el) => el.child(div().text_size(12).truncate().child(name)))
    .child(svg(icon).size(20).flex_none().text_color(tint).when(spins, (el) => el.spin(2000)))
    .when(Boolean(since), (el) => el.child(div().text_size(11).text_color(t.dim).child(since)));
}

// Rough width of `text` at `size`; the readouts are digits and a unit.
const wide = (text, size) => String(text ?? "").length * size * 0.6;

// Whether the compact readout fits `space` (the band's width, or the rail's
// height) with the CPU and memory icons drawn.
function fits(sample, row, space, since) {
  const agent = sample.agent && Object.keys(sample.agent).length ? sample.agent : null;
  if (row) {
    const metric = (value) => 16 + 6 + Math.max(30, wide(value, 11));
    const badge = agent ? 10 + 20 + 6 + 20 + (since ? 6 + wide(since, 11) : 0) : 0;
    return 12 + wide(sample.pane, 11) + 10 + metric(sample.cpu) + 10 + metric(sample.memory) + badge <= space;
  }
  // Stacked: the id, then an icon over each value, then the badge's marks.
  return 12 + 15 + 2 * (6 + 16 + 2 + 14) + (agent ? 6 + 20 + 20 : 0) <= space;
}

export default class PaneStatus extends View {
  init(_props, cx) {
    // The agent's elapsed time: whole minutes, refreshed every 30 s as the badge does.
    cx.timer.every(30000, (cx) => cx.notify());
  }

  render() {
    const t = theme();
    const p = props() ?? {};
    const sample = resources();
    if (!sample) return div().size_full().px(6).text_size(12).text_color(t.dim).child(tr("Resource monitoring is unavailable for this pane."));
    if (p.compact) {
      const row = Boolean(p.row);
      // A one-row band reads left to right; a narrow rail stacks each value
      // under its icon so it fits the rail's width.
      //
      // Short of room, the values stay and their icons go: the tooltip and
      // the order (CPU, then memory) still say which is which.
      const since = sample.agent?.since != null && sample.agent.since >= 0 ? duration(Date.now() / 1000 - sample.agent.since) : null;
      const space = row ? this.size?.width : this.size?.height;
      const icons = space == null || fits(sample, row, space, since);
      const metric = (icon, value) => (row ? h_flex().gap(6) : v_flex().gap(2)).items_center().flex_none()
        .when(icons, (el) => el.child(svg(icon).size(16).flex_none().text_color(t.foreground)))
        .child(div().text_size(row ? 11 : 10).min_w(row && icons ? 30 : 0).child(value));
      const body = (row ? h_flex().gap(10) : v_flex().gap(6)).id("compact").size_full().px(6).items_center()
        .when(!row, (el) => el.items_start().py(6).min_h(0).overflow_y_scrollbar())
        .on_size_change((size, cx) => {
          const next = { width: Math.round(size.width), height: Math.round(size.height) };
          if (next.width === this.size?.width && next.height === this.size?.height) return;
          this.size = next;
          cx.notify();
        })
        .tooltip(sample.tooltip)
        .child(div().id("pane").text_size(11).flex_none().child(sample.pane))
        .child(metric("cpu.svg", sample.cpu))
        .child(metric("ram.svg", sample.memory));
      const agent = badge(sample.agent, t, row);
      return agent ? body.child(agent) : body;
    }
    // One icon row per reading; rows keep their height and a short panel scrolls.
    const line = (id, icon, value, tooltip, tint = t.foreground) => h_flex().id(id).w_full().h(26).flex_none().gap(8).items_center().tooltip(tooltip)
      .child(svg(icon).size(18).flex_none().text_color(tint))
      .child(div().text_size(15).truncate().child(value));
    const monitor = MONITOR[sample.status] ?? (sample.status === "running" ? null : ["circle-alert.svg", "#ff8080", false]);
    const header = h_flex().id("pane").w_full().h(28).flex_none().gap(8).items_center()
      .tooltip([`${sample.label} · ${sample.status_label}`, sample.message].filter(Boolean).join("\n"))
      .child(svg(KIND[sample.kind] ?? KIND.terminal).size(18).flex_none().text_color(t.foreground))
      .child(div().text_size(15).truncate().child(sample.pane))
      .when(Boolean(monitor), (el) => el.child(svg(monitor[0]).size(18).flex_none().text_color(monitor[1]).when(monitor[2], (icon) => icon.spin(2000))));
    const agent = sample.agent && Object.keys(sample.agent).length ? sample.agent : null;
    const rows = [header, ...sample.metrics.map((m) => line(`metric-${m.id}`, m.icon, m.value, m.tooltip))];
    // With nothing measured, why: the only sentence the panel shows, wrapped.
    if (sample.message && !sample.metrics.length) rows.push(div().id("message").w_full().flex_none().text_size(13).text_color(t.dim).child(sample.message));
    if (agent) {
      const name = agent.name || (agent.provider ? agent.provider[0].toUpperCase() + agent.provider.slice(1) : tr("Node"));
      rows.push(div().w_full().h(1).my(4).flex_none().bg(t.dim).opacity(0.3));
      rows.push(h_flex().id("agent-row").w_full().h(26).flex_none().gap(12).items_center()
        .child(badge(agent, t, true, `${name} · ${agent.label}\n${agent.session}`))
        .child(h_flex().id("queued").gap(6).items_center().flex_none().tooltip(agent.queued_label)
          .child(svg("mail.svg").size(18).flex_none().text_color(agent.queued > 0 ? t.foreground : t.dim))
          .child(div().text_size(15).text_color(agent.queued > 0 ? t.foreground : t.dim).child(String(agent.queued))))
        .when(Boolean(agent.detail), (el) => el.child(svg("triangle-alert.svg").id("detail").size(18).flex_none().text_color("#ffd078").tooltip(agent.detail))));
    }
    return v_flex().id("readout").size_full().min_h(0).px(6).py(4).gap(2).overflow_y_scrollbar().text_color(t.foreground).children(rows);
  }
}
