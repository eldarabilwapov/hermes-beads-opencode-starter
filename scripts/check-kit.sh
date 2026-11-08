#!/usr/bin/env bash
# check-kit.sh: verify the assembled starter kit matches the intended manifest,
# contains no symlinks, unexpected files, personal paths, or secret-looking strings.
# Bash 3.2+; Python 3 stdlib used for portable scanning and archive verification.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
KIT_DIR="${1:-$SCRIPT_DIR/..}"
KIT_DIR=$(cd "$KIT_DIR" && pwd)

ARCHIVE="hermes-beads-opencode-starter.tar.gz"

[[ -d "$KIT_DIR" ]] || { printf 'check-kit: fail: not a directory: %s\n' "$KIT_DIR" >&2; exit 1; }

python3 - "$KIT_DIR" "$ARCHIVE" <<'PY'
import hashlib, os, re, sys, tarfile

KIT_DIR = sys.argv[1]
ARCHIVE_NAME = sys.argv[2]

# Built-in manifest; do not trust a modified MANIFEST.txt.
MANIFEST = {
    "README.md",
    "MANIFEST.txt",
    "scripts/manager-bridge.sh",
    "scripts/check-kit.sh",
    "tests/smoke.sh",
    "tests/live-beads.sh",
    "templates/config.yml",
    "templates/AGENTS.md",
    "templates/bridge.env.example",
    "skills/hermes-beads-manager/SKILL.md",
    "docs/VERIFICATION.md",
}

ERRORS = []

def fail(msg):
    ERRORS.append(msg)

def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()

def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            c = f.read(65536)
            if not c:
                break
            h.update(c)
    return h.hexdigest()

def rel_path(full):
    return os.path.relpath(full, KIT_DIR)

# Build PEM needle from pieces so the pattern string does not match itself.
DASH5 = "-" * 5
SENSITIVE_PATTERNS = [
    (r"sk-[a-zA-Z0-9]{20,}", "openai-key-like"),
    (r"xai-[a-zA-Z0-9]{40,}", "xai-key-like"),
    (r"ghp_[a-zA-Z0-9]{36}", "github-token"),
    (r"gho_[a-zA-Z0-9]{36}", "github-oauth-token"),
    (r"ghu_[a-zA-Z0-9]{36}", "github-user-token"),
    (r"ghs_[a-zA-Z0-9]{36}", "github-server-token"),
    (r"ghr_[a-zA-Z0-9]{36}", "github-refresh-token"),
    (r"r8_[a-zA-Z0-9]{32,}", "replicate-token"),
    (r"[A-Za-z0-9_-]{32,}\.[A-Za-z0-9_-]{32,}\.[A-Za-z0-9_-]{32,}", "jwt-like"),
    (DASH5 + r"BEGIN .* PRIVATE KEY" + DASH5, "pem-private-key"),
    (DASH5 + r"BEGIN OPENSSH PRIVATE KEY" + DASH5, "openssh-private-key"),
    (r"/Users/[A-Za-z0-9_-]+/", "mac-personal-path"),
    (r"/home/[A-Za-z0-9_-]+/", "linux-personal-path"),
]

# Structural pass: walk the kit, reject symlinks, unexpected dirs/files.
actual_files = set()
for root, dirs, files in os.walk(KIT_DIR):
    for d in dirs:
        full = os.path.join(root, d)
        r = rel_path(full)
        if os.path.islink(full):
            fail(f"symlink not allowed: {r}")
    for name in files:
        full = os.path.join(root, name)
        r = rel_path(full)
        if os.path.islink(full):
            fail(f"symlink not allowed: {r}")
            continue
        if not os.path.isfile(full):
            fail(f"unexpected non-file entry: {r}")
            continue
        actual_files.add(r)

# Rejected symlinks or non-file entries make the tree unsafe to read.
if ERRORS:
    for e in ERRORS:
        print(f"check-kit: fail: {e}", file=sys.stderr)
    sys.exit(1)

# Allow the known derived archive as an optional extra regular file.
archive_path = os.path.join(KIT_DIR, ARCHIVE_NAME)
archive_present = os.path.isfile(archive_path) and not os.path.islink(archive_path)
check_set = actual_files.copy()
if archive_present:
    check_set.discard(ARCHIVE_NAME)

