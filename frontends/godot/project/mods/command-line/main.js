import { View, div, h_flex } from "graffitty-ui";
import { props } from "graffitty";

export default class CommandLine extends View {
  render() {
    const p = props();
    const label = h_flex().w(p.address_width).flex_none().overflow_hidden();
    const matches = new Set(p.indices ?? []);
    let run = "", marked = false;
    const flush = () => { if (run) label.child(div().whitespace_nowrap().text_color(marked ? "#ffd078" : p.foreground).child(run)); run = ""; };
    Array.from(p.label ?? "").forEach((c, i) => { const next = matches.has(i); if (next !== marked) flush(); marked = next; run += c; });
    flush();
    return h_flex().size_full().gap(24).items_center().text_size(p.font_size).text_color(p.foreground)
      .child(label)
      .child(div().flex_1().min_w(0).truncate().child(p.title ?? ""))
      .child(div().w(p.detail_width).flex_none().truncate().text_color(p.dim).child(p.detail ?? ""));
  }
}
