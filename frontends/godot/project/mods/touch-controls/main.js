// Faces of the touch controls: the key strip above the soft keyboard and the
// floating buttons.
//
// Graffitty keeps the controls themselves native (hit areas, holds, drags,
// the modifier latch, the round chrome and its shadow); this mod paints only
// what is on them, so the art can change without touching input.
//
// Props: every face gets { mode, palette }: the button's draw state (normal,
// hover, pressed, hover_pressed, disabled) and the color its own text or icon
// had in each.
//
// A strip key adds { part: "key", key? | label?, locked, locked_color }; a
// floating button adds { part: "button", button } with button "keyboard",
// "microphone", "stop" or "text_size" (and width, height).
import { View, div, svg, h_flex } from "graffitty-ui";
import { props } from "graffitty";

// Strip icons: 24×24 strokes, 2 px (3 px for a locked Shift).
//
// Copy and paste are Lucide's `copy` and `clipboard` (ISC,
// mods/icons/LUCIDE-LICENSE), drawn at 20 px so their full-bleed outlines
// match the weight of the arrows.
const KEY_PATHS = {
  copy: "M10 8h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H10a2 2 0 0 1-2-2V10a2 2 0 0 1 2-2zM4 16a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2",
  paste: "M9 2h6a1 1 0 0 1 1 1v2a1 1 0 0 1-1 1H9a1 1 0 0 1-1-1V3a1 1 0 0 1 1-1zM16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2",
  shift: "M8 21v-9H3l9-9 9 9h-5v9z",
  tab: "M3 12h13M11 7l5 5-5 5M21 5v14",
  left: "M20 12H4m6-6-6 6 6 6",
  right: "M4 12h16m-6-6 6 6-6 6",
  up: "M12 20V4m-6 6 6-6 6 6",
  down: "M12 4v16m-6-6 6 6 6-6",
};
const KEY_SIZES = { copy: 20, paste: 20 };
const KEY_LABELS = { escape: "Esc", ctrl: "Ctrl", alt: "Alt", home: "Home", end: "End", page_up: "PgUp", page_down: "PgDn" };
const keyIcon = (key, bold) =>
  `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="${KEY_PATHS[key]}" fill="none" stroke="white" stroke-width="${bold ? 3 : 2}" stroke-linecap="round" stroke-linejoin="round"/></svg>`;

const BUTTON_ICONS = { keyboard: "keyboard.svg", microphone: "microphone.svg", stop: "stop.svg" };

export default class TouchControls extends View {
  color(p) {
    const pressed = p.mode === "pressed" || p.mode === "hover_pressed";
    if (p.locked && pressed) return p.locked_color;
    return p.palette?.[p.mode] ?? p.palette?.normal ?? "#ffffff";
  }

  key(p) {
    const color = this.color(p);
    const face = h_flex().size_full().items_center().justify_center();
    if (p.key && KEY_PATHS[p.key]) return face.child(svg(keyIcon(p.key, p.key === "shift" && p.locked)).size(KEY_SIZES[p.key] ?? 24).text_color(color));
    const label = p.label ?? KEY_LABELS[p.key] ?? "";
    return face.child(div().whitespace_nowrap().text_size(14).text_color(color)
      .when(Boolean(p.locked), (el) => el.font_extrabold()).child(label));
  }

  // Match the native text-size pill. Place − at one quarter and + at
  // three quarters, with a faint divider in the center.
  //
  // Use a 2 px bar with a 1 px fringe at 20% on the sides and 60% at the ends.
  // Split the 1 px divider across two 10% columns and soften its end pixels.
  textSize(color, width, height) {
    const rect = (x, y, w, h, c) => div().absolute().left(x).top(y).w(w).h(h).bg(c);
    const core = color + "ff", end = color + "99", side = color + "33";
    const horizontal = (cx, cy) => [
      rect(cx - 8, cy - 2, 16, 1, side), rect(cx - 8, cy + 1, 16, 1, side),
      rect(cx - 8, cy - 1, 1, 2, end), rect(cx + 7, cy - 1, 1, 2, end),
      rect(cx - 7, cy - 1, 14, 2, core),
    ];
    const vertical = (cx, cy) => [
      rect(cx - 2, cy - 8, 1, 16, side), rect(cx + 1, cy - 8, 1, 16, side),
      rect(cx - 1, cy - 8, 2, 1, end), rect(cx - 1, cy + 7, 2, 1, end),
      rect(cx - 1, cy - 7, 2, 14, core),
    ];
    const left = Math.round(width * 0.25), right = Math.round(width * 0.75), mid = Math.round(height / 2);
    const divider = Math.round(width / 2) - 1, length = Math.max(0, height - 31);
    // Fringes first, then cores, so crossing bars never tint each other.
    const plus = [...horizontal(right, mid), ...vertical(right, mid)];
    return div().relative().size_full().children([
      ...horizontal(left, mid),
      ...plus.filter((_, i) => i % 5 !== 4),
      ...plus.filter((_, i) => i % 5 === 4),
      rect(divider, 14, 2, 1, "#ffffff09"), rect(divider, 15 + length, 2, 1, "#ffffff09"),
      rect(divider, 15, 2, length, "#ffffff19"),
    ]);
  }

  render() {
    const p = props();
    if (p.part === "key") return this.key(p);
    // The pill draws in one fixed color in every state, as it always has.
    if (p.button === "text_size") return this.textSize("#e1e7f2", p.width ?? 104, p.height ?? 52);
    return h_flex().size_full().items_center().justify_center()
      .child(svg(BUTTON_ICONS[p.button] ?? BUTTON_ICONS.keyboard).size(24).text_color(this.color(p)));
  }
}
