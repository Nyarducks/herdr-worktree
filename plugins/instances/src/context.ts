// What every operation gets: how to run commands, where files live, and
// where to print. Tests build their own Ctx with a fake runner and a
// temporary directory.
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { type Runner, sleepSync, systemRunner } from "./proc.ts";

export interface Paths {
  /** the herdr-worktree checkout (build context of the images) */
  readonly coreDir: string;
  /** this plugin's directory */
  readonly pluginDir: string;
  /** the manifest (git-ignored) */
  readonly manifestFile: string;
  /** instances.example.yml: the first manifest is a copy of it */
  readonly exampleFile: string;
  /** docker/: one directory per image */
  readonly imagesDir: string;
  readonly composeFile: string;
  /** per-container state: key, ssh config, port, image, docker */
  readonly containersDir: string;
  /** per-remote-host state: ssh config, known_hosts */
  readonly remotesDir: string;
  /** the label each instance had when the manifest and herdr last agreed */
  readonly labelsFile: string;
  /** the user's ssh config, which includes ours */
  readonly userSshConfig: string;
}

export interface Ctx {
  readonly run: Runner;
  readonly paths: Paths;
  /** a line for stdout (results) */
  readonly out: (line: string) => void;
  /** a line for stderr (progress, notes, guidance) */
  readonly err: (line: string) => void;
  readonly sleep: (ms: number) => void;
}

/** A failure to report as `Error: <message>` with exit status 1. */
export class CliError extends Error {}

/** A failure already explained on stderr (exit status 1, nothing more). */
export class Reported extends Error {}

export const PLUGIN_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");

/** The command users type for this plugin, relative to the checkout. */
export const CLI = "plugins/instances/bin/instance";

export function defaultPaths(env: NodeJS.ProcessEnv = process.env, pluginDir = PLUGIN_DIR): Paths {
  const config = env["XDG_CONFIG_HOME"] ?? join(homedir(), ".config");
  return {
    coreDir: env["HW_CORE_DIR"] ?? resolve(pluginDir, "..", ".."),
    pluginDir,
    manifestFile: env["HW_INSTANCES_FILE"] ?? join(pluginDir, "instances.yml"),
    exampleFile: join(pluginDir, "instances.example.yml"),
    imagesDir: env["HW_IMAGES_DIR"] ?? join(pluginDir, "docker"),
    composeFile: join(pluginDir, "compose.yml"),
    containersDir: env["HW_CONTAINER_DIR"] ?? join(config, "herdr-worktree", "containers"),
    remotesDir: env["HW_REMOTES_STATE_DIR"] ?? join(config, "herdr-worktree", "remotes"),
    labelsFile: env["HW_LABELS_FILE"] ?? join(config, "herdr-worktree", "labels.json"),
    userSshConfig: env["HW_USER_SSH_CONFIG"] ?? join(homedir(), ".ssh", "config"),
  };
}

export function systemCtx(): Ctx {
  return {
    run: systemRunner,
    paths: defaultPaths(),
    out: (line) => process.stdout.write(`${line}\n`),
    err: (line) => process.stderr.write(`${line}\n`),
    sleep: sleepSync,
  };
}
