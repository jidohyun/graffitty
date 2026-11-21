# Graph Protocol: make your custom node

1. Open with Claude and an empty Payload Inspector side by side, connected by
   a solid Turn Completed wire. Type `What is HTTP?` and show Claude streaming
   its response while the inspector stays in view. The real completion payload
   arrives after the response finishes. Then move closer to the inspector and
   explain the session reference and last message while the JSON is readable.
2. Show the checked-in Python source with `bat node.py`. It declares one input,
   one output, an `@node.on("in")` handler, and `node.run()`.
3. Say “Run it” while typing **`uv run node.py`**. The SDK registers the node without an adapter wrapper.
4. Drag Manual Prompt's output to Uppercase's input, then Uppercase's output to
   Payload Inspector during “Connect the nodes.” All sending in this chain is automatic, so use solid wires.
5. Leave 1.5 seconds after the connection cue. Frame the prompt during that pause,
   then type and submit `hello graph` during “Send the message.” Show `HELLO GRAPH`
   in the inspector and verify its receipt.
   The generic nodes omit `provider`, and the Manual Prompt message has
   `sessions: []`; the introductory Claude completion retains its real session.

Park the pointer in empty workspace while explaining `bat node.py`, so it does
not cover `Node` or any other code. Regenerate changed narration as complete
sentences and transcribe the exported audio to check the actual spoken words.

The shared desktop recorder stages real programs and uses the existing pointer,
typing, physics and navigation helpers. Only the introductory agent's answer is
scripted; Python execution, Pydantic validation, graph routing and inspection are real.

```sh
python3 videos/main-demo/recording/systemone/record.py --chapter protocol \
  --output videos/main-demo/assets/takes/protocol-demo/my-take
python3 videos/main-demo/composition/append_protocol.py \
  videos/main-demo/assets/takes/protocol-demo/my-take
cd videos/main-demo/composition
python3 music.py --prepare
python3 render_protocol.py
python3 verify_delivery.py
```

Run and Connect should flow together: suppress typing-camera settling before the run command and reframe promptly when the real node registers. Before submitting “hello graph”, reveal the Manual Prompt → Uppercase → Payload Inspector route so the actual transfer animations stay visible; hold the route, then follow it into the inspector result. Footage stays at 1×.
