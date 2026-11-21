import { test, expect } from "@graffitty/playwright/test";

test("uses the existing page through standard Playwright fixtures", async ({ page, context, browser }) => {
  expect(await page.evaluate(() => (window as any).ownerProof)).toBe("graffitty-owned");
  expect(await page.evaluate(() => (window as any).retainedCount)).toBe(2);
  expect(context).toBe(page.context());
  expect(browser.contexts()).toContain(context);
  await expect(page.getByRole("heading", { name: "Attached to Graffitty" })).toBeVisible();
  await page.getByLabel("Name").fill("Playwright Test");
  await page.getByRole("button", { name: "Greet", exact: true }).click();
  await expect(page.locator("output")).toHaveText("Hello Playwright Test");
  await page.evaluate(() => (window as any).fixturePassed = true);
});
