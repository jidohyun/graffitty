// The `graffitty-ui` module: elements and the View base class.
//
// Forked from gpui-kit (Apache-2.0, Longbridge): the builder vocabulary is
// kept, so a Herdr mod ports by changing its import lines.
//
// Nothing from GPUI is behind it; the host lays the tree out and each
// frontend paints it.
const ui = globalThis.__gft_ui;

export class View {
  constructor(props) {
    this.props = props;
  }
}

export const div = ui.div;
export const text = ui.text;
export const svg = ui.svg;
export const image = ui.image;
// gpui-component's two flex helpers, as every Herdr mod uses them.
export const h_flex = () => div().flex().flex_row().items_center();
export const v_flex = () => div().flex().flex_col();
