// Stable OpenCode server entrypoint. The runtime binds each call to its TUI.
import { binary, home } from "./config.js"
import { load } from "./loader.mjs"

export default {
  id: "graffitty",
  async setup(ctx) {
    return (await load(binary, "opencode", "server")).default(ctx, { home })
  },
}
