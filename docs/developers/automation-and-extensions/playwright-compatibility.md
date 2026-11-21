# Playwright attachment

`@graffitty/playwright` lives at `ts/packages/playwright/`. It attaches to an
existing embedded Chromium under Node or Bun and includes fixtures for
ordinary Playwright Test suites. The package is local; it has not been published
to npm.

## Build the local package

Build the native chromium host with `bash apps/server/chromium/build.sh`, then run
`npm ci && npm run build` inside `ts/packages/playwright/`. Save a checkpoint and use `gft server restart`, then
open a new browser so it uses the rebuilt host. Install the local package into
your test project:

```sh
npm install -D /absolute/path/to/graffitty/ts/packages/playwright @playwright/test
```

## Attach to an existing page

Use `gft chromium list` from the owning terminal to find the chromium ID.
That terminal already inherits the workspace socket and capability.

```ts
import { attach } from "@graffitty/playwright";

const connection = await attach({ chromium: "%3" });
try {
  await connection.page.goto("http://localhost:3000");
  await connection.page.getByRole("button", { name: "Sign in" }).click();
} finally {
  await connection.detach();
}
```

## Use the test fixture

For existing test suites, import `test` and `expect` from
`@graffitty/playwright/test` and set `workers: 1`. Run with an explicit target:

```sh
GRAFFITTY_CHROMIUM=%3 bunx playwright test --workers=1
```

The fixtures return the existing primary page, context and chromium. They do not
create a clean context per test; state persists and retries do not reset it.
Chromium-launch calls in custom tests must be replaced with `attach()`. WebKit and
Firefox projects cannot attach to our Chromium. The package README documents
all options and the existing-page fixture behavior.

## Limits

This first attachment implementation is macOS-only. Downloads, popups,
cross-origin frames, interception, tracing/video, and crash recovery are not yet
covered; CDP attachment does not imply full Playwright compatibility. Existing
context options are not reset to test-runner defaults.

The bundled CEF build crashed when `setContent` created a `srcdoc` iframe from an
opaque `about:blank` origin. Navigate to your HTTP application before frame tests;
the E2E uses a real HTTP origin. Existing CEF allocator, chromium-info timeout and
shutdown waitpid warnings also remain visible on passing runs.

See [lease security and recorded verification](../internals/playwright-attachment.md).
