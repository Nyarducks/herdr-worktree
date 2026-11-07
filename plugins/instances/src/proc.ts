// Running external commands (ssh, docker, herdr, ssh-keygen) behind one
// interface, so the logic can be tested with a fake runner instead of stub
// executables on PATH.
import { spawnSync, type SpawnSyncOptions } from "node:child_process";

/** Where a command's output goes. */
export type Output =
  /** collect stdout and stderr (default) */
  | "capture"
  /** the command's stdout and stderr go to our stderr (progress, build logs) */
  | "stderr"
  /** pass through to our stdout and stderr */
  | "inherit";

export interface RunOptions {
  /** text for the command's stdin; without it stdin is closed, so a command
   *  such as ssh can never read input meant for its caller */
  readonly input?: string;
  readonly env?: Readonly<Record<string, string>>;
  readonly output?: Output;
}

export interface RunResult {
  readonly code: number;
  readonly stdout: string;
  readonly stderr: string;
}

export type Runner = (cmd: string, args: readonly string[], options?: RunOptions) => RunResult;

export const systemRunner: Runner = (cmd, args, options = {}) => {
  const output = options.output ?? "capture";
  const stdin = options.input === undefined ? "ignore" : "pipe";
  const spawnOptions: SpawnSyncOptions = {
    stdio:
      output === "capture"
        ? [stdin, "pipe", "pipe"]
        : output === "stderr"
          ? [stdin, 2, 2]
          : [stdin, "inherit", "inherit"],
    env: options.env === undefined ? process.env : { ...process.env, ...options.env },
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  };
  if (options.input !== undefined) spawnOptions.input = options.input;
  const result = spawnSync(cmd, [...args], spawnOptions);
  if (result.error !== undefined) {
    const code = (result.error as NodeJS.ErrnoException).code === "ENOENT" ? 127 : 1;
    return { code, stdout: "", stderr: `${cmd}: ${result.error.message}` };
  }
  return {
    code: result.status ?? 1,
    stdout: typeof result.stdout === "string" ? result.stdout : "",
    stderr: typeof result.stderr === "string" ? result.stderr : "",
  };
};

/** Quote one word for a POSIX shell (single quotes). */
export function shellQuote(word: string): string {
  return /^[A-Za-z0-9_./:=@%+-]+$/.test(word) ? word : `'${word.replaceAll("'", `'"'"'`)}'`;
}

/** Block for `ms` milliseconds (the CLI is synchronous). */
export function sleepSync(ms: number): void {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}
