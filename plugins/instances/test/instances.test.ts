import assert from "node:assert/strict";
import { chmodSync, existsSync, lstatSync, mkdirSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { describe, it } from "node:test";
import { CliError } from "../src/context.ts";
import * as container from "../src/container.ts";
import * as contract from "../src/contract.ts";
import * as instances from "../src/instances.ts";
import { readManifest, writeManifest } from "../src/manifest.ts";
import { hasInclude, probeWord } from "../src/ssh.ts";
import { setup } from "./helpers.ts";

const rejects = (fn: () => unknown, message: RegExp) =>
  assert.throws(fn, (e: unknown) => e instanceof CliError && message.test(e.message));

describe("containers", () => {
  it("add builds, writes the key in through exec stdin, and registers with the label", () => {
    const { world, ctx, paths } = setup();
    assert.equal(instances.add(ctx, "container", "hw-a", undefined, { port: 2301, label: "ClientA" }), true);

    assert.deepEqual(readManifest(ctx).instances, [
      { kind: "container", name: "hw-a", label: "ClientA", port: 2301, image: "default", docker: false },
    ]);
    const up = world.find("compose", "-p hw-a", " build")[0];
    assert.ok(up);
    assert.equal(up.options.env?.["HW_SSH_PORT"], "2301");
    assert.equal(up.options.env?.["HW_IMAGE_DIR"], join(paths.imagesDir, "default"));
    assert.equal(up.options.env?.["HW_CORE_DIR"], paths.coreDir);
    assert.equal(up.options.env?.["HW_RUNTIME"], "runc");
    const key = world.find("compose", "exec -T -u root dev sh -c", "authorized_keys/dev")[0];
    assert.equal(key?.options.input, "ssh-ed25519 AAAA test\n");
    assert.equal(world.find("compose", " cp ").length, 0, "docker cp fails on sysbox containers");
    assert.ok(world.find("herdr machine add hw-a --label ClientA").length === 1);
    assert.deepEqual(world.out, ["ClientA: ready (herdr --machine ClientA)"]);
    assert.match(readFileSync(join(paths.containersDir, "hw-a", "ssh_config"), "utf8"), /Host hw-a\n {4}HostName 127\.0\.0\.1\n {4}Port 2301/);
    assert.equal(readFileSync(paths.userSshConfig, "utf8").split("\n")[0], `Include ${paths.containersDir}/ssh_config`);
    assert.match(readFileSync(paths.manifestFile, "utf8"), /# Fields and examples/, "the first manifest is a copy of the example");
  });

  it("check runs the core's and every plugin's shell tests inside", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, { port: 2301 });
    container.check(ctx, "hw-a");
    const call = world.find("ssh", "hw-a", "bats")[0];
    assert.ok(call, "the check script went over ssh");
    const script = call.args.at(-1) ?? "";
    for (const glob of ["tests/scripts/*.bats", "tests/scripts/lib/*.bats", "tests/plugins/*/*.bats"]) {
      assert.ok(script.includes(glob), `runs ${glob}`);
    }
  });

  it("add gives each container its own port and refuses a port another container uses", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "dev-a", undefined, {});
    instances.add(ctx, "container", "dev-c", undefined, { docker: true });
    instances.add(ctx, "container", "dev-d", undefined, { port: 2224 });
    instances.add(ctx, "container", "dev-e", undefined, {});
    assert.deepEqual(readManifest(ctx).instances.map((i) => [i.name, i.port]), [
      ["dev-a", 2222],
      ["dev-c", 2223],
      ["dev-d", 2224],
      ["dev-e", 2225],
    ]);
    assert.ok(world.find("compose", "-p dev-c", "up -d").length === 1);
    rejects(() => instances.add(ctx, "container", "dev-f", undefined, { port: 2223 }), /port 2223 is already used by container dev-c/);
    assert.equal(readManifest(ctx).instances.length, 4, "nothing written for a refused port");
  });

  it("a container back after rm on another port is built on that port", () => {
    const { world, ctx, paths } = setup();
    instances.add(ctx, "container", "dev-a", undefined, {});
    instances.remove(ctx, "dev-a", false);
    instances.add(ctx, "container", "dev-b", undefined, {});
    rejects(() => instances.add(ctx, "container", "dev-a", undefined, {}), /port 2222 is already used by container dev-b; pick another with --port/);
    world.calls.length = 0;
    assert.equal(instances.add(ctx, "container", "dev-a", undefined, { port: 2230 }), true);
    const up = world.find("compose", "-p dev-a", " build")[0];
    assert.equal(up?.options.env?.["HW_SSH_PORT"], "2230", "rebuilt on the new port");
    assert.match(readFileSync(join(paths.containersDir, "dev-a", "ssh_config"), "utf8"), /Port 2230/);
  });

  it("a container back after rm with another image or docker setting is built with them", () => {
    const { world, ctx, paths } = setup();
    instances.add(ctx, "container", "dev-a", undefined, {});
    instances.remove(ctx, "dev-a", false);
    world.calls.length = 0;
    assert.equal(instances.add(ctx, "container", "dev-a", undefined, { image: "gpu", docker: true }), true);
    const up = world.find("compose", "-p dev-a", " build")[0];
    assert.equal(up?.options.env?.["HW_IMAGE_DIR"], join(paths.imagesDir, "gpu"));
    assert.equal(up?.options.env?.["HW_RUNTIME"], "sysbox-runc");
  });

  it("a failed build changes nothing, so ensure still notes the difference", () => {
    const { world, ctx, paths } = setup();
    instances.add(ctx, "container", "dev-a", undefined, {});
    writeManifest(ctx, { instances: readManifest(ctx).instances.map((i) => ({ ...i, image: "gpu", port: 2240 })) });
    world.buildFails = true;
    rejects(() => instances.rebuild(ctx, "dev-a"), /compose build failed for dev-a/);
    world.buildFails = false;
    assert.match(readFileSync(join(paths.containersDir, "dev-a", "ssh_config"), "utf8"), /Port 2222/, "ssh_config stays with the last build");
    world.running.delete("dev-a");
    world.calls.length = 0;
    world.err.length = 0;
    instances.ensureOne(ctx, "dev-a");
    assert.ok(world.err.some((l) => /Note: dev-a runs docker\/default, the manifest names docker\/gpu/.test(l)));
    assert.ok(world.err.some((l) => /Note: dev-a listens on 127\.0\.0\.1:2222, the manifest says 2240/.test(l)));
    assert.equal(world.find("compose", "-p dev-a", "up -d")[0]?.options.env?.["HW_SSH_PORT"], "2222", "started as last built");
  });

  it("rm --purge of a container never built touches no compose project", () => {
    const { world, ctx, paths } = setup();
    world.buildFails = true;
    rejects(() => instances.add(ctx, "container", "dev-a", undefined, {}), /compose build failed for dev-a/);
    world.buildFails = false;
    assert.equal(existsSync(join(paths.containersDir, "dev-a")), false, "a failed first build writes nothing");
    world.calls.length = 0;
    instances.remove(ctx, "dev-a", true);
    assert.equal(world.find("compose", "down").length, 0, "a project of that name may be someone else's");
    assert.equal(readManifest(ctx).instances.length, 0);
  });

  it("a first build refuses a name another compose file already uses as a project", () => {
    const { world, ctx, paths } = setup();
    world.foreignProjects.set("sandbox", "/home/u/other/compose.yml");
    rejects(() => instances.add(ctx, "container", "sandbox", undefined, {}), /docker compose project 'sandbox' from \/home\/u\/other\/compose\.yml already exists/);
    assert.equal(world.find("compose", "-p sandbox").length, 0, "nothing built or started");
    assert.equal(readManifest(ctx).instances.length, 0, "a refused add leaves no entry");
    world.foreignProjects.set("sandbox", paths.composeFile);
    world.volumes.set("sandbox_state", "sandbox");
    assert.equal(instances.add(ctx, "container", "sandbox", undefined, {}), true, "a project from the plugin's own file, volumes and all, is not refused");
  });

  it("a first build refuses a name whose compose volumes are left from another project", () => {
    const { world, ctx } = setup();
    world.volumes.set("dev_state", "dev");
    world.volumes.set("dev_data", "dev");
    rejects(() => instances.add(ctx, "container", "dev", undefined, {}), /docker volumes of a compose project 'dev' already exist \(dev_state, dev_data\)/);
    assert.equal(world.find("compose", "-p dev").length, 0, "no volume mounted");
    assert.equal(readManifest(ctx).instances.length, 0);
  });

  it("a first build refuses a volume compose would mount by name, whatever its label", () => {
    const { world, ctx } = setup();
    world.volumes.set("dev_state", "other");
    rejects(() => instances.add(ctx, "container", "dev", undefined, {}), /\(dev_state\)/);
    world.volumes.set("dev_state", "");
    rejects(() => instances.add(ctx, "container", "dev", undefined, {}), /\(dev_state\)/);
    world.volumes.delete("dev_state");
    world.volumes.set("dev_unrelated", "other");
    assert.equal(instances.add(ctx, "container", "dev", undefined, {}), true, "volumes compose would not mount are no concern");
  });

  it("a remote host cannot take the name of a container kept after rm until it is purged", () => {
    const { world, ctx, paths } = setup();
    instances.add(ctx, "container", "dev", undefined, {});
    instances.remove(ctx, "dev", false);
    rejects(() => instances.add(ctx, "remote", "dev", "u@192.0.2.10", {}), /removed without --purge .* rm --purge dev/);
    assert.equal(readManifest(ctx).instances.length, 0);
    instances.remove(ctx, "dev", true);
    assert.equal(world.find("compose", "-p dev", "down -v --rmi local").length, 1, "purged by name though not in the manifest");
    assert.equal(existsSync(join(paths.containersDir, "dev")), false, "its ssh entry is gone");
    world.probe.set("dev", "ok");
    assert.equal(instances.add(ctx, "remote", "dev", "u@192.0.2.10", {}), true);
  });

  it("rm --purge never guesses between a live label and an old container of that name", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "dev", undefined, {});
    instances.remove(ctx, "dev", false);
    instances.add(ctx, "container", "dev2", undefined, { label: "dev" });
    world.calls.length = 0;
    rejects(() => instances.remove(ctx, "dev", true), /'dev' is the label of instance dev2 and the name of a container removed without --purge/);
    assert.equal(world.find("compose", "down").length, 0, "nothing deleted");
    assert.ok(world.volumes.has("dev_state") && world.volumes.has("dev2_state"));
    assert.deepEqual(instances.remove(ctx, "dev", false), { name: "dev2", kind: "container", inManifest: true }, "without --purge the label resolves as before");
    assert.deepEqual(instances.remove(ctx, "dev", true), { name: "dev", kind: "container", inManifest: false }, "then the old container's data can go");
    assert.equal(world.volumes.has("dev_state"), false);
  });

  it("rm keeps the volumes and re-adding the same name is not refused; rm --purge removes them", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "dev-a", undefined, {});
    instances.remove(ctx, "dev-a", false);
    assert.ok(world.volumes.has("dev-a_state"), "a plain rm keeps the volumes");
    assert.equal(instances.add(ctx, "container", "dev-a", undefined, {}), true, "its own volumes do not refuse the re-add");
    instances.remove(ctx, "dev-a", true);
    assert.equal(world.volumes.has("dev-a_state"), false);
    assert.equal(instances.add(ctx, "container", "dev-a", undefined, {}), true);
  });

  it("ensure of a manifest entry never built also refuses a foreign project", () => {
    const { world, ctx } = setup();
    writeManifest(ctx, { instances: [{ kind: "container", name: "dev", label: "dev", port: 2222, image: "default", docker: false }] });
    world.volumes.set("dev_state", "dev");
    world.err.length = 0;
    assert.equal(instances.ensure(ctx, []), false);
    assert.ok(world.err.some((l) => /Error: dev: docker volumes of a compose project 'dev' already exist/.test(l)));
    assert.equal(world.find("compose", "-p dev").length, 0);
  });

  it("ensure notes a port edited in the manifest and points to rebuild", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "dev-a", undefined, {});
    writeManifest(ctx, { instances: readManifest(ctx).instances.map((i) => ({ ...i, port: 2240 })) });
    world.err.length = 0;
    instances.ensureOne(ctx, "dev-a");
    assert.ok(world.err.some((l) => /Note: dev-a listens on 127\.0\.0\.1:2222, the manifest says 2240; apply it with: .* rebuild dev-a/.test(l)));
  });

  it("the first container on a machine whose ssh config lacks the Include gets it before the probe", () => {
    const { world, ctx, paths } = setup();
    mkdirSync(dirname(paths.userSshConfig), { recursive: true });
    writeFileSync(paths.userSshConfig, "Host *\n    ServerAliveInterval 30\n");
    assert.equal(instances.add(ctx, "container", "dev-a", undefined, {}), true);
    assert.equal(readFileSync(paths.userSshConfig, "utf8").split("\n")[0], `Include ${paths.containersDir}/ssh_config`);
    assert.ok(world.machines.some((m) => m.target === "dev-a"), "registered with herdr");
  });

  it("ensure starts a stopped container without rebuilding", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    world.running.delete("hw-a");
    world.calls = [];
    world.err = [];
    assert.equal(instances.ensure(ctx, []), true);
    assert.equal(world.find("compose", " build").length, 0);
    assert.equal(world.find("compose", "-p hw-a", "up -d").length, 1);
    assert.ok(world.err.includes("hw-a: unreachable; starting the container and its herdr server"));
    assert.equal(world.find("herdr machine add").length, 0, "not registered again");
  });

  it("ensure only notes a changed image or docker; rebuild applies them", () => {
    const { world, ctx, paths } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    writeFileSync(paths.manifestFile, readFileSync(paths.manifestFile, "utf8").replace(/^    image: default$/m, "    image: gpu").replace(/^    docker: false$/m, "    docker: true"));
    world.calls = [];
    instances.ensure(ctx, ["hw-a"]);
    assert.ok(world.err.some((l) => l.includes("runs docker/default, the manifest names docker/gpu")));
    assert.ok(world.err.some((l) => l.includes("built with docker: false, the manifest says true")));
    assert.equal(world.find("compose", "up").length, 0, "a running container is left alone");

    assert.equal(instances.rebuild(ctx, "hw-a"), true);
    const up = world.find("compose", " build")[0];
    assert.equal(up?.options.env?.["HW_IMAGE_DIR"], join(paths.imagesDir, "gpu"));
    assert.equal(up?.options.env?.["HW_RUNTIME"], "sysbox-runc");
    assert.equal(up?.options.env?.["HW_DOCKER"], "1");
  });

  it("docker: true needs sysbox and never falls back to --privileged", () => {
    const { world, ctx } = setup();
    world.sysbox = false;
    instances.ensure(ctx, []);
    rejects(() => instances.add(ctx, "container", "hw-d", undefined, { docker: true }), /needs the sysbox-runc runtime/);
    assert.equal(world.find("compose", "up").length, 0);
    assert.equal(readManifest(ctx).instances.length, 0, "a refused add leaves no entry");
  });

  it("refuses unknown images, remote-only options and taken names", () => {
    const { ctx } = setup();
    rejects(() => instances.add(ctx, "container", "hw-x", undefined, { image: "nope" }), /no image 'nope'/);
    rejects(() => instances.add(ctx, "container", "hw-x", undefined, { dir: "~/x" }), /--identity and --dir are for remote hosts/);
    rejects(() => instances.add(ctx, "container", "Bad", undefined, {}), /invalid instance name/);
    instances.add(ctx, "container", "hw-a", undefined, {});
    rejects(() => instances.add(ctx, "container", "hw-a", undefined, {}), /already in the manifest/);
    rejects(() => instances.add(ctx, "container", "hw-b", undefined, { label: "HW-A" }), /label 'HW-A' is already used/);
  });

  it("rm --purge removes volumes, image, machine and state", () => {
    const { world, ctx, paths } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    instances.remove(ctx, "hw-a", true);
    assert.equal(world.find("compose", "-p hw-a", "down -v --rmi local").length, 1);
    assert.deepEqual(world.machines, []);
    assert.equal(existsSync(join(paths.containersDir, "hw-a")), false);
    assert.deepEqual(readManifest(ctx).instances, []);
    assert.match(readFileSync(paths.manifestFile, "utf8"), /# Fields and examples[\s\S]*instances: \[\]/, "the header survives");
  });
});

