from graffitty_graph_protocol import Event, InputPort, Node, Output, OutputPort


node = Node("Uppercase", icon="Aa",
            inputs=[InputPort(id="in", name="Original", icon="↓")],
            outputs=[OutputPort(id="out", name="Uppercase", icon="✓", line_style="solid")])


@node.on("in")
def uppercase(message: Event):
    return Output(port="out", text=message.text.upper())

node.run()
