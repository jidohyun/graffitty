// Pane chrome, in Herdr's defaults/mods/pane/main.js shape (Apache-2.0).
//
// Graffitty keeps its existing visual: 20px title, 24px actions, 28px splits,
// transparent background, hover-only actions, and title + close when compact
// (title only on touch, where a zoomed-out × is a stray-tap hazard).
//
// The host projects the title independently so it remains readable at low
// zoom.
import { View, div, svg, h_flex } from "graffitty-ui";
import { props, run, tr } from "graffitty";

const split = (down) => `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><g fill="none" stroke="white" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2"/>${down ? '<path d="M3 12h18"/>' : '<path d="M12 3v18"/>'}</g></svg>`;
const ACTIONS = [
  { id: "filetree", icon: "folder-tree.svg", size: 24 },
  { id: "chromium", icon: "chromium.svg", size: 24 },
  { id: "split_right", icon: split(false), size: 28 },
  { id: "split_down", icon: split(true), size: 28 },
  { id: "close", icon: "x.svg", size: 24 },
];

export default class PaneHeader extends View {
  button(p, action) {
    const blue = action.id === "filetree" && p.filetree_open;
    const color = blue ? "#4da3ff" : p.icon_color;
    return div().id(action.id).size(action.size).flex_none().rounded(3).text_color(color)
      .when(!p.touch, el => el.hover(s => s.bg("#ffffff1a").text_color(action.id === "close" ? "#e5484d" : color)))
      .active(s => s.bg(blue ? (p.touch ? "#ffffff00" : "#ffffff1a") : "#ffffff29")
        .text_color(action.id === "close" && !p.touch ? "#e5484d" : color))
      .tooltip(p.touch ? "" : tr(p.tooltips[action.id]))
      .on_click((_event, cx) => {
        cx.stop_propagation();
        run("PaneHeaderAction", { action: action.id });
      })
      .child(svg(action.icon).size(action.size));
  }

  render() {
    const p = props();
    if (p.part === "title") {
      return h_flex().size_full().overflow_hidden().text_size(p.font_size).text_color(p.color)
        .child(div().min_w(0).w_full().truncate().child(p.text ?? ""));
    }
    const gap = p.gap ?? 4;
    const full = 24 + 64 + (p.terminal ? 24 + 24 + 28 + 28 + gap * 4 : 0);
    const narrow = p.compact || p.width < full;
    const shown = !narrow && (p.hovered || p.touch);
    // Compact means the view is zoomed out.
    //
    // On touch a stray tap on a tiny × closes a pane, so the zoomed-out
    // header keeps only its title; a merely narrow pane at normal zoom still
    // shows its ×.
    const close = p.compact ? p.compact_close && !p.touch : shown || narrow;
    let actions = ACTIONS.filter(a => a.id === "close" ? close : p.terminal && shown);
    let agent = !narrow && !p.status_strip && Boolean(p.status);
    const width = () => 60 + actions.reduce((sum, a) => sum + a.size + gap, 0) + (agent ? 20 + gap : 0);
    // Same all-or-nothing toolbar and overflow removal order as native chrome.
    for (const id of ["filetree", "chromium", "split_down", "split_right", "agent", "close"]) {
      if (width() <= p.width) break;
      if (id === "agent") agent = false;
      else actions = actions.filter(a => a.id !== id);
    }
    const root = h_flex().size_full().gap(gap);
    // The independent projected title paints this slot; it also supplies the
    // drag hit region. It never covers a button's hit region.
    root.child(div().id("title").flex_1().min_w(60).h_full());
    if (agent) root.child(svg("circle-pause.svg").id("agent").size(20).flex_none().text_color("#ffd078")
      .tooltip(p.status_label ?? ""));
    for (const action of actions) root.child(this.button(p, action));
    return root;
  }
}
