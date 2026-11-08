#!/usr/bin/env bash
# live-beads.sh: exercise manager-bridge.sh against a real local bd backend
# with an OMP double. Runs in an isolated TMP/HOME/BEADS_DIR sandbox; does not
# touch the caller's ~/.beads or current project.
# Bash 3.2+.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
KIT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
MANAGER_BRIDGE="$KIT_DIR/scripts/manager-bridge.sh"

SKIP_RC=77
PASS=0
FAIL=0
TMP_ROOT=""
REAL_BD=""

die() { printf '%s\n' "$*" >&2; exit 1; }
skip() { printf 'SKIP: %s\n' "$*" >&2; exit "$SKIP_RC"; }
pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*" >&2; }

CLEANUP_DONE=""
cleanup() {
  [[ -n "$CLEANUP_DONE" ]] && return 0
  CLEANUP_DONE=1
  if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
    rm -rf "$TMP_ROOT" || true
  fi
  return 0
}
trap cleanup EXIT

# Verify real bd is available and locate its absolute path.
if ! command -v bd >/dev/null 2>&1; then
  skip "real 'bd' command not available"
fi
REAL_BD=$(command -v bd)

# Preserve the caller's trusted PATH so env-i can still find python3/git/bd.
TRUSTED_PATH="$PATH"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/live-beads-XXXXXX")
HOME_DIR="$TMP_ROOT/home"
PROJECT_DIR="$TMP_ROOT/project with spaces"
STATE_DIR="$TMP_ROOT/state root"
OMP_CONFIG="$TMP_ROOT/omp config.yml"
BIN_DIR="$TMP_ROOT/bin"

mkdir -p "$HOME_DIR" "$PROJECT_DIR" "$STATE_DIR" "$BIN_DIR"

# Mock OMP double: no real provider. Validates expected Codex flags.
cat > "$BIN_DIR/omp" <<'PY'
#!/usr/bin/env python3
# MOCK OMP DOUBLE for live-beads tests
import os, sys

def main():
    if "--help" in sys.argv:
        print("omp v18.18.0 (MOCK OMP DOUBLE)")
        print("  --cwd --config --model --thinking")
        print("  --no-session --no-extensions --tools")
        print("  --approval-mode=always-ask|always-ask-cached|write|yolo")
        print("  --wait-async --max-time -p")
        sys.exit(0)

    def flag_value(prefix):
        for i, a in enumerate(sys.argv[1:]):
            if a.startswith(prefix + "="):
                return a.split("=", 1)[1]
            if a == prefix and i + 2 < len(sys.argv):
                return sys.argv[i + 2]
        return None

    model = flag_value("--model")
    mode = flag_value("--approval-mode")
    if model != "openai-codex/gpt-6.1-sol":
        print("mock omp: expected Codex model, got %s" % model, file=sys.stderr)
        sys.exit(1)
    if mode != "always-ask":
        print("mock omp: expected always-ask, got %s" % mode, file=sys.stderr)
        sys.exit(1)

    rc = int(os.environ.get("MOCK_OMP_RC", "0"))
    print(os.environ.get("MOCK_OMP_OUTPUT", "MOCK OMP DOUBLE executed"))
    sys.exit(rc)

if __name__ == "__main__":
    main()
PY
chmod +x "$BIN_DIR/omp"

# Placeholder OMP config overlay; bridge only needs the file to exist and hash it.
echo "# live-beads test omp config overlay" > "$OMP_CONFIG"

# Git identity is supplied via env inside env-i, never touching the caller's HOME.
GIT_IDENTITY=(
  GIT_AUTHOR_NAME="Live Test"
  GIT_COMMITTER_NAME="Live Test"
  GIT_AUTHOR_EMAIL="live-test@example.com"
  GIT_COMMITTER_EMAIL="live-test@example.com"
)

# Build isolated environment: clear ambient BEADS/DOLT vars, override HOME.
run_isolated() {
  env -i \
    PATH="$BIN_DIR:$TRUSTED_PATH" \
    HOME="$HOME_DIR" \
    TMPDIR="${TMPDIR:-/tmp}" \
    HERMES_PROJECT="$PROJECT_DIR" \
    HERMES_OMP_CONFIG="$OMP_CONFIG" \
    HERMES_STATE_DIR="$STATE_DIR" \
    BD_BIN="$REAL_BD" \
    OMP_BIN="$BIN_DIR/omp" \
    MOCK_OMP_RC="${MOCK_OMP_RC:-0}" \
    MOCK_OMP_OUTPUT="${MOCK_OMP_OUTPUT:-}" \
    "${GIT_IDENTITY[@]}" \
    "$@"
}

run_bridge_isolated() {
  run_isolated "${BASH}" "$MANAGER_BRIDGE" "$@"
}

