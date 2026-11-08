#!/usr/bin/env bash
# smoke.sh: exercise manager-bridge.sh with explicitly labeled CLI doubles.
# No real provider or Beads backend is used. Bash 3.2+.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
KIT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
MANAGER_BRIDGE="$KIT_DIR/scripts/manager-bridge.sh"

PASS=0
FAIL=0
TMP_ROOT=""
OMP_LAUNCH_FILE=""
PYTHON3=""

die() { printf '%s\n' "$*" >&2; exit 1; }

# Locate a python3 that can actually execute one-liners. The first python3 in
# the caller's PATH may be the broken one we are regression-testing, so we need
# a known-good interpreter for the mock doubles and JSON assertions.
find_working_python3() {
  local p candidates
  candidates=(/opt/homebrew/bin/python3 /usr/bin/python3 /usr/local/bin/python3)
  p=$(command -v python3 2>/dev/null || true)
  [[ -n "$p" ]] && candidates+=("$p")
  for p in "${candidates[@]}"; do
    if [[ -x "$p" ]] && "$p" -c 'import sys; sys.stdout.write("1\n")' >/dev/null 2>&1; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  return 1
}

replace_shebang() {
  local file="$1" interp="$2"
  local tmp="${file}.tmp.$$"
  { printf '#!%s\n' "$interp"; tail -n +2 "$file"; } > "$tmp"
  mv "$tmp" "$file"
  chmod +x "$file"
}

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$*" >&2; }

