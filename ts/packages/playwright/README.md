# @graffitty/playwright

Drive Graffitty's built-in Chromium panes with Playwright. Your page code is
ordinary Playwright; only how you get the browser changes.

`launch()` creates a Chromium pane beside your terminal and connects to it.
`attach()` connects to a pane that already exists. Neither downloads or starts
a separate Chrome: the page stays visible in your Graffitty workspace.

## Installation

Requires **Node.js 22+** or **Bun**, **Playwright 1.60+**, and a running
**Graffitty** host on macOS. This package connects to Graffitty; it is not a
standalone browser.

```sh
npm install -D @graffitty/playwright @playwright/test
```

## Quick start

Save this as `example.mjs`:

```js
import { launch } from "@graffitty/playwright";

const browser = await launch({ url: "https://example.com", side: "right" });
try {
  await browser.page.getByRole("link").first().click();
  await browser.page.screenshot({ path: "example.png" });
} finally {
  await browser.close();
}
```

Run it **inside a Graffitty terminal pane**:

```sh
node example.mjs   # or: bun example.mjs
```

A Chromium pane opens to the right of your terminal, runs the script, and closes.
Graffitty supplies `GRAFFITTY_SOCKET` and `GRAFFITTY_TOKEN` to the pane; the
script will not work in an unrelated terminal. Keep the token private.

## Launching a pane

`launch(options)` returns `{ chromium, context, page, handle, detach(), close() }`.
`chromium`, `context` and `page` are real Playwright objects. `close()` removes
the pane; `detach()` disconnects but leaves it open.

| Option | Meaning |
|---|---|
| `side` | `"left"`, `"right"`, `"above"` or `"below"` of a pane. Default `"right"`. |
| `of` | The pane `side` refers to (`"%3"` or `":1.2"`). Default: your terminal. |
| `position`, `size` | `{ x, y }` and `{ width, height }` in workspace pixels; floating tabs only. |
| `hidden` | Create it hidden; the terminal's Chromium button reveals it. |
| `url` | Initial page: `http(s)://` or `about:blank` (default). |
| `profile`, `profileTemplate` | Persistent profile directory, or one copied into a temporary profile. |
| `timeout` | Milliseconds for each step. Default `20000`. |

Options are validated before anything is created. If placement or connecting
fails, the new pane is removed again. `handle` is the pane's `%N` ID, usable
with `gft chromium ... --target`.

## Attaching to an existing pane

```js
import { attach } from "@graffitty/playwright";

const { page, detach } = await attach({ chromium: "%3" }); // or set GRAFFITTY_CHROMIUM=%3
try {
  await page.goto("http://localhost:3000");
} finally {
  await detach(); // the pane and its page stay open
}
```

Find pane IDs with `gft chromium list`. Only panes in your own workspace can be
attached, and one connection is allowed per pane at a time.

## Playwright Test

Import `test` and `expect` from this package instead of `@playwright/test`.
Test bodies stay the same:

```ts
import { test, expect } from "@graffitty/playwright/test";

test.use({ graffittyLaunch: { side: "below" } });

test("sign in", async ({ page }) => {
  await page.goto("http://localhost:3000");
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page.getByText("Welcome")).toBeVisible();
});
```

```sh
npx playwright test --workers=1
```

Each worker launches its own pane and closes it afterwards. To reuse an existing
pane instead, set `GRAFFITTY_CHROMIUM=%3` or `test.use({ graffittyChromium: "%3" })`.
Use one worker and a Chromium project: WebKit and Firefox cannot attach.

## Behavior and limits

- Tests share one browser context and page, so cookies, storage and navigation
  persist between tests. Options such as `storageState`, `baseURL` and `viewport`
  are not applied automatically; use absolute URLs in `page.goto()`.
- Creating or closing browser contexts and `browser.close()` are not supported.
  Closing a page through Playwright does close that page.
- Downloads, popups, cross-origin frames, tracing, video and request
  interception are not supported.
- Screenshots work even when the pane's tab is not visible.
- Connections go through Graffitty's authenticated local socket; Chromium has no
  public debugging port. The connection URL is a temporary credential: keep it
  private. It is redacted from error messages.
- macOS only for now.

## Development

From a repository checkout:

```sh
cd ts/packages/playwright
npm ci
npm test              # build and unit tests
npm run test:e2e      # real Graffitty + Chromium on macOS; requires godot, node and bun
```

To try a local build in another project, run `npm run build`, then
`npm install -D <path-to-checkout>/ts/packages/playwright`. After rebuilding
the Chromium host, restart Graffitty and create a new pane.

## License

Apache-2.0.
