import assert from "node:assert/strict";
import { writeFileSync } from "node:fs";
import { describe, it } from "node:test";
import { hwPluginMain, instanceMain, runMain } from "../src/cli.ts";
import * as instances from "../src/instances.ts";
import { readManifest, writeManifest } from "../src/manifest.ts";
import { setup } from "./helpers.ts";

describe("hw-plugin (the contract core calls)", () => {
  it("describe names contract 1 and the skills", () => {
    const { world, ctx } = setup();
    assert.equal(runMain(ctx, hwPluginMain, ["describe"]), 0);
    const description = JSON.parse(world.out[0] as string) as { id: string; contract: number; skills: string[] };
    assert.equal(description.id, "instances");
    assert.equal(description.contract, 1);
    assert.ok(description.skills.some((s) => s.endsWith("skills/instances")));
  });

  it("machines lists the manifest with herdr's current labels", () => {
    const { world, ctx } = setup();
    world.probe.set("box", "ok");
    instances.add(ctx, "remote", "box", "192.0.2.10", { dir: "~/hw" });
    instances.add(ctx, "container", "hw-a", undefined, {});
    world.machines = world.machines.map((m) => (m.target === "box" ? { ...m, label: "Build" } : m));
    world.out = [];
    runMain(ctx, hwPluginMain, ["machines"]);
    assert.deepEqual(JSON.parse(world.out[0] as string), [
      { label: "Build", target: "box", dir: "~/hw", registered: true },
      { label: "hw-a", target: "hw-a", dir: "~/herdr-worktree", registered: true },
    ]);
  });

  it("machines reports the label a sync will leave, renaming nothing", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    instances.add(ctx, "container", "hw-b", undefined, { port: 2302 });
    world.machines = world.machines.map((m) => (m.target === "hw-a" ? { ...m, label: "My Box" } : m));
    const manifest = readManifest(ctx);
    writeManifest(ctx, { instances: manifest.instances.map((i) => (i.name === "hw-b" ? { ...i, label: "Bee" } : i)) });
    world.out = [];
    const renames = world.find("machine rename").length;
    runMain(ctx, hwPluginMain, ["machines"]);
    const labels = (JSON.parse(world.out[0] as string) as { label: string }[]).map((m) => m.label);
    assert.deepEqual(labels, ["hw-a", "Bee"], "an invalid herdr label is put back; a manifest edit wins");
    assert.equal(world.find("machine rename").length, renames, "nothing renamed");
  });

  it("exec runs in the checkout as from a pane, quoting each argument, and passes the status through", () => {
    const { world, ctx } = setup();
    world.probe.set("box", "ok");
    instances.add(ctx, "remote", "box", "192.0.2.10", { dir: "~/hw" });
    world.execCode.set("box", 3);
    assert.equal(runMain(ctx, hwPluginMain, ["exec", "box", "--", "scripts/spawn-repo-agent.sh", "--kind", "codex", "fix it's --machine x"]), 3);
    const call = world.find("cd ~/hw && HERDR_ENV=1")[0];
    assert.equal(call?.args.at(-1), `cd ~/hw && HERDR_ENV=1 scripts/spawn-repo-agent.sh --kind codex 'fix it'"'"'s --machine x'`);
    assert.equal(call?.options.output, "inherit");
    assert.equal(call?.options.input, undefined, "stdin stays closed");
  });

  it("ensure takes a label and keeps stdout clean", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, { label: "ClientA" });
    world.out = [];
    assert.equal(runMain(ctx, hwPluginMain, ["ensure", "ClientA"]), 0);
    assert.deepEqual(world.out, []);
    assert.ok(world.err.includes("ClientA: ready (herdr --machine ClientA)"));
  });
});

describe("instance (the CLI)", () => {
  it("--help explains every option; no command prints the usage", () => {
    const { world, ctx } = setup();
    assert.equal(runMain(ctx, instanceMain, ["--help"]), 0);
    assert.match(world.out[0] as string, /--identity <key> {2}remote: private key file/);
    assert.equal(runMain(ctx, instanceMain, []), 1);
    assert.match(world.err.at(-1) as string, /Every argument and option: plugins\/instances\/bin\/instance --help/);
  });

  it("a broken manifest stops every command with its line", () => {
    const { world, ctx, paths } = setup();
    writeFileSync(paths.manifestFile, "instances:\n  - name: x\n    kind: container\n    prot: 1\n");
    assert.equal(runMain(ctx, instanceMain, ["ls"]), 1);
    assert.match(world.err.at(-1) as string, /^Error: instances\.yml:4: unknown field 'prot'/);
  });

  it("an unknown option is an error with the usage", () => {
    const { world, ctx } = setup();
    assert.equal(runMain(ctx, instanceMain, ["add", "container", "hw-a", "--bogus"]), 1);
    assert.match(world.err.at(-1) as string, /Unknown option '--bogus'/);
  });

  it("ls prints tab-separated rows; image ls and new work on docker/", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, { docker: true });
    world.out = [];
    runMain(ctx, instanceMain, ["ls"]);
    assert.deepEqual(world.out, ["hw-a\thw-a\tcontainer\t127.0.0.1:2222\tok\tyes\tdefault\tyes"]);
    world.out = [];
    runMain(ctx, instanceMain, ["image", "new", "mytools"]);
    runMain(ctx, instanceMain, ["image", "ls"]);
    assert.deepEqual(world.out.slice(1), ["default\tversioned", "gpu\tlocal", "mytools\tlocal"]);
    assert.equal(runMain(ctx, instanceMain, ["image", "new", "default"]), 1);
  });
});

describe("instance rm (what it reports)", () => {
  it("says what rm and rm --purge did, and refuses an ambiguous purge", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "dev", undefined, {});
    instances.add(ctx, "container", "keep", undefined, { port: 2230 });
    world.out = [];
    assert.equal(runMain(ctx, instanceMain, ["rm", "keep"]), 0);
    assert.deepEqual(world.out, ["keep: removed from the manifest"]);
    world.out = [];
    assert.equal(runMain(ctx, instanceMain, ["rm", "dev"]), 0);
    assert.deepEqual(world.out, ["dev: removed from the manifest"]);

    instances.add(ctx, "container", "dev2", undefined, { label: "dev" });
    world.out = [];
    world.err.length = 0;
    assert.equal(runMain(ctx, instanceMain, ["rm", "--purge", "dev"]), 1);
    assert.deepEqual(world.out, []);
    assert.ok(world.err.some((l) => /^Error: 'dev' is the label of instance dev2 and the name of a container removed without --purge/.test(l)));

    world.out = [];
    assert.equal(runMain(ctx, instanceMain, ["rm", "--purge", "dev2"]), 0);
    assert.deepEqual(world.out, ["dev2: removed from the manifest (volumes, image and key deleted)"]);
    world.out = [];
    assert.equal(runMain(ctx, instanceMain, ["rm", "--purge", "dev"]), 0);
    assert.deepEqual(world.out, ["dev: deleted the volumes, image and key of this container (no longer in the manifest)"]);

    world.probe.set("box", "ok");
    instances.add(ctx, "remote", "box", "192.0.2.10", {});
    world.out = [];
    assert.equal(runMain(ctx, instanceMain, ["rm", "--purge", "box"]), 0);
    assert.deepEqual(world.out, ["box: removed from the manifest"], "a remote host has no volumes, image or key to delete");

    world.err.length = 0;
    assert.equal(runMain(ctx, instanceMain, ["rm", "--purge", "../containers/keep"]), 1, "only an instance name reaches a kept container");
    assert.ok(world.err.some((l) => /no instance named or labeled/.test(l)));
  });
});
