#!/usr/bin/env bash
# plugins.sh — finding and calling herdr-worktree plugins (ADR-0018). Sourced
# by list-workers.sh, spawn-repo-agent.sh and scripts/plugins.sh.
#
# A plugin is a directory with an executable bin/hw-plugin that speaks the
# contract (version 1):
#
#   hw-plugin describe            JSON {id, name, version, contract, skills[],
#                                 hooks}: skills are skill directories (each
#                                 with a SKILL.md), absolute or relative to
#                                 the plugin directory; hooks (optional)
#                                 lists "enable" and/or "disable"
#   hw-plugin machines            JSON [{label, target, dir, registered}]: the
#                                 other machines workers can run on
#   hw-plugin ensure <machine>    bring it into use; exit 1 (reasons on
#                                 stderr) when it cannot be
#   hw-plugin exec <machine> -- <cmd> [args...]
#                                 run <cmd> in that machine's herdr-worktree
#                                 checkout as from a pane there; its output
#                                 and exit status pass through
#   hw-plugin enable | disable    optional hooks, called by scripts/plugins.sh
#                                 after enabling / before disabling when
#                                 describe lists them; messages on stderr;
#                                 non-zero makes core warn, and the plugin is
#                                 enabled / disabled anyway (ADR-0022)
#
# A plugin is enabled by a symlink <checkout>/.plugins/<id> -> its directory
# (git-ignored; scripts/plugins.sh manages them; HW_PLUGINS_DIR overrides).
# With no plugin enabled, core works on this machine only.

hw_plugins_root() {
  printf '%s\n' "${HW_PLUGINS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.plugins}"
}

# hw_plugin_bins — the bin/hw-plugin of each enabled plugin, one per line.
hw_plugin_bins() {
  local root link
  root="$(hw_plugins_root)"
  [[ -d "${root}" ]] || return 0
  for link in "${root}"/*; do
    [[ -x "${link}/bin/hw-plugin" ]] && printf '%s\n' "${link}/bin/hw-plugin"
  done
  return 0
}

# hw_plugin_machines — "<bin>\t<label>\t<target>" for every machine of every
# enabled plugin. Fields are joined as they are (not @tsv, which would
# double a backslash in a label). A machine whose label or target is empty or
# holds whitespace, a control character or '/' would break these rows and
# the <label>/<pane> names: it is reported and skipped, as is a plugin that
# cannot list its machines.
hw_plugin_machines() {
  local bin json row
  while IFS= read -r bin; do
    if ! json="$("${bin}" machines </dev/null)"; then
      echo "Warning: plugin ${bin%/bin/hw-plugin} could not list its machines; skipped." >&2
      continue
    fi
    while IFS= read -r row; do
      if [[ "${row}" == "!"* ]]; then
        echo "Warning: plugin ${bin%/bin/hw-plugin} lists a machine with an unusable label or target (${row#!}); skipped." >&2
      else
        printf '%s\n' "${row}"
      fi
    done < <(jq -r --arg bin "${bin}" '.[] |
      if ([.label, .target] | all(type == "string" and test("^[^\\s\\p{Cc}/]+$")))
      then [$bin, .label, .target] | join("\t")
      else "!" + ({label, target} | tojson) end' <<< "${json}")
  done < <(hw_plugin_bins)
}

# hw_plugin_find <label-or-target> — "<bin>\t<label>\t<target>" of the
# machine with that target, else of the first with that label (the plugin
# resolves a name before a label too); empty when none. awk reads every
# line, so a plugin still answering never writes into a closed pipe.
hw_plugin_find() {
  # ENVIRON, not -v: -v would turn a backslash in the name into an escape.
  # `""` makes the comparison a string one: awk compares numeric-looking
  # values as numbers (1 == 01; macOS awk even takes nan == 1).
  hw_plugin_machines | HW_FIND="$1" awk -F'\t' '
    BEGIN { find = ENVIRON["HW_FIND"] "" }
    $3 == find && target == "" { target = $0 }
    $2 == find && label == ""  { label = $0 }
    END { if (target != "") print target; else if (label != "") print label }'
}

# hw_plugin_exec <bin> <target> <cmd> [args...] — the contract's exec; stdin
# is closed so it cannot eat a caller's loop input.
hw_plugin_exec() {
  local bin="$1" target="$2"
  shift 2
  "${bin}" exec "${target}" -- "$@" </dev/null
}

# hw_plugin_ensure <bin> <target> — the contract's ensure; its messages go to
# stderr.
hw_plugin_ensure() {
  "$1" ensure "$2" </dev/null >&2
}