describe("remote hosts", () => {
  it("are explained, never started, and registered once usable", () => {
    const { world, ctx, paths, dir } = setup();
    const key = join(dir, "id_test");
    writeFileSync(key, "");
    assert.equal(instances.add(ctx, "remote", "box", "dev@192.0.2.10", { port: 2022, identity: key }), false);
    assert.deepEqual(readManifest(ctx).instances, [
      { kind: "remote", name: "box", label: "box", host: "192.0.2.10", port: 2022, user: "dev", identity: key, dir: "~/herdr-worktree" },
    ]);
    const config = readFileSync(join(paths.remotesDir, "box", "ssh_config"), "utf8");
    assert.match(config, /Host box\n {4}HostName 192\.0\.2\.10\n {4}Port 2022\n {4}User dev\n {4}IdentityFile /);
    assert.ok(world.err.includes("Action needed on box (dev@192.0.2.10:2022) — remote hosts are not started from here:"));
    assert.ok(world.err.some((l) => l.includes("Connection refused")));
    assert.ok(world.err.includes("  Then run: plugins/instances/bin/instance ensure box"));
    assert.equal(world.find("compose").length, 0, "nothing started");
    assert.equal(world.find("herdr machine add").length, 0, "not registered while down");

    const cases: [string, RegExp][] = [
      ["missing: gh herdr", /missing on PATH for non-interactive ssh: gh, herdr/],
      ["no-checkout", /git clone https:\/\/example\.invalid\/herdr-worktree\.git ~\/herdr-worktree/],
      ["no-server", /cd ~\/herdr-worktree && setsid -f herdr server/],
    ];
    for (const [answer, guidance] of cases) {
      world.probe.set("box", answer);
      world.err = [];
      assert.equal(instances.ensure(ctx, ["box"]), false);
      assert.ok(world.err.some((l) => guidance.test(l)), answer);
    }

    world.probe.set("box", "ok");
    world.out = [];
    assert.equal(instances.ensure(ctx, ["box"]), true);
    assert.ok(world.find("herdr machine add box --label box").length === 1);
    assert.ok(world.find("herdr --machine id-box workspace list").length >= 1, "forwarding checked by id");
    assert.deepEqual(world.out, ["box: ready (herdr --machine box)"]);
  });

  it("rm deletes the ssh entry and the machine, nothing else", () => {
    const { world, ctx, paths } = setup();
    world.probe.set("box", "ok");
    instances.add(ctx, "remote", "box", "192.0.2.10", {});
    instances.remove(ctx, "box", false);
    assert.equal(existsSync(join(paths.remotesDir, "box")), false);
    assert.deepEqual(world.machines, []);
    assert.equal(world.find("compose").length, 0);
  });
});