cleanup() {
  [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/smoke-XXXXXX")
BIN_DIR="$TMP_ROOT/bin"
PROJECT_A="$TMP_ROOT/project with spaces A"
PROJECT_B="$TMP_ROOT/project B"
STATE_DIR="$TMP_ROOT/state root"
REL_STATE_DIR="$TMP_ROOT/relative state"
OMP_CONFIG="$TMP_ROOT/omp config.yml"
MOCK_DB="$TMP_ROOT/mock_bd.json"
OMP_LAUNCH_FILE="$TMP_ROOT/omp_launches.txt"

mkdir -p "$BIN_DIR" "$PROJECT_A" "$PROJECT_B"
echo "model: opencode-go/kimi-k2.7-code" > "$OMP_CONFIG"

PYTHON3=$(find_working_python3) || die "no working python3 found for test doubles"
ln -sfn "$PYTHON3" "$BIN_DIR/python3"

# Write mock bd (Python): explicitly labeled, strict API.
cat > "$BIN_DIR/bd" <<'PY'
#!/usr/bin/env python3
# MOCK BD DOUBLE for smoke tests
import json, os, sys, random

def db_path():
    return os.environ.get("MOCK_BD_DB", os.path.join(os.getcwd(), ".mock_bd.json"))

def load_db():
    p = db_path()
    if os.path.exists(p):
        with open(p) as f:
            return json.load(f)
    return {}

def save_db(db):
    p = db_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w") as f:
        json.dump(db, f)

def gen_id():
    return "smoke_%s-%03d" % (os.urandom(4).hex(), random.randint(0, 999))

def cmd_create(args):
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--silent", action="store_true")
    p.add_argument("--title", required=True)
    p.add_argument("--description", required=True)
    p.add_argument("--acceptance", required=True)
    p.add_argument("--labels", required=True)
    p.add_argument("--type", default="task")
    p.add_argument("--priority", default="2")
    ns = p.parse_args(args)
    db = load_db()
    iid = gen_id()
    db[iid] = {
        "id": iid,
        "title": ns.title,
        "description": ns.description,
        "acceptance_criteria": ns.acceptance,
        "notes": "",
        "priority": int(ns.priority),
        "issue_type": ns.type,
        "status": "open",
        "labels": [x.strip() for x in ns.labels.split(",") if x.strip()],
        "comments": [],
        "comment_count": 0,
    }
    save_db(db)
    if ns.silent:
        print(iid)

def cmd_show(args):
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--json", action="store_true")
    p.add_argument("id")
    ns = p.parse_args(args)
    if not ns.id:
        print("show needs id", file=sys.stderr)
        sys.exit(1)
    db = load_db()
    if ns.id not in db:
        print("unknown issue", file=sys.stderr)
        sys.exit(1)
    rec = db[ns.id]
    if ns.json:
        print(json.dumps([rec], sort_keys=True, ensure_ascii=False))
    else:
        print("Issue: %s" % rec["id"])
        print("Title: %s" % rec["title"])
        print("Description: %s" % rec["description"])
        print("Acceptance: %s" % rec["acceptance_criteria"])
        print("Notes: %s" % rec["notes"])

def cmd_comments(args):
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("sub")
    p.add_argument("id")
    p.add_argument("text", nargs="*")
    p.add_argument("--file")
    p.add_argument("--stdin", action="store_true")
    ns = p.parse_args(args)
    if ns.sub != "add":
        print("comments only supports add", file=sys.stderr)
        sys.exit(2)
    text = " ".join(ns.text) if ns.text else ""
    if ns.file:
        with open(ns.file) as f:
            text = f.read()
    if ns.stdin:
        text = sys.stdin.read()
    db = load_db()
    if ns.id not in db:
        print("unknown issue", file=sys.stderr)
        sys.exit(1)
    rc = int(os.environ.get("MOCK_BD_COMMENT_RC", "0"))
    if rc != 0:
        print("mock bd comment failure", file=sys.stderr)
        sys.exit(rc)
    db[ns.id]["comments"].append(text)
    db[ns.id]["comment_count"] = len(db[ns.id]["comments"])
    save_db(db)
    print("Comment added to %s" % ns.id)

def cmd_note(args):
    if len(args) < 2:
        print("note needs id and text", file=sys.stderr)
        sys.exit(1)
    iid = args[0]
    text = " ".join(args[1:])
    db = load_db()
    if iid not in db:
        print("unknown issue", file=sys.stderr)
        sys.exit(1)
    db[iid]["notes"] = (db[iid]["notes"] or "") + "\n" + text
    save_db(db)
    print("Note added to %s" % iid)

def main():
    args = sys.argv[1:]
    # Consume global -C flag.
    while args and args[0] in ("-C", "--directory"):
        if len(args) < 2:
            print("-C needs value", file=sys.stderr)
            sys.exit(2)
        args = args[2:]
    if not args:
        print("mock bd: no command", file=sys.stderr)
        sys.exit(2)
    cmd = args[0]
    rest = args[1:]
    if cmd == "create":
        cmd_create(rest)
    elif cmd in ("show", "view"):
        cmd_show(rest)
    elif cmd == "comments":
        cmd_comments(rest)
    elif cmd == "note":
        cmd_note(rest)
    else:
        print("mock bd: unsupported command %s" % cmd, file=sys.stderr)
        sys.exit(2)

if __name__ == "__main__":
    main()
PY
chmod +x "$BIN_DIR/bd"
replace_shebang "$BIN_DIR/bd" "$BIN_DIR/python3"

# Write mock omp (Python): explicitly labeled.
cat > "$BIN_DIR/omp" <<'PY'
#!/usr/bin/env python3
# MOCK OMP DOUBLE for smoke tests
import os, sys

def record_launch():
    f = os.environ.get("OMP_LAUNCH_FILE", "/tmp/mock_omp_launches")
    with open(f, "a") as fh:
        print("launch", file=fh)

def main():
    if "--help" in sys.argv:
        print("omp v18.18.0 (MOCK OMP DOUBLE)")
        print("  --cwd --config --model --thinking")
        print("  --no-session --no-extensions --tools")
        print("  --approval-mode=always-ask|always-ask-cached|write|yolo")
        print("  --wait-async --max-time -p")
        sys.exit(0)

    args = sys.argv[1:]
    record_launch()

    def has_flag(prefix):
        for a in args:
            if a.startswith(prefix + "=") or a == prefix:
                return True
        return False

    def flag_value(prefix):
        for i, a in enumerate(args):
            if a.startswith(prefix + "="):
                return a.split("=", 1)[1]
            if a == prefix and i + 1 < len(args):
                return args[i + 1]
        return None

    required = ["--cwd", "--config", "--model", "--approval-mode"]
    for r in required:
        if not has_flag(r):
            print("mock omp: missing %s" % r, file=sys.stderr)
            sys.exit(1)

    model = flag_value("--model")
    if model != "openai-codex/gpt-6.1-sol":
        print("mock omp: wrong model %s" % model, file=sys.stderr)
        sys.exit(1)

    mode = flag_value("--approval-mode")
    if mode != "always-ask":
        print("mock omp: wrong approval-mode %s" % mode, file=sys.stderr)
        sys.exit(1)

    rc = int(os.environ.get("MOCK_OMP_RC", "0"))
    print(os.environ.get("MOCK_OMP_OUTPUT", "MOCK OMP DOUBLE executed"))
    sys.exit(rc)

if __name__ == "__main__":
    main()
PY
chmod +x "$BIN_DIR/omp"
replace_shebang "$BIN_DIR/omp" "$BIN_DIR/python3"

# Mock tee to simulate tee failure when requested.
cat > "$BIN_DIR/tee" <<'EOF'
#!/usr/bin/env bash
if [[ -n "${MOCK_TEE_RC:-}" ]]; then
  # still consume stdin
  cat >/dev/null
  exit "$MOCK_TEE_RC"
fi
exec /usr/bin/tee "$@"
EOF
chmod +x "$BIN_DIR/tee"

# Mock OMP that only advertises cached approval mode (no always-ask).
cat > "$BIN_DIR/omp_cached" <<'PY'
#!/usr/bin/env python3
# MOCK OMP CACHED-ONLY DOUBLE
import os, sys

def main():
    if "--help" in sys.argv:
        print("omp v18.18.0 (MOCK OMP CACHED-ONLY DOUBLE)")
        print("  --cwd --config --model --thinking")
        print("  --no-session --no-extensions --tools")
        print("  --approval-mode=always-ask-cached|write|yolo")
        print("  --wait-async --max-time -p")
        sys.exit(0)

    # This double should never be asked to run a real provider task.
    print("mock omp cached-only: unexpected provider launch", file=sys.stderr)
    sys.exit(99)

if __name__ == "__main__":
    main()
PY
chmod +x "$BIN_DIR/omp_cached"
replace_shebang "$BIN_DIR/omp_cached" "$BIN_DIR/python3"

export PATH="$BIN_DIR:$PATH"
export BD_BIN="$BIN_DIR/bd"
export OMP_BIN="$BIN_DIR/omp"
export OMP_LAUNCH_FILE="$OMP_LAUNCH_FILE"
export MOCK_BD_DB="$MOCK_DB"

HERMES_PROJECT="$PROJECT_A"
HERMES_OMP_CONFIG="$OMP_CONFIG"
HERMES_STATE_DIR="$STATE_DIR"

run_bridge() {
  env \
    HERMES_PROJECT="$HERMES_PROJECT" \
    HERMES_OMP_CONFIG="$HERMES_OMP_CONFIG" \
    HERMES_STATE_DIR="$HERMES_STATE_DIR" \
    BD_BIN="$BD_BIN" \
    OMP_BIN="$OMP_BIN" \
    OMP_LAUNCH_FILE="$OMP_LAUNCH_FILE" \
    "${BASH}" "$MANAGER_BRIDGE" "$@"
}

omp_launches() {
  if [[ -f "$OMP_LAUNCH_FILE" ]]; then
    wc -l < "$OMP_LAUNCH_FILE" | tr -d ' '
  else
    printf '0'
  fi
}

expect_failure() {
  local name="$1"
  shift
  local expected_rc="${1:-}"
  shift
  local launches_before launches_after rc
  launches_before=$(omp_launches)
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  launches_after=$(omp_launches)
  if [[ "$rc" == "$expected_rc" && "$launches_before" == "$launches_after" ]]; then
    pass "$name (rc=$rc, no omp launch)"
  else
    fail "$name: expected rc=$expected_rc no launch, got rc=$rc launches $launches_before->$launches_after"
  fi
}

expect_rc() {
  local name="$1" expected_rc="$2"
  shift 2
  local rc
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  if [[ "$rc" == "$expected_rc" ]]; then
    pass "$name (rc=$rc)"
  else
    fail "$name: expected rc=$expected_rc, got $rc"
  fi
}

# --- Test: help ---
if "$MANAGER_BRIDGE" help >/dev/null 2>&1; then
  pass "help returns 0"
else
  fail "help returns nonzero"
fi

# --- Test: capture preserves Unicode owner wording ---
ORIG_TITLE="Smoke test"
ORIG_REQUEST="Owner wording with spaces and Unicode: привет мир"
ORIG_ACCEPTANCE="Observable acceptance: создано"
ISSUE_A=$(run_bridge capture \
  --title "$ORIG_TITLE" \
  --request "$ORIG_REQUEST" \
  --acceptance "$ORIG_ACCEPTANCE")
[[ -n "$ISSUE_A" ]] || fail "capture did not return id"

SAVED_TITLE=$($PYTHON3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]]["title"])' "$MOCK_DB" "$ISSUE_A")
SAVED_REQUEST=$($PYTHON3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]]["description"])' "$MOCK_DB" "$ISSUE_A")
SAVED_ACCEPTANCE=$($PYTHON3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[sys.argv[2]]["acceptance_criteria"])' "$MOCK_DB" "$ISSUE_A")
if [[ "$SAVED_TITLE" == "$ORIG_TITLE" && "$SAVED_REQUEST" == *"$ORIG_REQUEST"* && "$SAVED_ACCEPTANCE" == "$ORIG_ACCEPTANCE" ]]; then
  pass "capture preserves original owner wording"
