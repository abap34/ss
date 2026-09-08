import { spawnSync } from "node:child_process";

// Terminate descendants before their parent disappears from the process table.
// External artifact tools may own process groups distinct from the CLI's group.
export function terminateProcessTree(pid) {
  if (!pid) return;
  if (process.platform === "win32") {
    spawnSync("taskkill", ["/pid", String(pid), "/t", "/f"], { timeout: 2_000, stdio: "ignore" });
    return;
  }
  const table = spawnSync("ps", ["-eo", "pid=,ppid="], {
    encoding: "utf8", timeout: 2_000, maxBuffer: 4 * 1024 * 1024,
  });
  const children = new Map();
  for (const line of (table.stdout ?? "").trim().split("\n")) {
    const [child, parent] = line.trim().split(/\s+/).map(Number);
    if (!Number.isInteger(child) || !Number.isInteger(parent) || child <= 0) continue;
    const siblings = children.get(parent) ?? [];
    siblings.push(child);
    children.set(parent, siblings);
  }
  const descendants = [pid];
  for (let index = 0; index < descendants.length; index++) {
    descendants.push(...(children.get(descendants[index]) ?? []));
  }
  for (const child of descendants.reverse()) {
    signal(-child);
    signal(child);
  }
}

function signal(pid) {
  try { process.kill(pid, "SIGKILL"); } catch (error) {
    if (error.code !== "ESRCH") throw error;
  }
}
