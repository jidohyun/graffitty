import { test as base, expect } from "@playwright/test";
import { attach, launch, type Attachment, type LaunchOptions } from "./index.js";

type Workers = {
  /** Existing chromium (%N); empty launches a new pane for this worker. */
  graffittyChromium: string;
  /** Where a launched pane goes, its URL and profile. */
  graffittyLaunch: LaunchOptions;
  graffittyConnection: Attachment;
};

/**
 * Use `workers: 1` with the Graffitty page fixture.
 *
 * - Set `GRAFFITTY_CHROMIUM` or `graffittyChromium` to reuse an existing pane.
 * - Otherwise, the fixture opens a pane using `graffittyLaunch` and closes
 *   it when the worker finishes.
 *
 * The browser context and page state persist between tests in either case.
 */
export const test = base.extend<{}, Workers>({
  graffittyChromium: [process.env.GRAFFITTY_CHROMIUM ?? "", { option: true, scope: "worker" }],
  graffittyLaunch: [{}, { option: true, scope: "worker" }],
  graffittyConnection: [async ({ graffittyChromium, graffittyLaunch, browserName }, use, workerInfo) => {
    if (browserName !== "chromium")
      throw new Error("Graffitty embeds Chromium; WebKit and Firefox projects cannot attach");
    if (workerInfo.config.workers !== 1)
      throw new Error("An existing Graffitty page requires workers: 1");
    if (graffittyChromium) {
      const connection = await attach({ chromium: graffittyChromium });
      try {
        await use(connection);
      } finally {
        await connection.detach();
      }
      return;
    }
    const launched = await launch(graffittyLaunch);
    try {
      await use(launched);
    } finally {
      await launched.close();
    }
  }, { scope: "worker" }],
  browser: [async ({ graffittyConnection }, use) => {
    await use(graffittyConnection.chromium);
  }, { scope: "worker" }],
  context: async ({ graffittyConnection }, use) => {
    await use(graffittyConnection.context);
  },
  page: async ({ graffittyConnection }, use) => {
    await use(graffittyConnection.page);
  },
});

export { expect };
export type { AttachOptions, Attachment, LaunchOptions, Launched, Side } from "./index.js";
