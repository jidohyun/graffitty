# StatusStrip event updates

Open Overview and the resource monitor. Feed resource samples and Codex/Claude
lifecycle events, then assert the visible text and agent badge before yielding a
frame. A 200 ms polling implementation must fail. Import a remote graph snapshot
and detach it; each must update immediately. Hidden strips retain the latest
sample. Replacing a session monitor disconnects its previous sample publisher.

The replay uses the production workspace, graph and resource-monitor signals;
controlled samples avoid CPU timing noise. Unexpected diagnostics fail the case.
