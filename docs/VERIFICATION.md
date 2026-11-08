# Verification methods and limits

This document records how the starter kit was checked and what remains unverified after this session.

## What has been observed

- Host OS: macOS 27.2, build 26B123, arm64.
- Shell: `/bin/bash` 3.2.57(1)-release.
- `omp --version`: 18.18.0.
- `bd version`: 1.2.2 (6c124203e main).
- `hermes --version`: Hermes Agent v0.23.0 (2026.9.24), stable.
- Python 3.14.6 available; `deaify` lint (`ailint.py`) and `tardis-type` checker (`typocheck.py`) respond to `--help`.

### Static checks

- Bash syntax checks passed: `/bin/bash -n scripts/manager-bridge.sh`, `/bin/bash -n scripts/check-kit.sh`, `/bin/bash -n tests/smoke.sh`, and `/bin/bash -n tests/live-beads.sh` all returned rc=0.
- Final typography check: four Markdown files passed (rc=0).
- Final ailint check: PASS (rc=0), seven factual enumeration warnings below the threshold.
- Security scan: heuristic pass plus manual root read of the allowlisted files. This is not proof that secrets are absent; it only confirms that no obvious credentials, tokens, or private temp paths were left in the shipped files.

### Schema validation

- Schema validation passed in an isolated temporary profile using the template as the global `config.yml`. `omp config get modelRoles --json`, `retry.fallbackChains`, `task.agentModelOverrides`, `tools.approvalMode`, and `enabledModels` returned rc=0 with values matching the contract. `omp config get tools.approval --json` also returned rc=0; the fixture allows read/grep/glob and prompts for bash/eval/task/write/edit. No auth or provider integration was performed.
- Running `omp --config templates/config.yml config get modelRoles` against the installed OMP 18.18.0 returned `{}`; this is not counted as overlay validation; schema validation used a separate isolated global fixture. Actual model integration remains untested.
- The SHA-256 of `templates/config.yml` matches the isolated global fixture. The hash value itself is omitted from this document.

### Defects fixed in this session

- Python 3 dependency in `scripts/manager-bridge.sh`: `realpath_canonical` and `KIT_CANONICAL` used `python3 -c '...'` for path canonicalization. On the observed macOS host the first `python3` in PATH produced no output for `python3 -c` while still exiting 0, so `PROJECT_CANONICAL` and `STATE_CANONICAL` became empty strings. The empty strings matched the `case` prefix test and the bridge failed with `error: HERMES_STATE_DIR must be outside HERMES_PROJECT`. Fix: reimplemented `realpath_canonical` in pure Bash 3.2 using `cd -P` and `pwd -P`; non-existent paths are resolved by walking up to the nearest existing ancestor, canonicalizing that ancestor, and appending the remaining tail while rejecting `.` and `..` components in the not-yet-created tail. `KIT_CANONICAL` now uses the same function. The remaining Python 3 calls (SHA-256 in `sha256_file`, JSON parsing in `fetch_contract_snapshot`, and contract digest) now explicitly check for non-empty output and non-zero exit status. `tests/smoke.sh` gained a regression test that places a fake `python3` (exits 0 with no output for `python3 -c`) first in PATH and verifies that `capture` still succeeds.

### Behavior checks

- `tests/smoke.sh`: final result 43 PASS, 0 FAIL. An earlier run produced 31 PASS and 2 FAIL; two incorrect smoke expectations were corrected and fresh-state/failure regression cases were added; the broken-python3 regression test was added after the fix.
- `tests/live-beads.sh`: final result 11 PASS, 0 FAIL. The initial isolated `bd init` failed and skip cleanup masked rc 77 as rc 1; the recipe and cleanup were corrected (explicit prefix and subshell), after which the final run was 11 PASS, 0 FAIL.
- `scripts/check-kit.sh`: final result manifest_files=11, sensitive_files=0, archive_members=11.
- Extra interpreter compatibility: `/opt/homebrew/bin/bash tests/smoke.sh` (Bash 5.3.9(1)-release, same macOS 27.2 arm64 host) also produced 43 PASS, 0 FAIL. This checks only the interpreter, not Linux or WSL2.

## Deviations observed during final verification

- `tests/live-beads.sh` failed on the observed host with the current PATH because the script makes direct `python3 -c` calls for JSON assertions and the first `python3` in PATH produced empty output. This script was not in the set allowed for modification for this task.
- `scripts/check-kit.sh` returned exit 0 with the current PATH but produced no output, because the broken `python3` silently executed the embedded Python block without printing anything. When run with a working `python3` first in PATH, it correctly reported that `hermes-beads-opencode-starter.tar.gz` members differ from disk for the four files changed during this fix; the archive was intentionally not rebuilt per task constraints.

## What has not been verified

- No real OMP provider auth has been performed.
- No live Hermes gateway or Telegram integration has been started.
- No clean install has been performed on a friend's machine.
- Linux and WSL2 behavior has not been verified.
- Actual runtime behavior of `manager-bridge.sh` with a live model provider remains untested.

## Tooling notes

- `shellcheck` is not installed on the observed host (`command -v shellcheck` exits 1), so it cannot be claimed as passing.
- Bash crapper, dryer, and mutator tools are not applicable to this Bash-based kit.
- Unsupported/undefined-behavior tool claims (for example `PASS` on shellcheck) will not be made.

## Honest limits

- Receipts and approvals are bookkeeping controls, not cryptographic guarantees. A user with write access to `HERMES_STATE_DIR` can forge a receipt.
- Prompts and instructions are not a security boundary.
- Subagent behavior in headless environments can be more permissive than the CLI `always-ask` setting. This kit prefers `always-ask`, but it cannot fully contain headless `yolo` behavior.
- This kit does not publish, deploy, or modify production systems. Those actions require separate owner approval outside the bridge.
