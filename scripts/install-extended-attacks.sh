#!/usr/bin/env bash
# Installs the extended attack tooling on the lab:
#   - APT Simulator + PurpleSharp + EICAR + CALDERA Sandcat agent on win-client1
#   - Defused malware sample staging on win-client1 (MalwareBazaar API)
#   - CALDERA server on kali
#   - Extended Atomic Runner schedule (~70 techniques)
#
# Run DURING the bootstrap window — before scripts/lock-down.sh. After
# lockdown, none of these can phone home and external pulls will fail.
#
# Idempotent: re-runs only download what's missing.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "${REPO_ROOT}/.env" ]]; then
  echo ".env required (used for RANGE_ID + optional MALWARE_BAZAAR_API_KEY + CALDERA_PASSWORD)" >&2
  exit 1
fi
set -a; source "${REPO_ROOT}/.env"; set +a

# Refresh inventory in case it isn't rendered yet. Picks minimal/full based on
# RANGE_MODE.
source "${REPO_ROOT}/scripts/lib/render-inventory.sh"
render_inventory

if [[ "${SKIP_MALWARE_SAMPLES:-0}" == "0" && -z "${MALWARE_BAZAAR_API_KEY:-}" ]]; then
  echo "NOTE: MALWARE_BAZAAR_API_KEY not set. Skipping abuse.ch pull (EICAR + APT Simulator + PurpleSharp still install)."
  echo "       Get a free key at https://bazaar.abuse.ch/account/ and add it to .env to enable."
  export SKIP_MALWARE_SAMPLES=1
fi

echo "=== 0/3  Ensure ansible collections are installed ==="
ansible-galaxy collection install -r "${REPO_ROOT}/ansible/requirements.yml" 1>&2

echo "=== 1/3  Extended attack tooling on win-client1 ==="
ansible-playbook \
  -i "${REPO_ROOT}/ansible/inventory.yml" \
  "${REPO_ROOT}/ansible/extended-attacks.yml"

echo "=== 2/3  CALDERA server on kali ==="
ansible-playbook \
  -i "${REPO_ROOT}/ansible/inventory.yml" \
  "${REPO_ROOT}/ansible/caldera-server.yml"

if [[ "${SKIP_MALWARE_SAMPLES:-0}" == "0" ]]; then
  echo "=== 3/3  Defused malware samples on win-client1 ==="
  ansible-playbook \
    -i "${REPO_ROOT}/ansible/inventory.yml" \
    "${REPO_ROOT}/ansible/malware-samples.yml"
else
  echo "=== 3/3  Defused malware samples — SKIPPED ==="
fi

echo
echo "All extended tooling installed."
echo "Next:"
echo "  scripts/lock-down.sh                # cut off egress now that pulls are done"
echo "  scripts/list-samples.sh             # show staged samples"
echo "  scripts/detonate-sample.sh <hash>   # safely fire one inside the lab"
