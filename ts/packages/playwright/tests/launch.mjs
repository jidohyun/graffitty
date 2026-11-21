import assert from "node:assert/strict";
import { attach, launch } from "@graffitty/playwright";

// This fixture serves the frontend API, which has no pane.place; placement is
// covered against a real session server separately. Hidden skips placement.
const launched = await launch({ url: process.env.GRAFFITTY_PLAYWRIGHT_TEST_URL + "?launched=1", hidden: true });
try {
  assert.match(launched.handle, /^%\d+$/);
  assert.notEqual(launched.handle, process.env.GRAFFITTY_CHROMIUM);
  const { page } = launched;
  await page.waitForURL(/launched=1/);
  assert.equal(await page.title(), "Owned test page");
  await page.setContent("<button onclick=\"window.clicked=event.isTrusted\">Go</button>");
  await page.getByRole("button", { name: "Go" }).click();
  assert.equal(await page.evaluate(() => window.clicked), true);
  await assert.rejects(attach({ chromium: launched.handle }), /chromium_busy/);
} finally {
  await launched.close();
  await launched.close();
}
// The launched pane is gone, not merely detached.
await assert.rejects(attach({ chromium: launched.handle, timeout: 5000 }), /invalid_target/);
await assert.rejects(launch({ side: "left", position: { x: 1, y: 2 } }), /not both/);
console.log("PASS: launch creates a pane, waits for its page, drives it, and close removes it");
