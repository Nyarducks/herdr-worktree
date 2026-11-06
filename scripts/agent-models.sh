#!/usr/bin/env bash
# Usage: agent-models.sh [--refresh] <kind> [models|efforts]
#
# Prints what --model / --effort accept for a worker agent kind, from a
# cache so the agent CLIs are not re-queried on every dispatch:
#   models   (default) TSV: <id> <TAB> <label> <TAB> <efforts, comma-separated>
#            (the efforts column is empty when the CLI does not report
#            per-model levels — the kind-wide list then applies)
#   efforts  one accepted --effort value per line; empty output means the
#            kind's effort cannot be set from the command line
#
# Kinds and sources:
#   claude  models: built-in alias/ID list (the CLI has no list command)
#           efforts: parsed from `claude --help`
#   agy     models: `agy models`; efforts: parsed from `agy --help`
#   codex   models + per-model efforts: `codex debug models` (JSON)
#           efforts: union of the listed models' levels
#   pi      models: `pi --list-models` (provider/id), with per-model levels
#           from custom models' `thinkingLevelMap` in
#           ${PI_CODING_AGENT_DIR:-~/.pi/agent}/models.json (null marks a
#           level unsupported; unmapped levels work through high, xhigh/max
#           only when mapped; reasoning=false leaves just off)
#           efforts: the `--thinking` levels parsed from `pi --help`
#   devin   models: `devin models list --format json` (needs `devin auth
#           login`; falls back to the documented aliases, uncached)
#           efforts: none — the CLI has no effort flag; the level is part
#           of the variant id (e.g. claude-opus-5-5-high, swe-2-max)
#
# Cache: ${AGENT_MODELS_CACHE_DIR:-${XDG_CACHE_HOME:-~/.cache}/herdr-worktree/agent-models}/<kind>.{models,efforts}
# An entry is rebuilt when missing, older than AGENT_MODELS_TTL_DAYS
# (default 7), or with --refresh. When a CLI is not installed, the built-in
# fallback lists are used and nothing is cached.
set -euo pipefail

readonly CLAUDE_MODELS='fable	Claude Fable (latest)
opus	Claude Opus (latest)
sonnet	Claude Sonnet (latest)
haiku	Claude Haiku (latest)
claude-fable-5-1	Claude Fable 5.1
claude-opus-5-5	Claude Opus 5.5
claude-sonnet-5-5	Claude Sonnet 5.5
claude-haiku-5-5	Claude Haiku 5.5	'
# https://docs.devin.ai/cli/models — aliases resolve to the family's latest.
readonly DEVIN_MODELS='opus	Anthropic Opus (latest)
sonnet	Anthropic Sonnet (latest)
swe	Cognition SWE (latest)
codex	OpenAI Codex (latest)
gpt	OpenAI GPT (latest)
gemini	Google Gemini (latest)	'
readonly DEFAULT_EFFORTS='low
medium
high
xhigh
max'

usage() {
  echo "Usage: $0 [--refresh] <claude|agy|codex|pi|devin> [models|efforts]" >&2
  exit 1
}

# ensure_node_on_path — pi is a node script; Homebrew's keg-only node@N is
# often on PATH only in interactive shells.
ensure_node_on_path() {
  command -v node > /dev/null 2>&1 && return 0
  local d
  for d in /opt/homebrew/opt/node*/bin /usr/local/opt/node*/bin; do
    if [[ -x "${d}/node" ]]; then
      PATH="${d}:${PATH}"
      return 0
    fi
  done
}

# help_efforts <help-text> <flag> — the level list on <flag>'s help line:
# "level: a, b, c" or "(a|b|c)" / "(a, b, c)". The description may wrap,
# so the following line is tried when the flag line itself has no list.
help_efforts() {
  local help_text="$1" flag="$2" block line
  block="$(grep -A1 -E -- "${flag}( |$)" <<< "${help_text}" || true)"
  while IFS= read -r line; do
    if [[ "${line}" =~ level:\ ([a-z]+(,\ ?[a-z]+)+) ]] ||
       [[ "${line}" =~ \(([a-z]+([|,]\ ?[a-z]+)+)\) ]]; then
      tr -c '[:lower:]' '\n' <<< "${BASH_REMATCH[1]}" | grep -v '^$'
      return 0
    fi
  done <<< "${block}"
}

# fetch_<kind> <models_out> <efforts_out> — query the CLI; non-zero when it
# is not installed (the caller then uses the fallback without caching).
fetch_claude() {
  command -v claude > /dev/null 2>&1 || return 1
  printf '%s\n' "${CLAUDE_MODELS}" > "$1"
  help_efforts "$(claude --help 2>&1)" "--effort" > "$2"
}

fetch_agy() {
  command -v agy > /dev/null 2>&1 || return 1
  agy models 2>/dev/null | awk -F'\t' 'NF >= 2 {print $1 "\t" $2 "\t"}' > "$1"
  help_efforts "$(agy --help 2>&1)" "--effort" > "$2"
}

