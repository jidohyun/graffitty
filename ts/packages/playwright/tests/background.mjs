import assert from "node:assert/strict";
import { access, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { setTimeout } from "node:timers/promises";
import { attach } from "@graffitty/playwright";

const directory = process.env.GRAFFITTY_PLAYWRIGHT_TEST_DIR;
async function waitFor(name) {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    try { await access(join(directory, name)); return; } catch {}
    await setTimeout(25);
  }
  throw new Error(`Host did not acknowledge ${name}`);
}

await writeFile(join(directory, "hide-chromium"), "");
let connection;
try {
  await waitFor("chromium-hidden.json");
  const hidden = JSON.parse(await readFile(join(directory, "chromium-hidden.json"), "utf8"));
  assert.notEqual(hidden.active, hidden.chromium_workspace);
  connection = await attach();
  assert.equal(await connection.page.evaluate(() => window.ownerProof), "graffitty-owned");
  const png = await connection.page.screenshot({
    path: join(directory, "background-page.png"), timeout: 10_000,
  });
  assert.equal(png.subarray(0, 8).toString("hex"), "89504e470d0a1a0a");
  assert.ok(png.readUInt32BE(16) > 0 && png.readUInt32BE(20) > 0);
  await connection.detach();
  connection = undefined;
  console.log("PASS: hidden workspace attachment keeps compositor live for screenshot and releases its lease");
} finally {
  await connection?.detach();
  await writeFile(join(directory, "restore-chromium"), "");
  await waitFor("chromium-restored.json");
}
