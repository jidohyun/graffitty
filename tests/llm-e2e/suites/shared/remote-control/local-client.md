# Local remote-control client

1. Start a server with two terminal tabs; leave the desktop on the first tab.
2. Connect a separate Godot client and select the second tab independently.
3. Send commands, control keys, colored output, Korean text and combining characters.
4. Explicitly resize the remote terminal to 65 × 18. Verify the server and a
   second observer have the same grid size.
5. Disconnect, produce output through the second observer, and reconnect.
   The first client catches up without changing its selected tab.
6. Reject a client with an invalid token before exposing any terminal state.
7. Desktop tab/focus and shell PIDs remain unchanged throughout.