else
  fail "capture did not preserve wording"
fi

# --- Test: capture tolerates a broken python3 first in PATH ---
# The bridge must not rely on python3 for path canonicalization. Simulate the
# observed failure mode: python3 -c exits 0 and prints nothing.
BROKEN_PYTHON_DIR="$TMP_ROOT/broken-python"
mkdir -p "$BROKEN_PYTHON_DIR"
cat > "$BROKEN_PYTHON_DIR/python3" <<'EOF'
#!/bin/sh
# FAKE BROKEN python3: the observed failure mode on the owner's host.
# python3 -c exits 0 with no output; script execution is not exercised here.
exit 0
EOF
chmod +x "$BROKEN_PYTHON_DIR/python3"

run_bridge_broken_python() {
  env \
    HERMES_PROJECT="$HERMES_PROJECT" \
    HERMES_OMP_CONFIG="$HERMES_OMP_CONFIG" \
    HERMES_STATE_DIR="$HERMES_STATE_DIR" \
    BD_BIN="$BD_BIN" \
    OMP_BIN="$OMP_BIN" \
    OMP_LAUNCH_FILE="$OMP_LAUNCH_FILE" \
    PATH="$BROKEN_PYTHON_DIR:$PATH" \
    "${BASH}" "$MANAGER_BRIDGE" "$@"
}

