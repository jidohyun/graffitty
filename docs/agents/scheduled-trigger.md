# Schedule a trigger

Run `gft node scheduled-trigger`, connect **Trigger** to a receiver, and choose
one schedule below. Click **Start** and keep the node running.

## Run once after a delay

Choose **In / After** and enter `30s`, `5m`, or `1h`.
The countdown starts on Start. Editing pauses it; starting again resets it.

## Run at a clock time

```sh
gft node scheduled-trigger --at "18:00" --text "Check the build" --headless
```

A once-only clock time uses its next occurrence. Use an explicit timezone in
shared timestamps to avoid different interpretations.

## Repeat within a window

```sh
gft node scheduled-trigger --every 5m --from "09:00" --until "18:00" --headless
```

Bare window times mean today in local time. The start is included and the end
excluded: every minute for 30 minutes produces 30 triggers.

## Sleep, failures, and recovery

| Event | Result |
| --- | --- |
| Device sleeps through intervals | One combined trigger after waking |
| Send fails or output is unwired | Schedule pauses; no silent retry |
| Checkpoint restores a schedule | Resolved times remain; fired one-shots do not repeat |

## Stop a loop at a deadline

Put a Filter on the return connection; connect **Matched** to the next iteration:

```sh
gft node filter --before "18:00" --headless
```

At the deadline it acknowledges and drops incoming events. A running turn may
finish. The deadline resolves once at startup or Apply, not again next morning.
For ordinary conditions, an unwired Unmatched output is an error; a time window
is the explicit way to stop delivery.
