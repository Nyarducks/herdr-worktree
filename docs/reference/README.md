# Reference docs

Fact inventories — what exists and where — plus style conventions.
Unlike design docs, these are derived from the code; keep them terse and
update them in the same commit as the change.

| Doc | Contents |
|---|---|
| [agent-configs.md](agent-configs.md) | Per-agent config dirs (`.claude`/`.agents`) |
| [../../plugins/instances/README.md](../../plugins/instances/README.md) | The instances plugin — manifest, CLI, the Ubuntu container (tools, SSH, volumes), Docker inside, the contract |
| [skills.md](skills.md) | `.agents/skills` inventory |
| [scripts.md](scripts.md) | `scripts/` reference — behavior contract of each script |
| [shell-style.md](shell-style.md) | Shell script style guide — conventions for `scripts/` and hook scripts |
