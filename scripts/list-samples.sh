#!/usr/bin/env bash
# Lists the defused malware samples staged on win-client1.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${REPO_ROOT}/.env"; set +a

TARGET="${RANGE_ID}-winclient1"
ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
    "${AD_DOMAIN_ADMIN}@${TARGET}" \
    'powershell -NoProfile -Command "Get-Content C:\Quarantine\manifest.json"' \
  | python3 -m json.tool 2>/dev/null || echo "no manifest yet — run scripts/install-extended-attacks.sh first"
