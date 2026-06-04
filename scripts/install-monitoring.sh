#!/usr/bin/env bash
# Brings up the second SIEM (Elastic stack) on the `elastic` VM, enrolls
# Elastic Agents on every Windows + Linux host, and applies any extra
# Splunk users from .env / ludus/splunk-users.yml.
#
# Run DURING the bootstrap egress window — before scripts/lock-down.sh —
# because Docker needs to pull Elastic images and the Elastic Agent
# installer needs HTTPS to artifacts.elastic.co.
#
# Idempotent: re-runs only do what's missing.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo ".env required" >&2
  exit 1
fi
set -a; source "${REPO_ROOT}/.env"; set +a

source "${REPO_ROOT}/scripts/lib/render-inventory.sh"
render_inventory

echo "=== 0/3  Ensure ansible collections are installed ==="
ansible-galaxy collection install -r "${REPO_ROOT}/ansible/requirements.yml" 1>&2

if [[ "${RANGE_MODE:-full}" == "minimal" ]]; then
  echo "=== 1/3  Elastic stack — SKIPPED (RANGE_MODE=minimal: Splunk only) ==="
  echo "=== 2/3  Elastic Agents — SKIPPED ==="
else
  echo "=== 1/3  Elastic stack on ${RANGE_ID}-elastic ==="
  ansible-playbook \
    -i "${REPO_ROOT}/ansible/inventory.yml" \
    "${REPO_ROOT}/ansible/elastic-stack.yml"

  echo "=== 2/3  Elastic Agents on every Windows + Linux host ==="
  ansible-playbook \
    -i "${REPO_ROOT}/ansible/inventory.yml" \
    "${REPO_ROOT}/ansible/elastic-agents.yml"
fi

echo "=== 3/3  Extra Splunk users ==="
if [[ -z "${SPLUNK_USERS:-}" && ! -f "${REPO_ROOT}/ludus/splunk-users.yml" ]]; then
  echo "skipping — SPLUNK_USERS empty and no ludus/splunk-users.yml present"
else
  ansible-playbook \
    -i "${REPO_ROOT}/ansible/inventory.yml" \
    "${REPO_ROOT}/ansible/splunk-users.yml"
fi

cat <<EOF

Monitoring stack ready.
  Splunk:  http://${RANGE_ID}-splunk:8000
EOF
if [[ "${RANGE_MODE:-full}" != "minimal" ]]; then
cat <<EOF
  Kibana:  http://${RANGE_ID}-elastic:5601    (login: elastic / \$ELASTIC_PASSWORD)
  Fleet:   http://${RANGE_ID}-elastic:8220
EOF
fi
