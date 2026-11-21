import assert from "node:assert/strict";
import { attach } from "@graffitty/playwright";

await assert.rejects(attach({ chromium: "%999999" }), /invalid_target/);
await assert.rejects(attach({ token: "invalid" }), /unauthorized/);
await assert.rejects(attach({ token: process.env.GRAFFITTY_FOREIGN_TEST_TOKEN }), /forbidden/);
const connection = await attach();
try {
  const { page, chromium } = connection;
  assert.equal(await page.evaluate(() => window.ownerProof), "graffitty-owned");
  await assert.rejects(attach(), /chromium_busy/);
  await page.evaluate(() => {
    sessionStorage.setItem("owner", window.ownerProof);
    sessionStorage.setItem("count", String(window.retainedCount));
  });
  await page.goto(process.env.GRAFFITTY_PLAYWRIGHT_TEST_URL + "?navigation=playwright");
  assert.equal(await page.evaluate(() => sessionStorage.getItem("owner")), "graffitty-owned");
  await page.evaluate(() => {
    window.ownerProof = sessionStorage.getItem("owner");
    window.retainedCount = Number(sessionStorage.getItem("count"));
  });
  await page.setContent(`<title>Graffitty Playwright attachment</title>
    <style>body{background:#182b36;color:white;font:24px system-ui;padding:48px}input,button{font:inherit}</style>
    <h1>Attached to Graffitty</h1><label>Name <input></label>
    <button onclick="document.querySelector('output').textContent='Hello '+document.querySelector('input').value;window.trusted=event.isTrusted">Greet</button>
    <output></output><div id="shadow"></div><iframe srcdoc="<label>Frame <input></label>"></iframe>`);
  await page.getByLabel("Name").fill(process.release.name === "node" ? "Node or Bun" : "Bun");
  await page.getByRole("button", { name: "Greet", exact: true }).click();
  await page.waitForFunction(() => document.querySelector("output").textContent.startsWith("Hello"));
  assert.equal(await page.evaluate(() => window.trusted), true);
  await page.frameLocator("iframe").getByLabel("Frame").fill("nested");
  assert.equal(await page.frameLocator("iframe").getByLabel("Frame").inputValue(), "nested");
  await page.evaluate(() => document.querySelector("#shadow").attachShadow({ mode: "open" }).innerHTML = "<button>Shadow</button>");
  await page.getByRole("button", { name: "Shadow", exact: true }).click();
  await page.screenshot({ path: process.env.GRAFFITTY_PLAYWRIGHT_TEST_DIR + "/page.png" });
  await assert.rejects(chromium.newContext(), /Graffitty owns/);
  await page.evaluate(() => window.retainedCount++);
} finally {
  await connection.detach();
  await connection.detach();
}
const reconnected = await attach();
assert.equal(await reconnected.page.evaluate(() => window.ownerProof), "graffitty-owned");
await reconnected.detach();
console.log("PASS: attach, identity, locators, trusted click, iframe, shadow DOM, screenshot, lease exclusivity, reconnect");
