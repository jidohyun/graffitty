# JavaScript mods

Create a panel with JavaScript. The example below shows the number of agents
and updates when that number changes.

## 1. Save the script

Beside `client.toml`, create `mods/agent-count/panel.js`:

```js
import { View, h_flex } from "graffitty-ui";
import { agents, theme, tr } from "graffitty";

export default class AgentCount extends View {
  render() {
    return h_flex().size_full().px(14).items_center()
      .text_color(theme().foreground)
      .child(`${agents().length} ${tr("agents")}`);
  }
}
```

Use `theme()` for colors and `tr()` for visible strings.
Shipped mods need translations for every UI string.

## 2. Register the panel

In `client.toml`:

```toml
[mods.agent-count]
entry = "./mods/agent-count/panel.js"
title = "Agents"
host = "panel"
place = "left"
size = 280
open = true
```

The entry path starts beside the TOML file. Restart the frontend after loading
the registration and script. Check its shutdown behavior before restarting if
you have live sessions.

## 3. Check the result

The panel should appear on the left and show your current agent count.
Click its title to fold it; drag the title to move or dock it.
Saved placement and visibility take precedence on later launches.

## Extend it

Live data reads update automatically. Call `cx.notify()` after changing your own
state; avoid polling. Mods build native UI and cannot access files or the Godot scene tree.

See [Mod API reference](mods-reference.md) for hosts, elements, actions,
built-in overrides, persistent state, and panel backgrounds.