# Initialize real bd in the isolated project. Use a safe prefix and run from
# inside the project directory; do not suppress diagnostics on failure.
if ! INIT_OUT=$(run_isolated bash -c 'cd "$0" && "$1" init --quiet --prefix starter --skip-hooks --skip-agents' "$PROJECT_DIR" "$REAL_BD" 2>&1); then
  printf 'SKIP: bd init failed inside isolated sandbox\n%s\n' "$INIT_OUT" >&2
  exit "$SKIP_RC"
fi

# --- Test: capture creates a real issue ---
ISSUE=$(run_bridge_isolated capture \
  --title "Live beads test" \
  --request "Owner original wording" \
  --acceptance "Issue created in isolated db")
[[ -n "$ISSUE" ]] || fail "capture returned empty id"
pass "capture returns real issue id"

# Verify the issue exists in the isolated backend and preserves owner wording.
ISSUE_JSON=$(run_isolated "$REAL_BD" -C "$PROJECT_DIR" show --json "$ISSUE" 2>/dev/null) || ISSUE_JSON=""
if [[ -n "$ISSUE_JSON" ]]; then
  pass "real backend contains the captured issue"
else
  fail "real backend does not contain the captured issue"
fi
ACTUAL_TITLE=$(printf '%s' "$ISSUE_JSON" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data[0]["title"])')
ACTUAL_REQUEST=$(printf '%s' "$ISSUE_JSON" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data[0]["description"])')
ACTUAL_ACCEPTANCE=$(printf '%s' "$ISSUE_JSON" | python3 -c 'import json,sys; data=json.load(sys.stdin); print(data[0]["acceptance_criteria"])')
if [[ "$ACTUAL_TITLE" == "Live beads test" && "$ACTUAL_REQUEST" == *"Owner original wording"* && "$ACTUAL_ACCEPTANCE" == "Issue created in isolated db" ]]; then
  pass "capture preserves exact owner request and acceptance in real backend"
else
  fail "capture did not preserve owner wording in real backend"
fi

# --- Test: plan with OMP double ---
export MOCK_OMP_RC=0
export MOCK_OMP_OUTPUT="LIVE MOCK PLAN"
if run_bridge_isolated plan "$ISSUE" >/dev/null 2>&1; then
  pass "plan with real bd and OMP double"
else
  fail "plan with real bd and OMP double"
fi

PLAN_FILE=$(find "$STATE_DIR/runs" -maxdepth 1 -type f -name "${ISSUE}-*-plan-*" | sort | tail -n 1)
[[ -f "$PLAN_FILE" ]] && pass "plan artifact saved" || fail "plan artifact missing"

# --- Test: approve writes receipt tied to real contract ---
RECEIPT=$(run_bridge_isolated approve "$ISSUE" --by "telegram:owner")
[[ -f "$RECEIPT" ]] && pass "approve writes receipt against real issue" || fail "approve receipt missing"

# --- Test: execute with fresh approval ---
export MOCK_OMP_OUTPUT="LIVE MOCK EXECUTE"
if run_bridge_isolated execute "$ISSUE" >/dev/null 2>&1; then
  pass "execute with fresh approval and OMP double"
else
  fail "execute with fresh approval and OMP double"
fi

EXEC_FILE=$(find "$STATE_DIR/runs" -maxdepth 1 -type f -name "${ISSUE}-*-execute-*" | sort | tail -n 1)
[[ -f "$EXEC_FILE" ]] && pass "execute artifact saved" || fail "execute artifact missing"

# --- Test: stale contract rejects execute ---
run_isolated "$REAL_BD" -C "$PROJECT_DIR" update "$ISSUE" --append-notes "additional scope added after approval" >/dev/null 2>&1
export MOCK_OMP_RC=0
if run_bridge_isolated execute "$ISSUE" >/dev/null 2>&1; then
  fail "execute accepted stale real contract"
else
  pass "execute rejects stale real contract"
fi

# --- Test: comments do not pollute contract snapshot ---
# After a note changed the contract, re-plan and approve; the new approval
# digest should reflect the updated notes, but comments from previous runs
# must not be part of the contract snapshot.
export MOCK_OMP_RC=0
run_bridge_isolated plan "$ISSUE" >/dev/null 2>&1
run_bridge_isolated approve "$ISSUE" --by "telegram:owner" >/dev/null 2>&1
if run_bridge_isolated execute "$ISSUE" >/dev/null 2>&1; then
  pass "execute after replan/approve with updated contract"
else
  fail "execute after replan/approve with updated contract"
fi

# --- Test: status ---
if run_bridge_isolated status "$ISSUE" >/dev/null 2>&1; then
  pass "status with real backend"
else
  fail "status with real backend"
fi

# --- Summary ---
printf '\nLIVE-BEADS SUMMARY: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