fetch_codex() {
  command -v codex > /dev/null 2>&1 || return 1
  local json
  json="$(codex debug models 2>/dev/null)"
  jq -r '.models[] | select(.visibility != "hide")
         | [.slug, (.display_name // .slug),
            ([.supported_reasoning_levels[]?.effort] | join(","))] | @tsv' \
    <<< "${json}" > "$1"
  jq -r '(reduce (.models[] | select(.visibility != "hide")
                   | .supported_reasoning_levels[]?.effort) as $e
            ([]; if index([$e]) then . else . + [$e] end))[]' \
    <<< "${json}" > "$2"
}

fetch_pi() {
  ensure_node_on_path
  command -v pi > /dev/null 2>&1 || return 1
  # columns: provider model context max-out thinking images (header first)
  local listed per_model=""
  listed="$(pi --list-models 2>/dev/null |
    awk 'NR > 1 && NF >= 2 {print $1 "/" $2 "\t" $2 " (" $1 ")"}')"
  local models_json="${PI_CODING_AGENT_DIR:-${HOME}/.pi/agent}/models.json"
  if [[ -f "${models_json}" ]]; then
    per_model="$(jq -r '
      .providers // {} | to_entries[] | .key as $p | .value.models[]?
      | (.thinkingLevelMap // {}) as $m
      | [$p + "/" + .id,
         (if .reasoning == false then "off"
          else (["off"]
                + ([("minimal", "low", "medium", "high") as $l
                    | select(($m | has($l) | not) or $m[$l] != null) | $l])
                + ([("xhigh", "max") as $l
                    | select(($m | has($l)) and $m[$l] != null) | $l])
               ) | join(",")
          end)] | @tsv' "${models_json}" 2>/dev/null || true)"
  fi
  # join: listed models get their per-model levels when models.json has them
  awk -F'\t' 'NR == FNR {lv[$1] = $2; next} {print $1 "\t" $2 "\t" lv[$1]}' \
    <(printf '%s\n' "${per_model}") <(printf '%s\n' "${listed}") |
    grep -v '^\t' > "$1" || true
  help_efforts "$(pi --help 2>&1)" "--thinking" > "$2"
}

fetch_devin() {
  command -v devin > /dev/null 2>&1 || return 1
  local json
  json="$(devin models list --format json 2>/dev/null)" || return 1
  # {families: [{family_label, slug, aliases[], variants[{model_uid,
  # label}]}]} — every variant, then each family's slug and aliases (which
  # resolve to the family's latest variant).
  jq -r '.families[]
         | ((.variants[]? | [.model_uid, (.label // .model_uid), ""]),
            ((([.slug] + (.aliases // [])) | unique[]) as $a
             | select($a != null)
             | [$a, ((.family_label // $a) + " (latest)"), ""]))
         | @tsv' \
    <<< "${json}" | awk -F'\t' '!seen[$1]++' > "$1" 2>/dev/null || return 1
  [[ -s "$1" ]] || return 1
  : > "$2"
}

# fallback <kind> <models_out> <efforts_out> — built-in lists for a CLI
# that is not installed.
fallback() {
  case "$1" in
    claude) printf '%s\n' "${CLAUDE_MODELS}" > "$2"; printf '%s\n' "${DEFAULT_EFFORTS}" > "$3" ;;
    devin)  printf '%s\n' "${DEVIN_MODELS}" > "$2"; : > "$3" ;;
    *)      : > "$2"; : > "$3" ;;
  esac
}

# is_fresh <file> — exists and younger than the TTL.
is_fresh() {
  local file="$1" ttl_days="${AGENT_MODELS_TTL_DAYS:-7}"
  [[ -f "${file}" ]] || return 1
  [[ -z "$(find "${file}" -mtime "+${ttl_days}" 2>/dev/null)" ]]
}

main() {
  local refresh=0
  if [[ "${1:-}" == "--refresh" ]]; then
    refresh=1
    shift
  fi
  [[ $# -ge 1 && $# -le 2 ]] || usage
  local kind="$1" what="${2:-models}"
  [[ "${kind}" == "antigravity" ]] && kind="agy"
  case "${kind}" in claude|agy|codex|pi|devin) ;; *) usage ;; esac
  case "${what}" in models|efforts) ;; *) usage ;; esac

  local cache_dir="${AGENT_MODELS_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/herdr-worktree/agent-models}"
  local models_file="${cache_dir}/${kind}.models" efforts_file="${cache_dir}/${kind}.efforts"

  if [[ ${refresh} -eq 1 ]] || ! is_fresh "${models_file}" || ! is_fresh "${efforts_file}"; then
    mkdir -p "${cache_dir}"
    local tmp_models tmp_efforts
    tmp_models="$(mktemp "${models_file}.XXXXXX")"
    tmp_efforts="$(mktemp "${efforts_file}.XXXXXX")"
    if "fetch_${kind}" "${tmp_models}" "${tmp_efforts}"; then
      mv "${tmp_models}" "${models_file}"
      mv "${tmp_efforts}" "${efforts_file}"
    else
      fallback "${kind}" "${tmp_models}" "${tmp_efforts}"
      if [[ "${what}" == "models" ]]; then cat "${tmp_models}"; else cat "${tmp_efforts}"; fi
      rm -f "${tmp_models}" "${tmp_efforts}"
      return 0
    fi
  fi

  if [[ "${what}" == "models" ]]; then cat "${models_file}"; else cat "${efforts_file}"; fi
}

main "$@"
