// Stable OpenCode TUI entrypoint; implementation ships with gft.
import { binary, home } from "./config.js"
import { load } from "./loader.mjs"

export default {
  id: "graffitty",
  async setup(ctx) {
    if (!process.env.GRAFFITTY_SOCKET || !process.env.GRAFFITTY_TOKEN) return
    return (await load(binary, "opencode", "tui")).default(ctx, { home })
  },
}
