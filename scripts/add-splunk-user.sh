#!/usr/bin/env bash
# Quick interactive helper to add ONE Splunk user without re-running the
# whole playbook.
#
# Usage:
#   scripts/add-splunk-user.sh <username> <role>
#     (prompts for password, then SSHes to the splunk VM)
#
# Roles: admin | power | user | can_delete
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${REPO_ROOT}/.env"; set +a

USER_NAME="${1:-}"
ROLE="${2:-user}"
if [[ -z "$USER_NAME" ]]; then
  echo "usage: $0 <username> [admin|power|user|can_delete]" >&2
  exit 2
fi

read -s -p "New password for ${USER_NAME}: " PW; echo
read -s -p "Confirm: " PW2; echo
[[ "$PW" == "$PW2" ]] || { echo "passwords don't match" >&2; exit 1; }

ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
  "ubuntu@${RANGE_ID}-splunk" \
  "sudo /opt/splunk/bin/splunk add user '${USER_NAME}' \
     -password '${PW}' -role '${ROLE}' \
     -auth admin:'${SPLUNK_ADMIN_PASSWORD:-changeme123!}'"

echo "Added ${USER_NAME} (${ROLE}). Login at http://${RANGE_ID}-splunk:8000"
