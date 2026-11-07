---
type: ADR
title: Plugins may hook enable and disable; instances takes its machines out of herdr while off
description: A plugin whose describe lists "enable" or "disable" hooks is called after plugins.sh enable and before plugins.sh disable; the instances plugin removes its herdr machines on disable, names the containers still running, and brings the same machines back on enable.
status: accepted
last_modified: 2026-11-07
tags: [plugin, contract, herdr]
---

# ADR-0022: Plugins may hook enable and disable; instances takes its machines out of herdr while off

## Status

Accepted. Extends contract 1 (ADR-0018) with optional calls; plugins that
do not list them behave as before.

## Context

Disabling a plugin removed core's links (`.plugins/<id>`, the skill
links) and nothing else. With the `instances` plugin disabled, core behaved
as without plugins (no machines, local dispatch and listing only), but
herdr itself still showed the plugin's machines: they were registered
with `herdr machine add`, and only the plugin knows which ones are its
own. A user who disables the plugin to get back to a single machine still
saw, and was connected to, the plugin's containers and hosts.

## Decision

- **Optional hooks in contract 1.** `describe` may list
  `"hooks": ["enable", "disable"]`. `plugins.sh enable` calls
  `hw-plugin enable` after linking the plugin; `plugins.sh disable` calls
  `hw-plugin disable` before unlinking it. Core calls only the hooks a
  plugin lists, so a plugin without them is unchanged and the contract
  version stays 1. A hook's messages pass through on stderr; a hook that
  fails is a warning, and the plugin is still enabled or disabled: the
  user asked for that, and the hook says what is left to do.
- **instances, disable:** each instance's herdr machine is removed, after
  its label is synced (a label renamed in herdr is adopted, as `ensure`
  would). The removed instances are recorded in
  `~/.config/herdr-worktree/unregistered.json`. The manifest, containers
  and volumes stay. A container that is still running is named with the
  command that stops it (`docker compose -p <name> stop`); it is not
  stopped for the user, who may want its processes to finish.
- **instances, enable:** the recorded instances are ensured (a stopped
  container is started, each is registered again). One that cannot come
  back, such as a remote host that is down, is reported with the usual
  steps and stays recorded for the next enable. An instance never
  registered before disable is left alone.

## Consequences

- With the plugin disabled, neither core nor herdr shows its machines, as
  with v1.0. Enabling it again restores the machines that were there.
- Disabling needs herdr running to remove the machines. Without it,
  disable warns with the machines to remove by hand, and still unlinks.
- The record lives outside the checkout, with the plugin's other state;
  removing an instance (`instance rm`) while disabled drops it from the
  next enable.
