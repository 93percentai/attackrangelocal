#!/usr/bin/env bash
# Installs every Ansible Galaxy role listed in ludus/roles.txt into the
# Ludus admin user, then kicks off a `ludus templates build`.
#
# Idempotent: re-running just refreshes roles.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ROLES_FILE="${REPO_ROOT}/ludus/roles.txt"
STATUS_FILE=/var/lib/ludus-bootstrap/status

write_status() { echo "$1" > "$STATUS_FILE" 2>/dev/null || true; }

# shellcheck source=scripts/lib/ludus-env.sh
source "${REPO_ROOT}/scripts/lib/ludus-env.sh"
source_ludus_env

if ! command -v ludus >/dev/null 2>&1; then
  echo "ludus CLI not found — run scripts/bootstrap-ludus.sh first" >&2
  exit 1
fi

if [[ ! -f "$ROLES_FILE" ]]; then
  echo "roles file missing: $ROLES_FILE" >&2
  exit 1
fi

echo "Installing Ansible roles into Ludus admin user..."
while IFS= read -r line; do
  role="${line%%#*}"
  role="${role// /}"
  [[ -z "$role" ]] && continue
  echo "  -> $role"
  ludus ansible role add "$role" || echo "WARN: $role install failed (may already be present)"
done < "$ROLES_FILE"

echo
echo "Triggering template build (this takes 60-90 minutes)..."
write_status templates-building
ludus templates build

# Block until every template reports SUCCESS or FAILED.
while true; do
  out="$(ludus templates status 2>&1 || true)"
  echo "$out"
  if echo "$out" | grep -qiE '\b(BUILDING|PENDING|BUILT_BUT_PROCESSING)\b'; then
    sleep 60
    continue
  fi
  if echo "$out" | grep -qiE '\bFAILED\b'; then
    echo "Template build FAILED — inspect 'ludus templates logs'" >&2
    exit 1
  fi
  break
done

write_status templates-ready
echo "All templates built."
