#!/usr/bin/env bash
# Clones splunk/attack_range at the pinned v5 tag, then applies the
# local_ludus patches from this repo. The result is a self-contained,
# patched checkout under attack_range_fork/upstream/.
#
# Idempotent. Re-running re-applies the patches against a fresh checkout
# (any local edits in upstream/ are discarded).
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FORK_ROOT="${REPO_ROOT}/attack_range_fork"
UPSTREAM="${FORK_ROOT}/upstream"
PATCH_DIR="${FORK_ROOT}/patches"
NEW_FILES="${FORK_ROOT}/new-files"

# Pin to a specific v5 tag for reproducibility. Bump as upstream releases.
: "${ATTACK_RANGE_REF:=v5.0.0}"
: "${ATTACK_RANGE_REPO:=https://github.com/splunk/attack_range.git}"

if [[ -d "$UPSTREAM" ]]; then
  echo "Removing existing $UPSTREAM (will re-clone)"
  rm -rf "$UPSTREAM"
fi

echo "Cloning $ATTACK_RANGE_REPO @ $ATTACK_RANGE_REF ..."
git clone --depth 1 --branch "$ATTACK_RANGE_REF" "$ATTACK_RANGE_REPO" "$UPSTREAM"

# ----- 1. Copy new files in -----
if [[ -d "$NEW_FILES" ]]; then
  echo "Copying new files into upstream..."
  (cd "$NEW_FILES" && find . -type f) | while read -r rel; do
    src="$NEW_FILES/$rel"
    dst="$UPSTREAM/$rel"
    mkdir -p "$(dirname "$dst")"
    cp -v "$src" "$dst"
  done
fi

# ----- 2. Apply the python-based patcher -----
echo "Applying local_ludus patches via apply-patches.py..."
# apply-patches.py exits non-zero if ANY patch fails to land or if the
# result isn't valid Python. Do not continue on failure: an unpatched
# fork silently falls back to the AWS provider and tries to talk to a
# cloud API that isn't there.
if ! python3 "${FORK_ROOT}/apply-patches.py" "$UPSTREAM"; then
  echo >&2
  echo "ERROR: patching failed — refusing to leave a broken fork at $UPSTREAM" >&2
  echo "       Upstream ($ATTACK_RANGE_REF) has probably changed shape." >&2
  echo "       Fix the patterns in attack_range_fork/apply-patches.py, then re-run." >&2
  exit 1
fi

# ----- 3. (Optional) apply any unified-diff patches -----
if compgen -G "$PATCH_DIR/*.patch" > /dev/null; then
  echo "Applying *.patch files..."
  for p in "$PATCH_DIR"/*.patch; do
    echo "  -> $p"
    (cd "$UPSTREAM" && git apply --whitespace=fix "$p")
  done
fi

echo
echo "Fork ready at: $UPSTREAM"
echo "Next steps:"
echo "  cd $UPSTREAM"
echo "  docker compose -f docker/docker-compose.yml -f $REPO_ROOT/docker/attack-range.compose.yml up -d"
echo
echo "Or use scripts/start-attack-range.sh which wires this up for you."
