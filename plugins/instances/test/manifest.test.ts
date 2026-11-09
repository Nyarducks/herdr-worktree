import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { CliError } from "../src/context.ts";
import { headerOf, parseManifest, serializeManifest } from "../src/manifest.ts";

const parse = (text: string) => parseManifest(text, "instances.yml");
const failsAt = (text: string, message: RegExp) =>
  assert.throws(() => parse(text), (e: unknown) => e instanceof CliError && message.test(e.message));

describe("parseManifest", () => {
  it("reads both kinds with defaults filled in", () => {
    const m = parse(`# notes
instances:
  - name: dev-a   # a container
    kind: container
  - name: box
    kind: remote
    label: 'クライアント''s'
    host: 192.0.2.10
    user: dev
`);
    assert.deepEqual(m.instances, [
      { kind: "container", name: "dev-a", label: "dev-a", port: 2222, image: "default", docker: false },
      { kind: "remote", name: "box", label: "クライアント's", host: "192.0.2.10", port: 22, user: "dev", dir: "~/herdr-worktree" },
    ]);
  });

  it("takes an empty list, `instances:` alone and an empty file", () => {
    assert.deepEqual(parse("instances: []\n").instances, []);
    assert.deepEqual(parse("# only comments\ninstances:\n").instances, []);
    assert.deepEqual(parse("").instances, []);
  });

  it("names the line of each problem", () => {
    failsAt("instances:\n  - name: x\n    ports:\n      - 1\n", /instances\.yml:3: 'ports' must be a single value/);
    failsAt("instances:\n  - name: x\n    kind: container\n    prot: 1\n", /:4: unknown field 'prot' for a container/);
    failsAt("instances:\n  - name: x\n    kind: vm\n", /:3: kind must be 'container' or 'remote'/);
    failsAt("instances:\n  - name: x\n    kind: container\n    port: '22'\n", /:4: 'port' must be an integer/);
    failsAt("instances:\n  - name: x\n    kind: container\n    docker: yes\n", /:4: 'docker' must be true or false/);
    failsAt("instances:\n  - kind: container\n", /:2: missing required field 'name'/);
    failsAt("instances:\n  - name: Bad_Name\n    kind: container\n", /invalid instance name 'Bad_Name'/);
    failsAt("instances:\n  - name: x\n    kind: remote\n", /missing required field 'host'/);
    failsAt("instances:\n  - name: x\n    kind: container\n  - name: x\n    kind: container\n", /:4: duplicate instance name 'x'/);
    failsAt("instances:\n  - name: x\n    kind: container\n    label: Box\n  - name: y\n    kind: container\n    label: box\n", /:5: label 'box' is used twice/);
    failsAt("instances:\n  - name: x\n    kind: container\n  - name: y\n    kind: container\n    label: x\n", /:4: label 'x' is used twice/);
    failsAt("machines: []\n", /unknown top-level key 'machines'/);
    failsAt("instances:\n  - name: x\n    kind: container\n    label: has space\n", /invalid label 'has space'/);
    failsAt('instances:\n  - name: x\n    kind: container\n    label: "del\\x7Fhere"\n', /invalid label/);
    failsAt('instances:\n  - name: x\n    kind: container\n    label: "c1\\u0085here"\n', /invalid label/);
    failsAt("instances:\n  - name: x\n    kind: remote\n    host: h\n    identity: /k/my key\n", /:5: invalid identity '\/k\/my key'/);
    failsAt('instances:\n  - name: x\n    kind: remote\n    host: h\n    identity: "/k\\n    ProxyCommand x"\n', /invalid identity/);
  });

  it("rejects image fields on a remote host", () => {
    failsAt("instances:\n  - name: x\n    kind: remote\n    host: h\n    image: default\n", /unknown field 'image' for a remote/);
  });
});

describe("serializeManifest", () => {
  it("round-trips, keeping the header", () => {
    const text = `# keep me\n# and me\ninstances:\n  - name: dev-a\n    kind: container\n    docker: true\n`;
    const m = parse(text);
    const out = serializeManifest(m, headerOf(text));
    assert.ok(out.startsWith("# keep me\n# and me\ninstances:\n"));
    assert.deepEqual(parse(out), m);
    assert.match(out, /^ {2}- name: dev-a\n {4}kind: container\n {4}label: dev-a\n {4}port: 2222\n {4}image: default\n {4}docker: true$/m);
  });

  it("keeps a number-looking text value as written, through a write too", () => {
    const m = parse("instances:\n  - name: a\n    kind: container\n    label: 007\n    image: 1.10\n  - name: b\n    kind: remote\n    host: 10.0\n");
    assert.equal(m.instances[0]?.label, "007");
    assert.equal(m.instances[0]?.kind === "container" ? m.instances[0].image : "", "1.10");
    assert.equal(m.instances[1]?.kind === "remote" ? m.instances[1].host : "", "10.0");
    assert.deepEqual(parse(serializeManifest(m, "")), m, "written back unchanged");
  });

  it("writes an empty list explicitly and quotes what needs it", () => {
    assert.equal(serializeManifest({ instances: [] }, "# h\n"), "# h\ninstances: []\n");
    const out = serializeManifest(
      { instances: [{ kind: "remote", name: "b", label: "#tag", host: "h", port: 22, dir: "~/hw" }] },
      "",
    );
    assert.deepEqual(parse(out).instances[0], { kind: "remote", name: "b", label: "#tag", host: "h", port: 22, dir: "~/hw" });
    assert.match(out, /label: "#tag"/);
  });
});
