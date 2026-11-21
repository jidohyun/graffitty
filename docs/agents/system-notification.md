# Desktop notifications

Get a desktop alert when an agent finishes or a graph event arrives.

## Set it up

1. Run this in a Graffitty terminal:

   ```sh
   gft node system-notification --title 'Agent finished'
   ```

2. Connect an agent's **Turn completed** output, or another graph output, to **Notify**.
3. Keep the node running. Click an alert to bring its source pane into view.

Notifications start immediately, with system sound, even while Graffitty is focused.

## Change settings

Edit the form, then press **Ctrl+Enter** to apply and resume notifications.
Editing pauses incoming notifications.

| Setting | Use |
| --- | --- |
| Title, sound, urgency, icon | Defaults; incoming messages supply the body and may override title |
| Expiry | 3 seconds by default; `-1` uses OS default, `0` requests no automatic expiry |
| Buttons | One label per line; each opens the chosen pane |
| Replace ID | Blank creates new alerts; fixed value replaces this node's previous alert |

Use **Tab / Shift+Tab** between fields. **Enter / Space / F2** opens a dropdown;
arrows choose and **Enter** confirms. **Esc** cancels it. **Ctrl+C** stops the node.
The OS may hide banners before the requested expiry.

## Choose where a click takes you

**Focus target** selects the pane to bring into view:

| Setting | Pane |
| --- | --- |
| `original_sender` (default) | The agent or node that started the message |
| `previous_sender` | The node that sent directly to this notification node |
| `this_pane` | This notification node |

If the source pane has closed, Graffitty tries the next available sender, then
this node. Disable **Click fits pane** to leave focus unchanged.

## Save and reuse settings

Create a settings file and open it:

```sh
printf '{}\n' > notification.json
gft node system-notification --config notification.json
```

Edit the form and press **Ctrl+S** to save. Use the same command to load it later.

- Add `--edit` to start paused.
- Add `--headless` to run without the form.
- Add `--once` to exit after sending one notification.

## If no alert appears

Enable Graffitty notifications in your system settings and check Do Not Disturb.
The node's log shows sent messages and setting errors; **Sent** does not guarantee
the OS displayed a banner. Sounds, buttons, and banner duration depend on your OS.