ISSUE_BROKEN=$(run_bridge_broken_python capture \
  --title "Broken python3 regression" \
  --request "Owner wording" \
  --acceptance "Issue created despite broken python3")
[[ -n "$ISSUE_BROKEN" ]] && pass "capture works with broken python3 first in PATH" || \
  fail "capture failed with broken python3 first in PATH"

# --- Test: plan happy ---
export MOCK_OMP_RC=0
export MOCK_OMP_OUTPUT="MOCK PLAN"
run_bridge plan "$ISSUE_A" >/dev/null 2>&1
PLAN_FILE=$(find "$STATE_DIR/runs" -maxdepth 1 -type f -name "${ISSUE_A}-*-plan-*" | sort | tail -n 1)
[[ -f "$PLAN_FILE" ]] && pass "plan creates artifact" || fail "plan artifact missing"
[[ -f "$STATE_DIR/approvals/$ISSUE_A.plan" ]] && pass "plan writes current-plan metadata" || fail "plan metadata missing"

# --- Test: approve ---
RECEIPT=$(run_bridge approve "$ISSUE_A" --by "telegram:owner")
[[ -f "$RECEIPT" ]] && pass "approve writes receipt" || fail "approve receipt missing"

# --- Test: execute with approval ---
export MOCK_OMP_OUTPUT="MOCK EXECUTE"
run_bridge execute "$ISSUE_A" >/dev/null 2>&1 && pass "execute with fresh approval" || fail "execute with fresh approval"

# --- Test: execute without approval (different issue) ---
ISSUE_B=$(run_bridge capture --title "B" --request "r" --acceptance "a")
expect_failure "execute without approval" 2 run_bridge execute "$ISSUE_B"

# --- Test: wrong/nonexistent issue id ---
expect_failure "plan rejects unknown issue" 2 run_bridge plan "nosuch"
expect_failure "execute rejects unknown issue" 2 run_bridge execute "nosuch"

# --- Test: copied receipt wrong issue ---
FAKE_RECEIPT="$STATE_DIR/approvals/$ISSUE_B"
cp "$RECEIPT" "$FAKE_RECEIPT"
expect_failure "execute rejects receipt copied to wrong issue" 2 run_bridge execute "$ISSUE_B"
rm -f "$FAKE_RECEIPT"

