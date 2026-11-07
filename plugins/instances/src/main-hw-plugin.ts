// Entry point of bin/hw-plugin (the contract core calls).
import { hwPluginMain, runMain } from "./cli.ts";
import { systemCtx } from "./context.ts";

process.exitCode = runMain(systemCtx(), hwPluginMain, process.argv.slice(2));
