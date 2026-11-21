import { View, div, svg, image, h_flex, v_flex } from "graffitty-ui";
import { props, tr } from "graffitty";

export default class TabMenu extends View {
  render() {
    const p = props(), item = p.item;
    if (!item) return div();
    const pane = item.kind === "pane";
    const prefix = pane ? `↳ ${item.ordinal}.${item.pane_ordinal} · ` : `${item.ordinal}: `;
    const title = h_flex().min_w(0).overflow_hidden().text_size(p.font_size + 2).child(prefix);
    const matches = new Set(item.match_indices ?? []);
    // Split into runs, not individual glyphs: retain shaping and kerning.
    let run = "", marked = false;
    const flush = () => { if (run) title.child(div().whitespace_nowrap().text_color(marked ? "#ffd078" : p.foreground).child(run)); run = ""; };
    Array.from(item.title).forEach((c, i) => { const next = matches.has(i); if (next !== marked) flush(); marked = next; run += c; });
    flush();
    const root = v_flex().size_full().px(pane ? 30 : 10).py(8).gap(4).rounded(4)
      .bg(p.selected ? "#ffffff1f" : p.hover ? "#ffffff0f" : p.background).text_color(p.foreground).child(title);
    if (pane || item.show_details === false) return root;
    const detail = h_flex().gap(16).items_center().text_size(Math.max(10, p.font_size - 3));
    const metric = (icon, value, tooltip) => h_flex().gap(5).items_center().tooltip(tooltip)
      .child(svg(icon).size(14)).child(String(value));
    detail.child(metric("layout-template.svg", item.pane_count ?? 0, item.pane_tooltip ?? "").id("panes"));
    detail.child(metric("cpu.svg", item.resources?.cpu ?? "—", tr("Total CPU usage")));
    detail.child(metric("ram.svg", item.resources?.ram ?? "—", tr("Total RAM usage")));
    for (const badge of p.badges ?? []) {
      const group = h_flex().gap(4).items_center().tooltip(badge.tooltip);
      if (badge.logo) group.child((badge.logo.endsWith(".png") || badge.provider === "pi" ? image(badge.logo) : svg(badge.logo)).size(16).when(badge.status === "offline", icon => icon.grayscale().opacity(0.55)));
      else group.child(badge.name);
      if (badge.symbol) group.child(badge.symbol);
      group.child(svg(badge.icon).size(16).text_color(badge.tint).when(badge.spinning, el => el.spin(2000)));
      if (badge.count > 1) group.child(String(badge.count));
      detail.child(group);
    }
    return root.child(detail);
  }
}
