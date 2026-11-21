# Native notification activation

Run `gft node system-notification` in a pane and connect an output to Notify.
Check the Ratatui defaults, edit/apply with Ctrl+Enter, and save with Ctrl+S using
--config. Send an event and check the timestamped title/body log and native OS notification. Switch tabs or minimize
Graffitty, then click: the original graph sender must be selected and fitted in its
current window. Test a relay chain, close the origin to check fallback to the
previous sender, and choose `this_pane` to focus the notification node.
Repeated clicks stay fitted.
Repeat with `printf '\033]9;Task finished\007'` in an ordinary terminal.
Dismiss a notification and verify focus stays unchanged. Close the emitting pane
before clicking and verify no replacement pane or crash. Exit the node after
emission and verify its notification can still focus its existing pane.

Replay: `replays/system-notification.gd`, in Flat and Flat 2D. The replay exercises
real terminal bytes, OSC parsing, the node, asynchronous helper responses, and
pane navigation, OSC 99 capability/alive queries, numbered button replies, and
close reports; only the native desktop banner is substituted. Also verify real
banners and clicks on macOS, Windows, and Linux with notifications enabled.
