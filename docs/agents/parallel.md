# Wait for parallel work

Use **Parallel** to collect one result from every connected branch, then send
one combined message to the next agent. It joins work already running;
it does not start the tasks.

## Connect the branches

1. Run this in a Graffitty terminal:

   ```sh
   gft node parallel
   ```

2. Connect each agent's **Turn completed** output to **Wait for all branches**.
3. Connect **Combined** to the next agent's **Receive** input.
4. Start the upstream tasks. Keep Parallel running while they finish.

The checklist shows which branches have arrived. **Combined** sends automatically
when every branch has a result. Muted and Read-only connections do not count.

## What the next agent receives

The combined message includes each branch's text and its original event data.
Session references require Read access.

Results are paired **in arrival order per connection**, not by task or run ID.
A fast branch's second result waits for the next round. Use separate Parallel
nodes for unrelated jobs.

## Watch progress or inspect messages

| Control | Action |
| --- | --- |
| **L** or **Show log / Show image** | Switch views |
| **Mouse wheel / arrows / Page Up / Page Down** | Scroll the log |
| **Home / End** | First entry / follow latest |
| **Ctrl+C** | Stop the node |

**IN** shows branch messages; **OUT** shows the queued result. Views do not pause delivery.

## If it keeps waiting

| Situation | Action |
| --- | --- |
| A branch is unchecked | Finish or trigger that branch |
| Progress is 100% | Connect **Combined** to a receiver |
| The node stops after a wiring change | Restore the wiring, or restart with the new connections |
| A Filter drops a branch's event | Change the workflow: Parallel needs one event from every branch |

Connections are fixed after the first result arrives for a round. Wait for the
round to finish before changing or muting its branches.

Pending inputs stay queued after an error. A crash after sending the combined
result can repeat it on restart; custom receivers can check `inputs[].event_id`.

## Command options

```sh
gft node parallel --name "Review join"
gft node parallel --once
```

`--once` exits after one combined result is sent.
