#!/usr/bin/env bats
# agent-models.bats — scripts/agent-models.sh against stubbed agent CLIs:
# per-kind model/effort parsing, caching (no re-query while fresh,
# --refresh and TTL expiry re-query), and fallbacks when a CLI is missing
# or not logged in.

# t, repo_root, stub_bin and the stubs' exports are set by helpers.bash,
# which shellcheck does not follow through `load`.
# shellcheck disable=SC2154
load helpers

# stub_agy <model-line> — replace the agy stub with one listing another model
stub_agy() {
  cat > "${stub_bin}/agy" <<STUB
#!/usr/bin/env bash
if [[ "\${1:-}" == "models" ]]; then
  printf '$1\n'
else
  echo "  --effort   Reasoning effort (low|high)"
fi
STUB
  chmod +x "${stub_bin}/agy"
}

setup() {
  common_setup
  stub_agent_clis
  am="${repo_root}/scripts/agent-models.sh"
}

teardown() {
  common_teardown
}

@test "per-kind parsing of models and efforts" {
  expect_eq "claude efforts" "$("${am}" claude efforts | tr '\n' ' ')" "low medium high xhigh max "
  expect_grep "claude models carry aliases" "$("${am}" claude)" "haiku"
  expect_eq "agy models" "$("${am}" agy | cut -f1)" "gemini-3.8-flash-medium"
  expect_eq "agy efforts" "$("${am}" agy efforts | tr '\n' ' ')" "low medium high xhigh max "
  expect_eq "codex models skip hidden" "$("${am}" codex | cut -f1 | tr '\n' ' ')" "gpt-6-luna gpt-6-sol "
  expect_eq "codex per-model efforts" "$("${am}" codex | awk -F'\t' '$1 == "gpt-6-sol" {print $3}')" "high,ultra"
  expect_eq "codex efforts union in order" "$("${am}" codex efforts | tr '\n' ' ')" "low high ultra "
  expect_eq "pi models are provider/id" "$("${am}" pi | cut -f1)" "mlx/org/Qwen-4bit"
  mkdir -p "${t}/pi-agent"
  cat > "${t}/pi-agent/models.json" <<'JSON'
{"providers":{"mlx":{"models":[{"id":"org/Qwen-4bit","reasoning":true,
  "thinkingLevelMap":{"minimal":null,"low":null,"medium":null,"high":"high","max":"max"}}]}}}
JSON
  expect_eq "pi per-model levels from thinkingLevelMap" \
    "$(PI_CODING_AGENT_DIR="${t}/pi-agent" "${am}" --refresh pi | cut -f3)" "off,high,max"
  expect_eq "pi thinking levels" "$("${am}" pi efforts | tr '\n' ' ')" "off minimal low medium high xhigh max "
  expect_eq "antigravity alias" "$("${am}" antigravity | cut -f1)" "gemini-3.8-flash-medium"
}

@test "devin: documented aliases when logged out, variants cached when logged in" {
  expect_grep "logged out -> documented aliases" "$("${am}" devin)" "swe"
  expect_file "logged out -> not cached" "${AGENT_MODELS_CACHE_DIR}/devin.models" absent
  expect_eq "devin has no efforts" "$("${am}" devin efforts)" ""
  expect_eq "logged in -> variants then family slug/aliases" \
    "$(DEVIN_STUB_LOGGED_IN=1 "${am}" devin | cut -f1 | tr '\n' ' ')" "swe-2-high swe-2-medium swe swe-2 "
  expect_grep "alias labelled as family latest" "$("${am}" devin)" "SWE-2 (latest)"
  expect_file "logged in -> cached" "${AGENT_MODELS_CACHE_DIR}/devin.models" exists
}

@test "cache: kept while fresh, re-queried on --refresh or expiry" {
  "${am}" agy > /dev/null   # fill the agy cache
  mv "${stub_bin}/agy" "${stub_bin}/agy.off"
  expect_eq "fresh cache answers without the CLI" "$("${am}" agy | cut -f1)" "gemini-3.8-flash-medium"
  mv "${stub_bin}/agy.off" "${stub_bin}/agy"

  stub_agy 'gemini-9-pro\tGemini 9 Pro'
  expect_eq "cache kept while fresh" "$("${am}" agy | cut -f1)" "gemini-3.8-flash-medium"
  expect_eq "--refresh re-queries" "$("${am}" --refresh agy | cut -f1)" "gemini-9-pro"
  touch -t 200001010000 "${AGENT_MODELS_CACHE_DIR}/agy.models"
  stub_agy 'gemini-10\tGemini 10'
  expect_eq "expired cache re-queries" "$("${am}" agy | cut -f1)" "gemini-10"
}

@test "missing CLI: fallback efforts, uncached; uninstalled agy lists nothing" {
  # PATH without any agent CLI (the real ones live outside /usr/bin:/bin);
  # bash itself is invoked by absolute path since macOS /bin/bash is 3.2.
  bare_bin="${t}/bare-bin"
  mkdir -p "${bare_bin}"
  out="$(PATH="${bare_bin}:/usr/bin:/bin" "${BASH}" "${am}" claude efforts | tr '\n' ' ')"
  expect_eq "claude fallback efforts" "${out}" "low medium high xhigh max "
  expect_file "fallback not cached" "${AGENT_MODELS_CACHE_DIR}/claude.models" absent
  out="$(PATH="${bare_bin}:/usr/bin:/bin" "${BASH}" "${am}" agy)"
  expect_eq "uninstalled agy -> empty list" "${out}" ""
}

@test "usage: no args, an unknown kind or view exits non-zero" {
  run "${am}"
  expect_rc "no args -> usage" "${status}" nz
  run "${am}" cline
  expect_rc "unknown kind -> usage" "${status}" nz
  run "${am}" claude bogus
  expect_rc "unknown view -> usage" "${status}" nz
}
