# Let an external command trigger your graph

Run a command that waits for a condition, then prints a message. This small GGP
node forwards its output once it succeeds. Connect **Watcher / done → Claude /
Receive**, and tell Claude what to do with the message beforehand.

For example, an email CLI can wait for new mail, then print the email:

```sh
uv run node.py email-cli wait
```

`email-cli wait` illustrates an external command you provide; it is not a bundled
mail client. The demo supplies a local fixture with a sample email, without
accessing an inbox. Claude is already instructed to summarize incoming email and
make a short podcast. The graph transports the command's actual output.

Use any command that writes the desired message to stdout and exits successfully.
Diagnostics belong on stderr. A failed command sends nothing. The watcher drains
stdout while waiting, keeps its GGP session alive, and emits only once. Its `done`
output is solid because the node sends automatically when the condition is met.