# --- Test: cross-project / wrong shared state ---
HERMES_PROJECT="$PROJECT_B"
expect_failure "execute rejects cross-project stale approval" 2 run_bridge execute "$ISSUE_A"
HERMES_PROJECT="$PROJECT_A"

# --- Test: state dir inside kit rejected without mutation ---
KIT_STATE="$KIT_DIR/state"
HERMES_STATE_DIR="$KIT_STATE"
expect_failure "state dir inside kit rejected" 2 run_bridge plan "$ISSUE_A"
[[ ! -d "$KIT_STATE" ]] && pass "state dir inside kit not created" || fail "state dir inside kit was created"
HERMES_STATE_DIR="$STATE_DIR"

# --- Test: failed plan invalidates prior approval ---
export MOCK_OMP_RC=1
export MOCK_OMP_OUTPUT="MOCK PLAN FAILURE"
LAUNCHES_BEFORE=$(omp_launches)
expect_rc "failed plan returns nonzero" 1 run_bridge plan "$ISSUE_A"
LAUNCHES_AFTER=$(omp_launches)
if [[ "$((LAUNCHES_AFTER - LAUNCHES_BEFORE))" -eq 1 ]]; then
  pass "failed plan launched provider exactly once"
else
  fail "failed plan provider launch count $LAUNCHES_BEFORE->$LAUNCHES_AFTER"
fi
[[ ! -f "$STATE_DIR/approvals/$ISSUE_A" ]] && pass "failed plan removed approval receipt" || fail "failed plan left approval receipt"
[[ ! -f "$STATE_DIR/approvals/$ISSUE_A.plan" ]] && pass "failed plan removed plan metadata" || fail "failed plan left plan metadata"

# --- Test: approve after failed plan rejected ---
expect_failure "approve rejects after failed plan" 2 run_bridge approve "$ISSUE_A" --by "x"

# --- Test: replan with missing config invalidates prior approval and does not launch ---
export MOCK_OMP_RC=0
run_bridge plan "$ISSUE_A" >/dev/null 2>&1
run_bridge approve "$ISSUE_A" --by "telegram:owner" >/dev/null 2>&1
mv "$OMP_CONFIG" "$OMP_CONFIG.bak"
LAUNCHES_BEFORE=$(omp_launches)
expect_failure "replan rejects missing config before launch" 2 run_bridge plan "$ISSUE_A"
LAUNCHES_AFTER=$(omp_launches)
if [[ "$LAUNCHES_BEFORE" == "$LAUNCHES_AFTER" ]]; then
  pass "missing-config replan did not launch provider"
else
  fail "missing-config replan launched provider $LAUNCHES_BEFORE->$LAUNCHES_AFTER"
fi
[[ ! -f "$STATE_DIR/approvals/$ISSUE_A" ]] && pass "missing-config replan removed approval receipt" || fail "missing-config replan left approval receipt"
[[ ! -f "$STATE_DIR/approvals/$ISSUE_A.plan" ]] && pass "missing-config replan removed plan metadata" || fail "missing-config replan left plan metadata"
mv "$OMP_CONFIG.bak" "$OMP_CONFIG"

# Re-plan for further tests.
export MOCK_OMP_RC=0
run_bridge plan "$ISSUE_A" >/dev/null 2>&1

# --- Test: approve after config changed since plan ---
echo "# extra config line" >> "$OMP_CONFIG"
expect_failure "approve rejects stale config since plan" 2 run_bridge approve "$ISSUE_A" --by "x"
# restore config
echo "model: opencode-go/kimi-k2.7-code" > "$OMP_CONFIG"

# Re-plan after config restore.
run_bridge plan "$ISSUE_A" >/dev/null 2>&1

# --- Test: approve after scope changed since plan ---
"$BD_BIN" -C "$PROJECT_A" note "$ISSUE_A" "scope creep"
expect_failure "approve rejects stale contract since plan" 2 run_bridge approve "$ISSUE_A" --by "x"

# Re-plan after scope change and approve for execute tests.
run_bridge plan "$ISSUE_A" >/dev/null 2>&1
run_bridge approve "$ISSUE_A" --by "telegram:owner" >/dev/null 2>&1

