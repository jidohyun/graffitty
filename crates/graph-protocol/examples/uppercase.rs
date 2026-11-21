use graffitty_graph_protocol::{InputPort, LineStyle, Node, Output, OutputPort, Result};

fn main() -> Result<()> {
    let mut node = Node::new("Uppercase")
        .icon("Aa")
        .input(InputPort::new("in").name("Original").icon("↓"))
        .output(
            OutputPort::new("out")
                .name("Uppercase")
                .icon("✓")
                .line_style(LineStyle::Solid),
        );
    node.on("in", |message| {
        Ok(Output::text("out", message.text.to_uppercase()))
    })?;
    node.run()
}
