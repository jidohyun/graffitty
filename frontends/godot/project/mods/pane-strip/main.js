// The pane strip: the small card the workspace draws beside each pane when
// its header gets too small to read.
//
// Pane id, CPU and memory in aligned icon/value columns, and the agent badge
// (logo, status glyph, elapsed time).
//
// Host "pane": one copy per pane, sized to its content and placed by the
// workspace. `pane()` is this pane's data; the host publishes it per pane.
//
// Written for Graffitty in the shape of a herdr-app mod (Apache-2.0).

import { View, div, svg, image, h_flex, v_flex } from "graffitty-ui";
import { pane, theme } from "graffitty";

function duration(seconds) {
  const m = Math.floor(Math.max(seconds, 0) / 60);
  if (m < 1) return "<1m";
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  return h < 24 ? `${h}h` : `${Math.floor(h / 24)}d`;
}

export default class PaneStrip extends View {
  init(_props, cx) {
    // Elapsed times are whole minutes; refresh them every 30 s, as the Agents mod does.
    cx.timer.every(30000, (cx) => cx.notify());
  }

  badge(t, agent) {
    const since = agent.since != null && agent.since >= 0 ? duration(Date.now() / 1000 - agent.since) : null;
    return h_flex().id("agent").gap(6).items_center().flex_none().tooltip(agent.tooltip)
      .when(Boolean(agent.logo), (el) => el.child((agent.logo.endsWith(".png") || agent.provider === "pi"
        ? image(agent.logo) : svg(agent.logo).text_color("#ffffff"))
        .size(20).flex_none().when(agent.status === "offline", icon => icon.grayscale().opacity(0.55))))
      .when(Boolean(agent.symbol), (el) => el.child(div().text_size(12).child(agent.symbol)))
      .when(!agent.logo, (el) => el.child(div().id("agent-name").text_size(12).whitespace_nowrap().child(agent.name)))
      .child(svg(agent.icon).id("agent-status").size(20).flex_none().text_color(agent.tint).when(agent.spinning, (el) => el.spin(2000)))
      .when(Boolean(since), (el) => el.child(div().text_size(11).text_color(t.dim).child(since)));
  }

  render() {
    const t = theme();
    const p = pane();
    if (!p) return div();
    // CPU and RAM on their own rows with the icon and value columns aligned:
    // the same fixed icon slot in each row, and the value is never wrapped.
    const metric = (icon, id, value) => h_flex().gap(6).items_center().h(18)
      .child(svg(icon).id(id + "-icon").size(16).flex_none().text_color("#ffffff"))
      .child(div().id(id).text_size(12).whitespace_nowrap().child(value));
    return v_flex().px(6).py(3).gap(2).rounded(3).bg("#090b0f80").text_color(t.foreground)
      .child(div().id("label").text_size(12).whitespace_nowrap().child(p.label))
      .child(metric("cpu.svg", "cpu", p.cpu))
      .child(metric("ram.svg", "memory", p.memory))
      .when(Boolean(p.agent), (el) => el.child(this.badge(t, p.agent)));
  }
}