describe("labels, listing and ensure of many", () => {
  it("rename sets herdr's label; a rename in herdr is adopted", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    instances.rename(ctx, "hw-a", "クライアントB");
    assert.ok(world.find("herdr machine rename id-hw-a --label クライアントB").length === 1);
    assert.equal(readManifest(ctx).instances[0]?.label, "クライアントB");

    world.machines = world.machines.map((m) => ({ ...m, label: "Renamed" }));
    const [row] = instances.list(ctx);
    assert.equal(row?.label, "Renamed");
    assert.equal(readManifest(ctx).instances[0]?.label, "Renamed");
    assert.equal(instances.resolve(ctx, readManifest(ctx), "Renamed").name, "hw-a");
  });

  it("a herdr label the manifest cannot hold is put back, not adopted", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    instances.add(ctx, "container", "hw-b", undefined, { port: 2302, label: "Bee" });
    world.err.length = 0;

    world.machines = world.machines.map((m) => (m.target === "hw-a" ? { ...m, label: "My Box" } : m));
    instances.list(ctx);
    assert.equal(readManifest(ctx).instances[0]?.label, "hw-a", "invalid label not adopted");
    assert.equal(world.machines.find((m) => m.target === "hw-a")?.label, "hw-a", "herdr renamed back");
    assert.ok(world.err.some((l) => /herdr's label 'My Box' cannot be used/.test(l)));

    world.machines = world.machines.map((m) => (m.target === "hw-a" ? { ...m, label: "bee" } : m));
    instances.list(ctx);
    assert.equal(readManifest(ctx).instances[0]?.label, "hw-a", "another instance's label (any case) not adopted");
    assert.equal(world.machines.find((m) => m.target === "hw-a")?.label, "hw-a");
    assert.doesNotThrow(() => readManifest(ctx), "the manifest stays readable");
  });

  it("a rename herdr refuses is reported and ls still lists every instance", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    instances.add(ctx, "container", "hw-b", undefined, { port: 2302 });
    world.machines = world.machines.map((m) => (m.target === "hw-a" ? { ...m, label: "My Box" } : m));
    world.renameFails = true;
    world.err.length = 0;
    const rows = instances.list(ctx);
    assert.deepEqual(rows.map((r) => r.name), ["hw-a", "hw-b"]);
    assert.equal(readManifest(ctx).instances[0]?.label, "hw-a", "manifest unchanged");
    assert.ok(world.err.some((l) => /hw-a: herdr could not rename machine id-hw-a to hw-a; herdr keeps My Box/.test(l)));
  });

  it("add refuses an identity path an ssh config cannot hold", () => {
    const { ctx, dir } = setup();
    const key = join(dir, "my key");
    writeFileSync(key, "k");
    rejects(() => instances.add(ctx, "remote", "box", "dev@192.0.2.10", { identity: key }), /invalid identity/);
    assert.equal(readManifest(ctx).instances.length, 0);
  });

  it("a symlinked ~/.ssh/config is edited at its target, keeping the link", () => {
    const { ctx, paths, dir } = setup();
    const real = join(dir, "dotfiles", "ssh_config");
    mkdirSync(join(dir, "dotfiles"), { recursive: true });
    writeFileSync(real, "Host x\n");
    mkdirSync(dirname(paths.userSshConfig), { recursive: true });
    symlinkSync(real, paths.userSshConfig);
    instances.add(ctx, "container", "hw-a", undefined, {});
    assert.ok(lstatSync(paths.userSshConfig).isSymbolicLink(), "still a link");
    assert.equal(readFileSync(real, "utf8").split("\n")[0], `Include ${paths.containersDir}/ssh_config`);
    assert.ok(readFileSync(real, "utf8").includes("Host x"));
  });

  it("an ssh config link to a file that cannot be written is explained, not crashed on", () => {
    const { world, ctx, paths, dir } = setup();
    world.probe.set("box", "ok");
    const store = join(dir, "store");
    mkdirSync(store, { recursive: true });
    writeFileSync(join(store, "ssh_config"), "Host x\n");
    mkdirSync(dirname(paths.userSshConfig), { recursive: true });
    symlinkSync(join(store, "ssh_config"), paths.userSshConfig);
    chmodSync(join(store, "ssh_config"), 0o444);
    chmodSync(store, 0o555);
    try {
      assert.equal(instances.add(ctx, "container", "hw-a", undefined, {}), false, "unreachable without the Include");
      assert.ok(world.err.some((l) => /^Warning: hw-a: cannot update .*ssh_config.*links to.*\n {2}Include /s.test(l)), "says which line to add");
      assert.ok(world.err.some((l) => /^Error: hw-a: ssh does not know it without the Include line above \(ssh: Could not resolve hostname hw-a.*\); .* ensure hw-a/.test(l)), "ends on the Include, not on rebuild");
      assert.ok(!world.err.some((l) => /rebuild it with/.test(l)));
      assert.ok(lstatSync(paths.userSshConfig).isSymbolicLink(), "still a link");
      assert.deepEqual(readdirSync(store), ["ssh_config"], "no temporary file left");
      writeManifest(ctx, { instances: [{ kind: "remote", name: "box", label: "box", host: "192.0.2.10", port: 22, dir: "~/hw" }] });
      world.err.length = 0;
      assert.equal(instances.list(ctx).length, 1, "ls still lists");
      assert.ok(world.err.some((l) => /Warning: box: cannot update/.test(l)));
      world.err.length = 0;
      assert.equal(instances.ensure(ctx, ["box"]), false);
      assert.ok(world.err.some((l) => /^Error: box: ssh does not know it without the Include line above/.test(l)), "a remote also ends on the Include");
      assert.ok(!world.err.some((l) => /Start the machine/.test(l)));
    } finally {
      chmodSync(store, 0o755);
    }
  });

  it("an ssh config that cannot be read, or sits under a file, is explained, not crashed on", () => {
    const { world, ctx, paths, dir } = setup();
    mkdirSync(paths.userSshConfig, { recursive: true });
    assert.equal(instances.add(ctx, "container", "hw-a", undefined, {}), false);
    assert.ok(world.err.some((l) => /^Warning: hw-a: cannot update .*EISDIR/.test(l)));
    const other = setup();
    writeFileSync(join(dir, "afile"), "");
    const under = { ...other.ctx, paths: { ...other.paths, userSshConfig: join(dir, "afile", "config") } };
    assert.equal(instances.add(under, "container", "hw-a", undefined, {}), false);
    assert.ok(other.world.err.some((l) => /^Warning: hw-a: cannot update .*afile\/config: E[A-Z]+;/.test(l)));
  });

  it("an Include the plugin cannot see does not hide why ssh fails", () => {
    const { world, ctx, paths, dir } = setup();
    world.probe.set("box", "ok");
    instances.add(ctx, "remote", "box", "192.0.2.10", {});
    // the line sits where the plugin does not count it, in a read-only file
    const store = join(dir, "store");
    mkdirSync(store, { recursive: true });
    // ssh applies a line under `Host * !github.com` to box; the plugin counts
    // only an Include it can be sure of
    writeFileSync(join(store, "ssh_config"), `Host * !github.com\n${world.remotesInclude}\n`);
    rmSync(paths.userSshConfig);
    symlinkSync(join(store, "ssh_config"), paths.userSshConfig);
    chmodSync(store, 0o555);
    try {
      world.probe.delete("box");
      world.err.length = 0;
      assert.equal(instances.ensureOne(ctx, "box"), false);
      assert.ok(world.err.some((l) => /^Warning: box: cannot update/.test(l)), "the plugin could not see or write the line");
      assert.ok(!world.err.some((l) => /does not know it without the Include/.test(l)), "ssh knew the host");
      assert.ok(world.err.some((l) => /Connection refused/.test(l)), "the real cause is shown");
    } finally {
      chmodSync(store, 0o755);
    }
  });

  it("a HostName that does not resolve gets the usual advice, not the Include's", () => {
    const { world, ctx, paths, dir } = setup();
    world.probe.set("box", "ok");
    instances.add(ctx, "remote", "box", "box.lan", {});
    world.dnsFails.set("box", "box.lan");
    world.err.length = 0;
    assert.equal(instances.ensureOne(ctx, "box"), false);
    assert.ok(world.err.some((l) => /cannot connect over ssh \(ssh: Could not resolve hostname box\.lan/.test(l)), "the Include was written: usual advice");
    assert.ok(!world.err.some((l) => /does not know it without the Include/.test(l)));
    // a host named like the instance: ssh's error names the alias, but the
    // plugin wrote the Include itself, so that is not the cause
    world.dnsFails.set("box", "box");
    world.err.length = 0;
    assert.equal(instances.ensureOne(ctx, "box"), false);
    assert.ok(!world.err.some((l) => /does not know it without the Include/.test(l)), "an Include in place is never the advice");
    world.dnsFails.set("box", "box.lan");

    // the Include present in a form the plugin does not count, read-only
    const store = join(dir, "store");
    mkdirSync(store, { recursive: true });
    writeFileSync(join(store, "ssh_config"), `Host * !github.com\n${world.remotesInclude}\n`);
    rmSync(paths.userSshConfig);
    symlinkSync(join(store, "ssh_config"), paths.userSshConfig);
    chmodSync(store, 0o555);
    try {
      world.err.length = 0;
      assert.equal(instances.ensureOne(ctx, "box"), false);
      assert.ok(world.err.some((l) => /^Warning: box: cannot update/.test(l)));
      assert.ok(!world.err.some((l) => /does not know it without the Include/.test(l)), "ssh named the HostName, so it knew the alias");
      assert.ok(world.err.some((l) => /cannot connect over ssh/.test(l)));
    } finally {
      chmodSync(store, 0o755);
    }
  });

  it("hasInclude reads an Include in every form ssh takes", () => {
    const p = join(homedir(), ".config", "hw", "containers", "ssh_config");
    for (const line of [
      `Include ${p}`,
      `include = ${p}`,
      `  Include /a ${p}`,
      "Include ~/.config/hw/containers/ssh_config",
      `Include "${p}"`,
      `Include '${p}'`,
      `Include ${p} # mine`,
      `Host *\r\n  Include ${p}\r\n`,
      `Host x\n  User u\nMatch all\n  Include ${p}\n`,
    ]) {
      assert.ok(hasInclude(line, p), line);
    }
    for (const line of [
      `Include ${p}x`,
      `# Include ${p}`,
      `IncludeX ${p}`,
      "",
      // under a Host or Match block it applies to those hosts only
      `Host github.com\n  User git\nInclude ${p}\n`,
      `Match host other\nInclude ${p}\n`,
    ]) {
      assert.ok(!hasInclude(line, p), line);
    }
  });

  it("an Include ssh already takes in another form is recognized, even in a file that cannot be written", () => {
    const { world, ctx, paths, dir } = setup();
    const store = join(dir, "store");
    mkdirSync(store, { recursive: true });
    // home-manager writes every include on one line
    writeFileSync(join(store, "ssh_config"), `Include ${paths.remotesDir}/ssh_config ${paths.containersDir}/ssh_config\nHost *\n`);
    mkdirSync(dirname(paths.userSshConfig), { recursive: true });
    symlinkSync(join(store, "ssh_config"), paths.userSshConfig);
    chmodSync(join(store, "ssh_config"), 0o444);
    chmodSync(store, 0o555);
    try {
      // the World reads only the exact line; give it what ssh would resolve
      world.containersInclude = `Include ${paths.remotesDir}/ssh_config ${paths.containersDir}/ssh_config`;
      world.err.length = 0;
      assert.equal(instances.add(ctx, "container", "hw-a", undefined, {}), true);
      assert.ok(!world.err.some((l) => /Warning/.test(l)), "nothing to add, nothing to warn about");
    } finally {
      chmodSync(store, 0o755);
    }
  });

  it("ensure fails when herdr refuses the manifest's label, instead of naming a label herdr lacks", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    const manifest = readManifest(ctx);
    writeManifest(ctx, { instances: manifest.instances.map((i) => ({ ...i, label: "New" })) });
    world.renameFails = true;
    world.out.length = 0;
    world.err.length = 0;
    assert.equal(instances.ensureOne(ctx, "hw-a"), false);
    assert.deepEqual(world.out, [], "no ready line");
    assert.ok(world.err.some((l) => /Error: hw-a: herdr's machine and the manifest disagree/.test(l)));
    world.renameFails = false;
    assert.equal(instances.ensureOne(ctx, "hw-a"), true, "pushed once herdr accepts it");
    assert.equal(world.machines[0]?.label, "New");
  });

  it("an ssh config link to a missing file is explained and kept", () => {
    const { world, ctx, paths, dir } = setup();
    mkdirSync(dirname(paths.userSshConfig), { recursive: true });
    symlinkSync(join(dir, "gone", "ssh_config"), paths.userSshConfig);
    assert.equal(instances.add(ctx, "container", "hw-a", undefined, {}), false);
    assert.ok(world.err.some((l) => /^Warning: hw-a: .* is a link that leads to no file/.test(l)));
    assert.ok(lstatSync(paths.userSshConfig).isSymbolicLink(), "still a link");
  });

  it("a label edited in the manifest renames herdr's machine on the next ls and ensure", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    const edit = (label: string): void => {
      const manifest = readManifest(ctx);
      writeManifest(ctx, { instances: manifest.instances.map((i) => ({ ...i, label })) });
    };

    edit("Sandbox");
    assert.equal(instances.list(ctx)[0]?.label, "Sandbox");
    assert.ok(world.find("herdr machine rename id-hw-a --label Sandbox").length === 1);
    assert.equal(world.machines[0]?.label, "Sandbox");

    edit("Other");
    assert.equal(instances.ensureOne(ctx, "hw-a"), true);
    assert.equal(world.machines[0]?.label, "Other");
    assert.equal(readManifest(ctx).instances[0]?.label, "Other");

    // then a rename in herdr is still adopted
    world.machines = world.machines.map((m) => ({ ...m, label: "FromHerdr" }));
    instances.list(ctx);
    assert.equal(readManifest(ctx).instances[0]?.label, "FromHerdr");
  });

  it("with no record or both sides changed the manifest wins; a clash leaves herdr alone", () => {
    const { world, ctx, paths } = setup();
    instances.add(ctx, "container", "hw-a", undefined, {});
    world.machines.push({ id: "id-x", label: "Taken", target: "x", enabled: true });
    const edit = (label: string): void => {
      const manifest = readManifest(ctx);
      writeManifest(ctx, { instances: manifest.instances.map((i) => ({ ...i, label })) });
    };

    rmSync(paths.labelsFile);
    world.machines = world.machines.map((m) => (m.target === "hw-a" ? { ...m, label: "Herdr" } : m));
    edit("Manifest");
    instances.list(ctx);
    assert.equal(world.machines.find((m) => m.target === "hw-a")?.label, "Manifest", "no record: manifest wins");

    world.machines = world.machines.map((m) => (m.target === "hw-a" ? { ...m, label: "Herdr2" } : m));
    edit("Manifest2");
    instances.list(ctx);
    assert.equal(world.machines.find((m) => m.target === "hw-a")?.label, "Manifest2", "both changed: manifest wins");

    edit("taken");
    world.err.length = 0;
    instances.list(ctx);
    assert.equal(world.machines.find((m) => m.target === "hw-a")?.label, "Manifest2", "clash: herdr keeps its label");
    assert.equal(readManifest(ctx).instances[0]?.label, "taken", "clash: the manifest edit is not reverted");
    assert.ok(world.err.some((l) => /cannot be applied to herdr/.test(l)));
    assert.equal(instances.list(ctx)[0]?.label, "Manifest2", "clash: ls shows the label --machine takes");
    world.out.length = 0;
    assert.equal(instances.ensureOne(ctx, "hw-a"), true);
    assert.deepEqual(world.out, ["Manifest2: ready (herdr --machine Manifest2)"], "clash: ready names herdr's label, not the other machine's");
    instances.list(ctx);
    assert.equal(readManifest(ctx).instances[0]?.label, "taken", "still not reverted on the next ls");
  });

  it("ls reports each instance", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, { port: 2301 });
    world.probe.set("box", "no-server");
    instances.add(ctx, "remote", "box", "dev@192.0.2.10", {});
    const rows = instances.list(ctx).map((r) => [r.name, r.kind, r.address, probeWord(r.status), r.registered, r.image ?? "-"]);
    assert.deepEqual(rows, [
      ["hw-a", "container", "127.0.0.1:2301", "ok", true, "default"],
      ["box", "remote", "dev@192.0.2.10:22", "no-server", false, "-"],
    ]);
  });

  it("one unusable instance does not stop the others", () => {
    const { world, ctx } = setup();
    world.probe.set("box", "ok");
    instances.add(ctx, "remote", "box", "192.0.2.10", {});
    instances.add(ctx, "container", "hw-a", undefined, {});
    world.probe.set("box", "no-server");
    world.running.delete("hw-a");
    world.out = [];
    assert.equal(instances.ensure(ctx, []), false);
    assert.deepEqual(world.out, ["hw-a: ready (herdr --machine hw-a)"]);
  });
});

