// graffitty-pi
// Stable Pi entrypoint. Updating gft updates the implementation; /reload loads it.
import { Type } from "@earendil-works/pi-ai";
import { binary, home } from "./config.js";
import { load } from "./loader.mjs";

export default async function (pi) {
  if (!process.env.GRAFFITTY_SOCKET || !process.env.GRAFFITTY_TOKEN) return;
  const runtime = await load(binary, "pi", "main");
  return runtime.default(pi, { home, Type });
}