# --- Test: stale plan artifact rejects execute ---
PLAN_FILE=""
if [[ -f "$STATE_DIR/approvals/$ISSUE_A.plan" ]]; then
  while IFS='=' read -r key value; do
    [[ "$key" == "plan_path" ]] && PLAN_FILE="$value"
  done < "$STATE_DIR/approvals/$ISSUE_A.plan"
fi
if [[ -f "$PLAN_FILE" ]]; then
  echo "tampered" >> "$PLAN_FILE"
  expect_failure "execute rejects stale plan artifact" 2 run_bridge execute "$ISSUE_A"
  # restore for later tests
  export MOCK_OMP_RC=0
  run_bridge plan "$ISSUE_A" >/dev/null 2>&1
  run_bridge approve "$ISSUE_A" --by "telegram:owner" >/dev/null 2>&1
else
  fail "plan artifact missing for stale plan test"
fi

# --- Test: stale issue contract rejects execute ---
"$BD_BIN" -C "$PROJECT_A" note "$ISSUE_A" "new scope note"
expect_failure "execute rejects stale issue contract" 2 run_bridge execute "$ISSUE_A"

# Re-plan and approve.
run_bridge plan "$ISSUE_A" >/dev/null 2>&1
run_bridge approve "$ISSUE_A" --by "telegram:owner" >/dev/null 2>&1

# --- Test: cached-only approval mode rejected before provider launch ---
LAUNCHES_BEFORE=$(omp_launches)
OMP_BIN="$BIN_DIR/omp_cached" expect_failure "plan rejects cached-only approval mode" 2 run_bridge plan "$ISSUE_A"
LAUNCHES_AFTER=$(omp_launches)
if [[ "$LAUNCHES_BEFORE" == "$LAUNCHES_AFTER" ]]; then
  pass "cached-only mode did not launch provider"
else
  fail "cached-only mode launched provider $LAUNCHES_BEFORE->$LAUNCHES_AFTER"
fi

# Re-plan after cached-only rejection.
run_bridge plan "$ISSUE_A" >/dev/null 2>&1
run_bridge approve "$ISSUE_A" --by "telegram:owner" >/dev/null 2>&1

# --- Test: nonzero omp rc propagated ---
export MOCK_OMP_RC=42
export MOCK_OMP_OUTPUT="MOCK PLAN FAILURE 42"
expect_rc "nonzero omp rc propagated" 42 run_bridge plan "$ISSUE_A"

# --- Test: tee failure propagated ---
export MOCK_OMP_RC=0
export MOCK_TEE_RC=3
expect_rc "tee failure propagated" 3 run_bridge plan "$ISSUE_A"
export MOCK_TEE_RC=""

# --- Test: Beads comment error propagated ---
export MOCK_BD_COMMENT_RC=7
# plan succeeds, but comment fails -> command rc should be 7.
expect_rc "beads comment error propagated" 7 run_bridge plan "$ISSUE_A"
export MOCK_BD_COMMENT_RC=0

# --- Test: relative paths and spaces with separate state ---
REL_PROJECT="./relative project"
mkdir -p "$TMP_ROOT/rel/$REL_PROJECT"
cd "$TMP_ROOT/rel"
HERMES_PROJECT="$REL_PROJECT"
HERMES_STATE_DIR="$REL_STATE_DIR"
export MOCK_OMP_RC=0
ISSUE_REL=$(run_bridge capture --title "Rel" --request "r" --acceptance "a")
[[ -n "$ISSUE_REL" ]] && pass "capture with relative path and spaces" || fail "capture relative path"
if run_bridge plan "$ISSUE_REL" >/dev/null 2>&1; then
  pass "plan with relative path and spaces"
else
  fail "plan with relative path and spaces"
fi
cd "$KIT_DIR"

# Restore absolute paths for symlink test.
HERMES_PROJECT="$PROJECT_A"
HERMES_STATE_DIR="$STATE_DIR"

# --- Test: symlink spelling canonicalization ---
# Ensure approval exists for ISSUE_A via real path.
run_bridge plan "$ISSUE_A" >/dev/null 2>&1
run_bridge approve "$ISSUE_A" --by "telegram:owner" >/dev/null 2>&1
SYMLINK_PROJECT="$TMP_ROOT/symlink-project"
ln -sfn "$PROJECT_A" "$SYMLINK_PROJECT"
HERMES_PROJECT="$SYMLINK_PROJECT"
export MOCK_OMP_RC=0
if run_bridge execute "$ISSUE_A" >/dev/null 2>&1; then
  pass "symlink spelling resolves to canonical project"
