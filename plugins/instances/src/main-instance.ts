// Entry point of bin/instance.
import { instanceMain, runMain } from "./cli.ts";
import { systemCtx } from "./context.ts";

process.exitCode = runMain(systemCtx(), instanceMain, process.argv.slice(2));
