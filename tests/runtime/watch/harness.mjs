import { spawn } from "node:child_process";
import { ssBin } from "../harness.mjs";

export const settle = () => new Promise((resolve) => setTimeout(resolve, 300));

export class WatchProcess {
  log = "";

  constructor(cwd, args) {
    this.child = spawn(ssBin, ["watch", ...args, "--interval-ms", "50"], {
      cwd, detached: true, stdio: ["ignore", "pipe", "pipe"],
    });
    for (const stream of [this.child.stdout, this.child.stderr]) {
      stream.setEncoding("utf8");
      stream.on("data", (chunk) => { this.log += chunk; });
    }
    this.exit = new Promise((resolve, reject) => {
      this.child.on("error", reject);
      this.child.on("close", (code, signal) => resolve({ code, signal }));
    });
    this.exit.catch(() => {});
    this.deadline = setTimeout(() => this.kill(), 30_000);
  }

  occurrences(text) {
    return this.log.split(text).length - 1;
  }

  async waitFor(predicate, description) {
    const limit = Date.now() + 5_000;
    while (Date.now() < limit) {
      if (await predicate()) return;
      if (this.child.exitCode !== null || this.child.signalCode !== null) break;
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    throw new Error(`Timed out waiting for ${description}:\n${this.log}`);
  }

  kill() {
    if (!this.child.pid) return;
    try { process.kill(-this.child.pid, "SIGKILL"); } catch (error) {
      if (error.code !== "ESRCH") throw error;
    }
  }

  async close() {
    clearTimeout(this.deadline);
    this.kill();
    await this.exit;
  }
}