else
  fail "symlink spelling rejected"
fi
HERMES_PROJECT="$PROJECT_A"

# --- Test: invalid issue id rejected before path use ---
expect_failure "plan rejects path-traversal-like id" 2 run_bridge plan "../etc/passwd"

# --- Test: state lock concurrency gate ---
mkdir -p "$STATE_DIR/.lock"
expect_failure "bridge rejects held state lock" 2 run_bridge plan "$ISSUE_A"
rmdir "$STATE_DIR/.lock"

# --- Test: status ---
if run_bridge status "$ISSUE_A" >/dev/null 2>&1; then
  pass "status works"
else
  fail "status failed"
fi

# --- Test: check-kit scanner negative fixture ---
CHECK_KIT="$KIT_DIR/scripts/check-kit.sh"
BUILTIN_MANIFEST="README.md
MANIFEST.txt
scripts/manager-bridge.sh
scripts/check-kit.sh
tests/smoke.sh
tests/live-beads.sh
templates/config.yml
templates/AGENTS.md
templates/bridge.env.example
skills/hermes-beads-manager/SKILL.md
docs/VERIFICATION.md"

FAKE_KIT=$(mktemp -d "${TMPDIR:-/tmp}/fake-kit-XXXXXX")
mkdir -p "$FAKE_KIT/scripts" "$FAKE_KIT/tests" "$FAKE_KIT/templates" \
         "$FAKE_KIT/skills/hermes-beads-manager" "$FAKE_KIT/docs"
printf '%s' "$BUILTIN_MANIFEST" > "$FAKE_KIT/MANIFEST.txt"
for f in $(printf '%s' "$BUILTIN_MANIFEST"); do
  [[ "$f" == "MANIFEST.txt" ]] && continue
  touch "$FAKE_KIT/$f"
done

if "${BASH}" "$CHECK_KIT" "$FAKE_KIT" >/dev/null 2>&1; then
  pass "check-kit accepts valid fake kit"
else
  fail "check-kit rejected valid fake kit"
fi

# Extra file should fail.
echo "extra" > "$FAKE_KIT/extra.txt"
if "${BASH}" "$CHECK_KIT" "$FAKE_KIT" >/dev/null 2>&1; then
  fail "check-kit accepted extra file"
else
  pass "check-kit rejects extra file"
fi
rm -f "$FAKE_KIT/extra.txt"

# Symlink should fail.
ln -sfn "README.md" "$FAKE_KIT/scripts/link"
if "${BASH}" "$CHECK_KIT" "$FAKE_KIT" >/dev/null 2>&1; then
  fail "check-kit accepted symlink"
else
  pass "check-kit rejects symlink"
fi
rm -f "$FAKE_KIT/scripts/link"

# Sensitive content should fail and report path only.
printf 'sk-%s\n' "abcdefghijklmnopqrstuvwxyz1234567890" > "$FAKE_KIT/README.md"
if "${BASH}" "$CHECK_KIT" "$FAKE_KIT" >/dev/null 2>&1; then
  fail "check-kit accepted sensitive string"
else
  pass "check-kit rejects sensitive string"
fi

# Bad archive should fail.
printf '%s' "$BUILTIN_MANIFEST" > "$FAKE_KIT/MANIFEST.txt"
for f in $(printf '%s' "$BUILTIN_MANIFEST"); do
  [[ "$f" == "MANIFEST.txt" ]] && continue
  echo "content $f" > "$FAKE_KIT/$f"
done
# Create a tar.gz with one altered member and local uid.
(
  cd "$FAKE_KIT"
  tar -czf "hermes-beads-opencode-starter.tar.gz" \
    --owner=12345 --group=12345 \
    README.md scripts/check-kit.sh tests/smoke.sh 2>/dev/null || true
)
if "${BASH}" "$CHECK_KIT" "$FAKE_KIT" >/dev/null 2>&1; then
  fail "check-kit accepted bad archive"
else
  pass "check-kit rejects bad archive"
fi

rm -rf "$FAKE_KIT"

# --- Summary ---
printf '\nSMOKE SUMMARY: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