describe("plugin disable and enable", () => {
  it("describe lists the enable and disable hooks", () => {
    assert.deepEqual(contract.describe().hooks, ["enable", "disable"]);
  });

  it("disable takes the machines out of herdr and names the running containers; enable brings those back", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, { port: 2301, label: "ClientA" });
    instances.add(ctx, "container", "hw-b", undefined, { port: 2302 });
    world.probe.set("box", "ok");
    instances.add(ctx, "remote", "box", "dev@192.0.2.10", {});
    world.running.delete("hw-b");
    world.machines = world.machines.filter((m) => m.target !== "hw-b"); // never registered
    world.err.length = 0;

    assert.equal(contract.disable(ctx), true);
    assert.equal(world.machines.length, 0, "no machine of the plugin left in herdr");
    const err = world.err.join("\n");
    assert.match(err, /ClientA: removed from herdr's machines/);
    assert.match(err, /box: removed from herdr's machines/);
    assert.match(err, /ClientA is still running; stop it with: docker compose -p hw-a stop/);
    assert.doesNotMatch(err, /hw-b is still running/);
    assert.deepEqual(readManifest(ctx).instances.map((i) => i.name), ["hw-a", "hw-b", "box"], "the manifest is kept");

    world.err.length = 0;
    world.out.length = 0;
    assert.equal(contract.enable(ctx), true);
    assert.deepEqual(world.machines.map((m) => `${m.target}=${m.label}`).sort(), ["box=box", "hw-a=ClientA"], "only the machines disable took out");
    assert.equal(contract.enable(ctx), true, "a second enable has nothing to bring back");
    assert.equal(world.find("herdr machine add hw-a").length, 2, "added once at add, once on enable");
  });

  it("disable keeps a label renamed in herdr", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, { port: 2301 });
    world.machines = world.machines.map((m) => ({ ...m, label: "Renamed" }));
    contract.disable(ctx);
    contract.enable(ctx);
    assert.equal(readManifest(ctx).instances[0]?.label, "Renamed");
    assert.deepEqual(world.machines.map((m) => m.label), ["Renamed"]);
  });

  it("disable fails, with what to do, when herdr cannot list or remove its machines", () => {
    const { world, ctx } = setup();
    instances.add(ctx, "container", "hw-a", undefined, { port: 2301 });
    world.err.length = 0;
    world.listFails = true;
    assert.equal(contract.disable(ctx), false);
    const again = /scripts\/plugins\.sh enable instances && scripts\/plugins\.sh disable instances/;
    assert.match(world.err.join("\n"), /cannot read herdr's machines/);
    assert.match(world.err.join("\n"), again, "a sequence that works once the plugin is unlinked");
    world.listFails = false;
    world.removeFails = true;
    world.err.length = 0;
    assert.equal(contract.disable(ctx), false);
    assert.match(world.err.join("\n"), /hw-a: could not remove herdr machine id-hw-a/);
    assert.match(world.err.join("\n"), again);
    assert.equal(world.machines.length, 1);
  });

  it("enable reports a machine it cannot bring back and keeps it for the next enable", () => {
    const { world, ctx } = setup();
    world.probe.set("box", "ok");
    instances.add(ctx, "remote", "box", "dev@192.0.2.10", {});
    contract.disable(ctx);
    world.probe.set("box", "no-server");
    assert.equal(contract.enable(ctx), false);
    assert.equal(world.machines.length, 0);
    world.probe.set("box", "ok");
    assert.equal(contract.enable(ctx), true);
    assert.deepEqual(world.machines.map((m) => m.target), ["box"]);
  });
});
