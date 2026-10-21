import { ChildProcess, execFile, spawn } from "child_process";

const terminationTimeoutMs = 2_000;

// Keep process ownership here: the bundled language client's Unix termination
// helper is a separate shell script, which is absent from our extension bundle.
export class ServerProcess {
  private child?: ChildProcess;
  private generation = 0;

  constructor(private readonly log: (message: string) => void = () => {}) {}

  async start(command: string, cwd?: string): Promise<{ process: ChildProcess; detached: boolean }> {
    const generation = ++this.generation;
    await this.stopChild();
    if (generation !== this.generation) throw new Error("Server startup was cancelled.");
    const child = spawn(command, ["lsp"], {
      cwd,
      stdio: "pipe",
      detached: process.platform !== "win32",
    });
    this.child = child;
    child.once("exit", (code, signal) => {
      this.log(`[server] process ${child.pid} exited: ${signal ? `signal ${signal}` : `code ${code}`}`);
    });
    await new Promise<void>((resolve, reject) => {
      child.once("error", reject);
      child.once("spawn", resolve);
    });
    if (generation !== this.generation) throw new Error("Server startup was cancelled.");
    return { process: child, detached: true };
  }

  async stop(): Promise<void> {
    this.generation += 1;
    await this.stopChild();
  }

  private async stopChild(): Promise<void> {
    const child = this.child;
    // An exited PID no longer identifies an owned process group. In particular,
    // macOS can report EPERM for a group that disappeared after a server crash.
    if (!child?.pid || child.exitCode !== null || child.signalCode !== null) {
      if (this.child === child) this.child = undefined;
      return;
    }
    // The process group also includes TeX and other resource subprocesses.
    if (process.platform === "win32") {
      if (child.exitCode === null && child.signalCode === null) {
        await new Promise<void>((resolve, reject) => {
          execFile("taskkill", ["/PID", String(child.pid), "/T", "/F"],
            { timeout: terminationTimeoutMs }, (error) => error ? reject(error) : resolve());
        });
      }
    } else {
      try {
        process.kill(-child.pid, "SIGKILL");
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ESRCH") throw error;
      }
    }
    if (child.exitCode === null && child.signalCode === null) {
      await new Promise<void>((resolve, reject) => {
        const exited = () => { clearTimeout(timer); resolve(); };
        const timer = setTimeout(() => {
          child.removeListener("exit", exited);
          reject(new Error("The language server did not exit after forced termination."));
        }, terminationTimeoutMs);
        child.once("exit", exited);
      });
    }
    if (this.child === child) this.child = undefined;
  }
}