# Manifest.txt contents must equal the built-in manifest exactly (no duplicates).
manifest_txt_path = os.path.join(KIT_DIR, "MANIFEST.txt")
if os.path.isfile(manifest_txt_path):
    try:
        with open(manifest_txt_path, "r", encoding="utf-8") as f:
            txt_lines = [ln.strip() for ln in f.read().splitlines() if ln.strip()]
        if sorted(txt_lines) != sorted(MANIFEST):
            fail("MANIFEST.txt contents do not match built-in manifest")
    except Exception:
        fail("cannot read MANIFEST.txt")
else:
    fail("MANIFEST.txt missing")

# Exact file set check (archive excluded).
if check_set != MANIFEST:
    for m in sorted(MANIFEST - check_set):
        fail(f"missing manifest entry: {m}")
    for e in sorted(check_set - MANIFEST):
        fail(f"unexpected file: {e}")

# Reject unexpected directories (only parents of manifest entries allowed).
allowed_dirs = set()
for r in MANIFEST:
    parts = r.split("/")
    for i in range(1, len(parts)):
        allowed_dirs.add("/".join(parts[:i]))
for root, dirs, _ in os.walk(KIT_DIR):
    for d in dirs:
        r = rel_path(os.path.join(root, d))
        if r not in allowed_dirs:
            fail(f"unexpected directory: {r}")

# If the on-disk structure is not trustworthy, stop before reading any file
# contents; a rejected symlink parent must not be traversed via manifest paths.
if ERRORS:
    for e in ERRORS:
        print(f"check-kit: fail: {e}", file=sys.stderr)
    sys.exit(1)

# Content scan only on structural-safe manifest files.
affected = {}
for r in sorted(MANIFEST):
    full = os.path.join(KIT_DIR, r)
    if not os.path.isfile(full) or os.path.islink(full):
        continue
    try:
        with open(full, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except Exception:
        fail(f"cannot read: {r}")
        continue
    for pat, label in SENSITIVE_PATTERNS:
        if re.search(pat, text, re.IGNORECASE):
            affected.setdefault(r, []).append(label)

for r, labels in sorted(affected.items()):
    fail(f"sensitive pattern ({', '.join(labels)}): {r}")

# Optional derived archive verification.
if archive_present:
    try:
        with tarfile.open(archive_path, "r:gz") as tf:
            members = tf.getmembers()
            seen = set()
            archive_files = set()
            for m in members:
                name = m.name
                if name == ARCHIVE_NAME:
                    fail(f"archive contains itself: {name}")
                    continue
                if name.startswith(("/", "\\")) or ".." in name.split("/"):
                    fail(f"archive unsafe member path: {name}")
                    continue
                if name.startswith("._") or "/._" in name:
                    fail(f"archive AppleDouble member: {name}")
                    continue
                if m.pax_headers:
                    fail(f"archive PAX member: {name}")
                    continue
                if not m.isfile():
                    fail(f"archive non-file member: {name}")
                    continue
                if m.uid != 0 or m.gid != 0:
                    fail(f"archive member owner not neutral: {name}")
                    continue
                if m.uname not in ("", "root") or m.gname not in ("", "root"):
                    fail(f"archive member uname/gname not neutral: {name}")
                    continue
                if name in seen:
                    fail(f"archive duplicate member: {name}")
                    continue
                seen.add(name)
                archive_files.add(name)
                if name not in MANIFEST:
                    fail(f"archive extra member: {name}")
                    continue
                disk_full = os.path.join(KIT_DIR, name)
                member_data = tf.extractfile(m).read()
                if sha256_bytes(member_data) != sha256_file(disk_full):
                    fail(f"archive member differs from disk: {name}")
            missing_in_archive = MANIFEST - archive_files
            for m in sorted(missing_in_archive):
                fail(f"archive missing manifest entry: {m}")
    except Exception as e:
        fail(f"archive verification error ({type(e).__name__}): {archive_path}")

if ERRORS:
    for e in ERRORS:
        print(f"check-kit: fail: {e}", file=sys.stderr)
    sys.exit(1)

print(
    f"check-kit: pass: manifest_files={len(MANIFEST)}, "
    f"sensitive_files={len(affected)}, "
    f"archive_members={len(archive_files) if archive_present else 0}"
)
PY
