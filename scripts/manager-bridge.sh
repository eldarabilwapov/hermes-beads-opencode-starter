#!/usr/bin/env bash
# manager-bridge.sh: portable Hermes/Beads/OMP bridge for local starter kit.
# Bash 3.2+; safe quoting; paths with spaces supported.
# Required env: HERMES_PROJECT, HERMES_OMP_CONFIG, HERMES_STATE_DIR.
# Optional env: BD_BIN, OMP_BIN.
set -euo pipefail
umask 077

HERMES_PROJECT="${HERMES_PROJECT:-}"
HERMES_OMP_CONFIG="${HERMES_OMP_CONFIG:-}"
HERMES_STATE_DIR="${HERMES_STATE_DIR:-}"
BD_BIN="${BD_BIN:-bd}"
OMP_BIN="${OMP_BIN:-omp}"

LOCK_DIR=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

# Pure Bash 3.2 canonical path resolution. No external interpreters are used,
# so a broken python3 in PATH cannot silently produce an empty path.
realpath_canonical() {
  local target="$1"
  [[ -n "$target" ]] || die "realpath_canonical: empty path"

  # Relative paths are resolved from the current working directory at call time.
  case "$target" in
    /*) ;;
    *) target="$PWD/$target" ;;
  esac

  # Remove a trailing slash, but preserve the root path.
  target="${target%/}"
  [[ -n "$target" ]] || target="/"

  # For an existing path, cd -P resolves symlinks and pwd -P returns the
  # physical location (for example /var -> /private/var on macOS).
  if [[ -e "$target" ]]; then
    if [[ -d "$target" ]]; then
      (cd -P -- "$target" && pwd -P)
      return 0
    fi
    local dir name canon_dir
    dir=$(dirname "$target")
    name=$(basename "$target")
    canon_dir=$(cd -P -- "$dir" && pwd -P) || die "realpath_canonical: cannot canonicalize $dir"
    printf '%s/%s\n' "$canon_dir" "$name"
    return 0
  fi

  # Non-existent path: walk up to the nearest existing ancestor, canonicalize
  # that ancestor, and append the remaining tail.
  local current="$target" remainder=""
  while [[ -n "$current" && ! -e "$current" ]]; do
    local parent base
    parent=$(dirname "$current")
    base=$(basename "$current")
    [[ "$parent" != "$current" ]] || break
    if [[ -n "$remainder" ]]; then
      remainder="$base/$remainder"
    else
      remainder="$base"
    fi
    current="$parent"
  done

  [[ -e "$current" ]] || die "realpath_canonical: no existing ancestor for $1"

  # Conservatively reject . or .. inside the not-yet-created tail.
  local comp
  local old_ifs="$IFS"
  IFS='/'
  set -- $remainder
  IFS="$old_ifs"
  for comp; do
    [[ "$comp" != "." && "$comp" != ".." ]] || \
      die "realpath_canonical: non-existent path contains . or ..: $1"
  done

  local canon
  canon=$(cd -P -- "$current" && pwd -P) || die "realpath_canonical: cannot canonicalize $current"
  if [[ -n "$remainder" ]]; then
    printf '%s/%s\n' "$canon" "$remainder"
  else
    printf '%s\n' "$canon"
  fi
}

KIT_DIR=$(cd "$(dirname "$0")/.." && pwd)
KIT_CANONICAL=$(realpath_canonical "$KIT_DIR")
[[ -n "$KIT_CANONICAL" ]] || die "cannot canonicalize kit directory: $KIT_DIR"

cleanup() {
  release_lock
}

trap cleanup EXIT

require_value() {
  local flag="$1"
  local value="${2:-}"
  [[ -n "$value" ]] || die "$flag requires a value"
}

validate_env() {
  [[ -n "$HERMES_PROJECT" ]] || die "HERMES_PROJECT is required"
  [[ -n "$HERMES_STATE_DIR" ]] || die "HERMES_STATE_DIR is required"

  if [[ ! -d "$HERMES_PROJECT" ]]; then
    die "HERMES_PROJECT is not a directory: $HERMES_PROJECT"
  fi

  PROJECT_CANONICAL=$(realpath_canonical "$HERMES_PROJECT")
  [[ -n "$PROJECT_CANONICAL" ]] || die "cannot canonicalize HERMES_PROJECT: $HERMES_PROJECT"
  STATE_CANONICAL=$(realpath_canonical "$HERMES_STATE_DIR")
  [[ -n "$STATE_CANONICAL" ]] || die "cannot canonicalize HERMES_STATE_DIR: $HERMES_STATE_DIR"

  # State must live outside the project tree and outside the kit tree.
  case "$STATE_CANONICAL" in
    "$PROJECT_CANONICAL"|"$PROJECT_CANONICAL"/*)
      die "HERMES_STATE_DIR must be outside HERMES_PROJECT"
      ;;
    "$KIT_CANONICAL"|"$KIT_CANONICAL"/*)
      die "HERMES_STATE_DIR must be outside the kit directory"
      ;;
  esac

  RUNS_DIR="$STATE_CANONICAL/runs"
  APPROVALS_DIR="$STATE_CANONICAL/approvals"
  OWNER_FILE="$STATE_CANONICAL/.owner"

  # Fail-fast owner check without mutation. Creation happens under the state lock.
  if [[ -f "$OWNER_FILE" ]]; then
    local owner_project=""
    while IFS='=' read -r key value; do
      [[ "$key" == "project_canonical" ]] && owner_project="$value"
    done < "$OWNER_FILE"
    [[ "$owner_project" == "$PROJECT_CANONICAL" ]] || \
      die "state dir belongs to a different project: $owner_project"
  fi
}

validate_config() {
  [[ -n "$HERMES_OMP_CONFIG" ]] || die "HERMES_OMP_CONFIG is required"
  if [[ ! -f "$HERMES_OMP_CONFIG" ]]; then
    die "HERMES_OMP_CONFIG is not a file: $HERMES_OMP_CONFIG"
  fi
}

ensure_state_dirs() {
  # Must be called while holding the state lock.
  if [[ -f "$OWNER_FILE" ]]; then
    local owner_project=""
    while IFS='=' read -r key value; do
      [[ "$key" == "project_canonical" ]] && owner_project="$value"
    done < "$OWNER_FILE"
    [[ "$owner_project" == "$PROJECT_CANONICAL" ]] || \
      die "state dir belongs to a different project: $owner_project"
  else
    mkdir -p "$STATE_CANONICAL"
    printf 'project_canonical=%s\n' "$PROJECT_CANONICAL" > "$OWNER_FILE"
    chmod 600 "$OWNER_FILE"
  fi
  mkdir -p "$RUNS_DIR" "$APPROVALS_DIR"
}

acquire_lock() {
  local lock="$STATE_CANONICAL/.lock"
  # Create the state directory with restrictive permissions if it does not yet
  # exist. The owner precheck in validate_env already prevents us from touching
  # a state directory owned by another project.
  if ! mkdir -p -m 700 "$STATE_CANONICAL" 2>/dev/null; then
    die "cannot create state directory: $STATE_CANONICAL"
  fi
  if ! mkdir -m 700 "$lock" 2>/dev/null; then
    die "state lock is held: $lock (another bridge instance is running)"
  fi
  LOCK_DIR="$lock"
}

release_lock() {
  [[ -n "${LOCK_DIR:-}" && -d "$LOCK_DIR" ]] || return 0
  rmdir "$LOCK_DIR" 2>/dev/null || true
  LOCK_DIR=""
}

sha256_file() {
  local out
  out=$(python3 -c 'import hashlib,sys; h=hashlib.sha256(); f=open(sys.argv[1],"rb");
while True:
 c=f.read(65536); h.update(c);
 if not c: break
print(h.hexdigest())' "$1") || die "sha256_file failed: $1"
  [[ -n "$out" ]] || die "sha256_file produced empty hash: $1"
  printf '%s\n' "$out"
}

validate_issue_id() {
  local id="${1:-}"
  [[ -n "$id" ]] || die "issue id is required"
  if [[ "$id" == "." || "$id" == ".." ]]; then
    die "invalid issue id: $id"
  fi
  if [[ ! "$id" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    die "invalid issue id: $id"
  fi
}

issue_exists() {
  local id="$1"
  "$BD_BIN" -C "$PROJECT_CANONICAL" show --json "$id" >/dev/null 2>&1
}

fetch_contract_snapshot() {
  local id="$1"
  local out
  out=$("$BD_BIN" -C "$PROJECT_CANONICAL" show --json "$id" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        data = data[0]
except Exception:
    sys.exit(1)
keys = ["id", "title", "description", "acceptance_criteria", "notes",
        "design", "priority", "issue_type", "status", "labels"]
out = {}
for k in keys:
    if k in data:
        out[k] = data[k]
json.dump(out, sys.stdout, sort_keys=True, ensure_ascii=False)
') || die "cannot fetch contract snapshot for $id"
  [[ -n "$out" ]] || die "contract snapshot empty for $id"
  printf '%s\n' "$out"
}

contract_digest() {
  local id="$1"
  local snap out
  snap=$(fetch_contract_snapshot "$id") || die "cannot fetch contract for $id"
  out=$(printf '%s' "$snap" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.read().encode("utf-8")).hexdigest())') || die "cannot digest contract for $id"
  [[ -n "$out" ]] || die "contract digest empty for $id"
  printf '%s\n' "$out"
}

verify_omp_flags() {
  local help_text
  help_text=$("$OMP_BIN" --help 2>&1) || die "cannot run $OMP_BIN --help"
  if ! grep -q -- '--approval-mode' <<< "$help_text"; then
    die "omp does not support --approval-mode"
  fi
  # Match always-ask as a distinct enum value, not as a prefix of always-ask-cached.
  if ! grep -qE -- '--approval-mode.*always-ask[^[:alnum:]_-]' <<< "$help_text"; then
    die "omp --approval-mode does not list always-ask"
  fi
  if ! grep -q -- '--tools' <<< "$help_text"; then
    die "omp does not support --tools"
  fi
  if ! grep -q -- '--no-extensions' <<< "$help_text"; then
    die "omp does not support --no-extensions"
  fi
  if ! grep -q -- '--no-session' <<< "$help_text"; then
    die "omp does not support --no-session"
  fi
}

add_comment() {
  local id="$1"
  shift
  "$BD_BIN" -C "$PROJECT_CANONICAL" comments add "$id" "$@" >/dev/null 2>&1 || return $?
}

print_help() {
  cat <<'EOF'
Usage: manager-bridge.sh <command> [options]

Commands:
  capture --title <title> --request <text> --acceptance <text>
    Create a Beads issue capturing the owner's original wording.

  plan <issue-id>
    Produce a read-only plan via OMP and save the artifact.
    Invalidates any previous approval for this issue.

  approve <issue-id> --by <label>
    Record explicit owner approval with digests of plan, contract, and config.

  execute <issue-id>
    Run OMP execute after verifying the approval receipt is fresh.

  status <issue-id>
    Show Beads issue, run artifacts, and approval state.

  help
    Show this message.

Required environment:
  HERMES_PROJECT    path to the project directory (relative paths resolved from cwd)
  HERMES_OMP_CONFIG path to the OMP config overlay
  HERMES_STATE_DIR  directory for runs, approvals, and lock (outside project)

Optional environment:
  BD_BIN            path to bd executable (default: bd)
  OMP_BIN           path to omp executable (default: omp)
EOF
}

capture_issue() {
  local title="" request="" acceptance=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --title) require_value "$1" "${2:-}"; title="$2"; shift 2 ;;
      --request) require_value "$1" "${2:-}"; request="$2"; shift 2 ;;
      --acceptance) require_value "$1" "${2:-}"; acceptance="$2"; shift 2 ;;
      *) die "unknown capture argument: $1" ;;
    esac
  done
  [[ -n "$title" && -n "$request" && -n "$acceptance" ]] || \
    die "capture needs --title, --request, and --acceptance"

  local description
  printf -v description 'Original owner request:\n\n%s' "$request"

  local id
  id=$("$BD_BIN" -C "$PROJECT_CANONICAL" create --silent \
    --title="$title" \
    --type=task \
    --priority=2 \
    --description="$description" \
    --acceptance="$acceptance" \
    --labels="hermes-intake,opencode-go") \
    || die "beads create failed"
  printf '%s\n' "$id"
}

invalidate_plan_and_approval() {
  local id="$1"
  rm -f "$APPROVALS_DIR/$id" "$APPROVALS_DIR/$id.plan"
}

# Plan metadata records the artifact of a planning run whose OMP process, tee,
# and audit comment returned rc 0. It does NOT assert the provider produced a
# correct or complete plan; the owner must read the artifact before approving.
write_plan_metadata() {
  local id="$1" plan_path="$2" plan_sha="$3" contract_sha="$4" config_sha="$5"
  local meta="$APPROVALS_DIR/$id.plan"
  {
    printf 'plan_path=%s\n' "$plan_path"
    printf 'plan_sha256=%s\n' "$plan_sha"
    printf 'contract_sha256=%s\n' "$contract_sha"
    printf 'config_sha256=%s\n' "$config_sha"
    printf 'planned_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$meta" || return $?
  chmod 600 "$meta" || return $?
}

plan_issue() {
  local id="${1:-}"
  validate_issue_id "$id"
  issue_exists "$id" || die "unknown Beads issue: $id"

  # A new planning attempt invalidates any prior approval and current plan,
  # even if the subsequent OMP preflight fails.
  invalidate_plan_and_approval "$id"
  validate_config
  verify_omp_flags

  local stamp out issue_text prompt rc comment_rc
  local contract_at_plan config_at_plan plan_sha
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  out=$(mktemp "$RUNS_DIR/${id}-${stamp}-plan-XXXXXX") || die "mktemp failed"

  contract_at_plan=$(contract_digest "$id") || die "cannot snapshot contract"
  config_at_plan=$(sha256_file "$HERMES_OMP_CONFIG")

  issue_text=$("$BD_BIN" -C "$PROJECT_CANONICAL" show "$id" 2>/dev/null) || \
    die "cannot read issue $id"

  prompt=$(cat <<EOF
You are the planning stage for Beads issue $id in $PROJECT_CANONICAL.

Read AGENTS.md and inspect only the files needed to understand the request.
Do not edit files, update Beads, run builds, start services, access secrets,
or perform network mutations.

<beads_issue>
$issue_text
</beads_issue>

Return a concise Russian plan containing:
1. intended outcome;
2. scope and explicit non-goals;
3. files or systems likely involved;
4. acceptance evidence;
5. risks and owner decisions, if any.

Do not propose push, merge, deletion, destructive database actions,
production credential changes, or external publication.
EOF
)

  local -a statuses
  set +e
  "$OMP_BIN" \
    --cwd "$PROJECT_CANONICAL" \
    --config "$HERMES_OMP_CONFIG" \
    --model openai-codex/gpt-6.1-sol \
    --thinking high \
    --no-session \
    --no-extensions \
    --tools read,grep,glob \
    --approval-mode always-ask \
    --max-time 20m \
    -p "$prompt" 2>&1 | tee "$out"
  statuses=("${PIPESTATUS[@]}")
  set -e

  local rc_omp=${statuses[0]}
  local rc_tee=${statuses[1]}

  if [[ $rc_omp -ne 0 ]]; then
    rc=$rc_omp
  elif [[ $rc_tee -ne 0 ]]; then
    rc=$rc_tee
  else
    rc=0
  fi

  comment_rc=0
  add_comment "$id" "Plan artifact: $out (exit $rc)" || comment_rc=$?
  if [[ $rc -eq 0 && $comment_rc -ne 0 ]]; then
    rc=$comment_rc
  fi

  if [[ $rc -eq 0 ]]; then
    plan_sha=$(sha256_file "$out")
    if ! write_plan_metadata "$id" "$out" "$plan_sha" "$contract_at_plan" "$config_at_plan"; then
      rm -f "$out" "$APPROVALS_DIR/$id.plan"
      return 1
    fi
  fi

  return "$rc"
}

approve_issue() {
  local id="${1:-}" by=""
  validate_issue_id "$id"
  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --by) require_value "$1" "${2:-}"; by="$2"; shift 2 ;;
      *) die "unknown approve argument: $1" ;;
    esac
  done
  [[ -n "$by" ]] || die "approve needs --by"
  issue_exists "$id" || die "unknown Beads issue: $id"

  local meta="$APPROVALS_DIR/$id.plan"
  [[ -f "$meta" ]] || die "no successful plan for $id; run plan first"

  local m_path="" m_plan_sha="" m_contract_sha="" m_config_sha=""
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    case "$key" in
      plan_path) m_path="$value" ;;
      plan_sha256) m_plan_sha="$value" ;;
      contract_sha256) m_contract_sha="$value" ;;
      config_sha256) m_config_sha="$value" ;;
    esac
  done < "$meta"

  [[ -n "$m_path" && -n "$m_plan_sha" && -n "$m_contract_sha" && -n "$m_config_sha" ]] || \
    die "corrupt plan metadata for $id"

  [[ -f "$m_path" ]] || die "plan artifact missing: $m_path"
  local current_plan_sha current_contract_sha current_config_sha
  current_plan_sha=$(sha256_file "$m_path")
  [[ "$current_plan_sha" == "$m_plan_sha" ]] || die "plan artifact changed since plan"

  current_contract_sha=$(contract_digest "$id")
  [[ "$current_contract_sha" == "$m_contract_sha" ]] || \
    die "Beads contract changed since plan; rerun plan"

  current_config_sha=$(sha256_file "$HERMES_OMP_CONFIG")
  [[ "$current_config_sha" == "$m_config_sha" ]] || \
    die "OMP config changed since plan; rerun plan"

  local receipt_tmp receipt
  receipt="$APPROVALS_DIR/$id"
  receipt_tmp=$(mktemp "$APPROVALS_DIR/${id}-XXXXXX")
  {
    printf 'issue=%s\n' "$id"
    printf 'project_canonical=%s\n' "$PROJECT_CANONICAL"
    printf 'approved_by=%s\n' "$by"
    printf 'approved_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'plan_sha256=%s\n' "$m_plan_sha"
    printf 'contract_sha256=%s\n' "$m_contract_sha"
    printf 'config_sha256=%s\n' "$m_config_sha"
    printf 'plan_path=%s\n' "$m_path"
  } > "$receipt_tmp"
  chmod 600 "$receipt_tmp"

  if ! add_comment "$id" "Execution approved by $by. Receipt: $receipt"; then
    rm -f "$receipt_tmp"
    die "failed to record approval comment"
  fi

  mv -f "$receipt_tmp" "$receipt"
  printf '%s\n' "$receipt"
}

execute_issue() {
  local id="${1:-}"
  validate_issue_id "$id"
  issue_exists "$id" || die "unknown Beads issue: $id"
  verify_omp_flags

  local receipt="$APPROVALS_DIR/$id"
  [[ -f "$receipt" ]] || die "issue $id has no explicit execution approval receipt"

  local r_issue="" r_project="" r_by="" r_at="" r_plan_sha="" \
        r_contract_sha="" r_config_sha="" r_plan_path=""
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    case "$key" in
      issue) r_issue="$value" ;;
      project_canonical) r_project="$value" ;;
      approved_by) r_by="$value" ;;
      approved_at) r_at="$value" ;;
      plan_sha256) r_plan_sha="$value" ;;
      contract_sha256) r_contract_sha="$value" ;;
      config_sha256) r_config_sha="$value" ;;
      plan_path) r_plan_path="$value" ;;
    esac
  done < "$receipt"

  [[ -n "$r_issue" && -n "$r_project" && -n "$r_plan_sha" && \
     -n "$r_contract_sha" && -n "$r_config_sha" && -n "$r_plan_path" ]] || \
    die "malformed approval receipt for $id"

  local meta="$APPROVALS_DIR/$id.plan"
  [[ -f "$meta" ]] || die "stale approval: current plan pointer missing"

  local m_path="" m_plan_sha="" m_contract_sha="" m_config_sha=""
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    case "$key" in
      plan_path) m_path="$value" ;;
      plan_sha256) m_plan_sha="$value" ;;
      contract_sha256) m_contract_sha="$value" ;;
      config_sha256) m_config_sha="$value" ;;
    esac
  done < "$meta"

  [[ "$m_path" == "$r_plan_path" && "$m_plan_sha" == "$r_plan_sha" && \
     "$m_contract_sha" == "$r_contract_sha" && "$m_config_sha" == "$r_config_sha" ]] || \
    die "stale approval: receipt does not match current plan pointer"

  [[ "$r_issue" == "$id" ]] || die "receipt issue mismatch"
  [[ "$r_project" == "$PROJECT_CANONICAL" ]] || \
    die "stale approval: project changed"

  local current_config_sha current_contract_sha current_plan_sha
  current_config_sha=$(sha256_file "$HERMES_OMP_CONFIG")
  [[ "$current_config_sha" == "$r_config_sha" ]] || \
    die "stale approval: OMP config changed"

  current_contract_sha=$(contract_digest "$id")
  [[ "$current_contract_sha" == "$r_contract_sha" ]] || \
    die "stale approval: Beads contract changed"

  [[ -f "$r_plan_path" ]] || die "stale approval: plan artifact missing"
  current_plan_sha=$(sha256_file "$r_plan_path")
  [[ "$current_plan_sha" == "$r_plan_sha" ]] || \
    die "stale approval: plan artifact changed"

  verify_omp_flags

  local stamp out issue_text prompt rc comment_rc
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  out=$(mktemp "$RUNS_DIR/${id}-${stamp}-execute-XXXXXX") || die "mktemp failed"

  issue_text=$("$BD_BIN" -C "$PROJECT_CANONICAL" show "$id" 2>/dev/null) || \
    die "cannot read issue $id"

  prompt=$(cat <<EOF
Execute Beads issue $id in $PROJECT_CANONICAL.

Mandatory workflow:
- Read AGENTS.md and use the included Beads issue as the durable task contract.
- Preserve unrelated working-tree changes.
- Implement only the requested scope.
- You are the Codex orchestrator and reviewer. For code or file changes, delegate
  implementation to the OMP task agent routed to the configured OpenCode Go executor.
  Read-only tasks may be completed directly.
- After the executor returns, inspect its diff and evidence. Send corrections back
  when needed; keep final acceptance and security review in the root Codex session.
- Run verification proportional to the change and report exact evidence.
- Update the Beads issue with relevant findings via comments. Never close it.

<beads_issue>
$issue_text
</beads_issue>

Hard boundaries:
- no commit, push, merge, branch deletion, or force operation;
- no deletion of project files or directories;
- no destructive database operation;
- no production credential change;
- no external message or publication;
- no deployment unless the issue explicitly requests it and project rules permit it.

Return a Russian handoff with changed files, checks and results, remaining risks,
and the next human decision.
EOF
)

  local -a statuses
  set +e
  "$OMP_BIN" \
    --cwd "$PROJECT_CANONICAL" \
    --config "$HERMES_OMP_CONFIG" \
    --model openai-codex/gpt-6.1-sol \
    --thinking high \
    --no-session \
    --approval-mode always-ask \
    --wait-async \
    --max-time 2h \
    -p "$prompt" 2>&1 | tee "$out"
  statuses=("${PIPESTATUS[@]}")
  set -e

  local rc_omp=${statuses[0]}
  local rc_tee=${statuses[1]}

  if [[ $rc_omp -ne 0 ]]; then
    rc=$rc_omp
  elif [[ $rc_tee -ne 0 ]]; then
    rc=$rc_tee
  else
    rc=0
  fi

  comment_rc=0
  add_comment "$id" "Execution artifact: $out (exit $rc)" || comment_rc=$?
  if [[ $rc -eq 0 && $comment_rc -ne 0 ]]; then
    rc=$comment_rc
  fi
  return "$rc"
}

status_issue() {
  local id="${1:-}"
  validate_issue_id "$id"
  issue_exists "$id" || die "unknown Beads issue: $id"

  "$BD_BIN" -C "$PROJECT_CANONICAL" show "$id"
  printf '\nArtifacts:\n'
  find "$RUNS_DIR" -maxdepth 1 -type f \( -name "${id}-*-plan-*" -o -name "${id}-*-execute-*" \) -print 2>/dev/null | sort

  local receipt="$APPROVALS_DIR/$id"
  if [[ -f "$receipt" ]]; then
    printf '\nApproval: %s\n' "$receipt"
    # Show only non-secret summary fields.
    grep -E '^(issue|approved_by|approved_at|plan_path)=' "$receipt" || true
  else
    printf '\nApproval: none\n'
  fi
}

main() {
  local cmd="${1:-help}"
  case "$cmd" in
    capture) shift; validate_env; validate_config; acquire_lock; ensure_state_dirs; capture_issue "$@" ;;
    plan) shift; validate_env; acquire_lock; ensure_state_dirs; plan_issue "$@" ;;
    approve) shift; validate_env; validate_config; acquire_lock; ensure_state_dirs; approve_issue "$@" ;;
    execute) shift; validate_env; validate_config; acquire_lock; ensure_state_dirs; execute_issue "$@" ;;
    status) shift; validate_env; validate_config; acquire_lock; ensure_state_dirs; status_issue "$@" ;;
    help|--help|-h) print_help; exit 0 ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
