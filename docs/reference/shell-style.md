---
type: Reference
title: Shell Script Style Guide
description: Style conventions for everything under scripts/ and the hook scripts — safety header, variable naming, quoting, function scope.
status: current
last_modified: 2026-09-20
tags: [style, bash, conventions]
sources: []
---

Applies to everything under `scripts/` and the hook scripts.

## 1. Safety Header

Always start scripts with a standard bash shebang and strict execution
flags to fail fast on errors.

```bash
#!/usr/bin/env bash
set -euo pipefail
```

- `-e`: Exit immediately if a command exits with a non-zero status.
- `-u`: Treat unset variables as an error and exit immediately.
- `-o pipefail`: Return the exit status of the last command in the
  pipeline that failed.

## 2. Variable Naming Conventions

### Constants and Environment Variables

Use **UPPERCASE** snake_case. Mark read-only constants explicitly.

```bash
readonly DEFAULT_PORT=8080
export API_ENDPOINT="https://api.example.com"
```

### Internal and Local Variables

Use **lowercase** snake_case. This avoids accidental collisions with
system environment variables (e.g., `PATH`, `USER`, `HOME`).

```bash
local file_name="$1"
user_count=0
```

## 3. Variable Expansion and Quoting

### Double Quoting

Always wrap variable references in double quotes (`"..."`) to prevent
word splitting and globbing issues caused by spaces or special
characters.

```bash
# Correct
rm -- "$target_file"

# Incorrect (vulnerable to word splitting)
rm -- $target_file
```

### Braces Usage (`${var}`)

Braces are optional for simple references, but mandatory in the
following cases:

- **Concatenation**: When appending characters directly to the variable
  name.

  ```bash
  output_file="${base_name}_backup.tar.gz"
  ```

- **Array indexing**:

  ```bash
  echo "${my_array[0]}"
  ```

- **Parameter expansion**:

  ```bash
  echo "${timeout:-30}"
  ```

## 4. Functions and Scope

- Define functions without the `function` keyword:
  `function_name() { ... }`.
- Declare internal variables inside functions with the `local` keyword.

```bash
process_item() {
  local item_id="$1"
  local temp_dir="/tmp/work_${item_id}"

  echo "Processing item: ${item_id} in ${temp_dir}"
}
```

## 5. Lint Annotations

`bash scripts/lint.sh` runs shellcheck over every shell file. Suppress a
warning only when the flagged pattern is intentional, and always write
the reason in a comment on the line above the directive — a bare
`disable=` reads as "nobody checked this".

```bash
# $path is a jq variable, not shell — single quotes are intentional
# shellcheck disable=SC2016
jq '.projects[$path].x = true'

# Prefer `source=` over `disable=SC1090/SC1091` for dynamic sources —
# it names the file (or /dev/null) and lets -x keep following real ones.
# shellcheck source=scripts/lib/helper.sh
source "${script_root}/scripts/lib/helper.sh"
```

## 6. Quick Reference Template

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly LOG_DIR="/var/log/app"
readonly MAX_RETRIES=3

backup_logs() {
  local target_app="$1"
  local destination_archive="${LOG_DIR}/${target_app}_archive.tar.gz"

  echo "Creating archive: ${destination_archive}"
}

backup_logs "service-a"
```
