// Stable bootstrap. Runtime implementation ships with gft and runs in this host.
import { execFile } from "node:child_process";

export async function load(binary, provider, entry) {
  const source = await new Promise((resolve, reject) => {
    execFile(binary, ["internal", "agent-hook-integrate", "runtime", "--provider", provider, "--runtime", entry],
      { timeout: 10000, maxBuffer: 1024 * 1024, windowsHide: true },
      (error, stdout, stderr) => error ? reject(new Error(stderr.trim() || error.message)) : resolve(stdout));
  });
  // The installed gft is the trusted source. No downloaded code or dependency
  // resolution is involved; a source change also changes the module cache key.
  return import(`data:text/javascript;base64,${Buffer.from(source).toString("base64")}`);
}
