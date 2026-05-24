#!/usr/bin/env bash
# Proves the lab is fully isolated from the public internet.
# Run from your laptop (anywhere on the tailnet) AFTER lock-down.sh.
#
# Exits 0 if every check passes. Non-zero if any VM can reach the internet.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo ".env required" >&2
  exit 1
fi
set -a; source "$REPO_ROOT/.env"; set +a

# Resolve every lab VM by Tailscale MagicDNS name. Adjust hostnames if you
# changed range-config.yml.
LINUX_HOSTS=("${RANGE_ID}-splunk" "${RANGE_ID}-linux" "${RANGE_ID}-kali")
WIN_HOSTS=("${RANGE_ID}-dc01" "${RANGE_ID}-winclient1" "${RANGE_ID}-winsrv1")

fail=0
pass() { echo "  PASS: $*"; }
err()  { echo "  FAIL: $*"; fail=1; }

echo "=== Linux hosts must NOT reach the public internet ==="
for h in "${LINUX_HOSTS[@]}"; do
  echo "[$h]"
  # TCP to a known public IP (no DNS dependency).
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$h" \
       "curl -m 5 -s -o /dev/null -w '%{http_code}' https://1.1.1.1" 2>/dev/null \
     | grep -qE '^[23]'; then
    err "$h reached 1.1.1.1 — egress not locked down"
  else
    pass "$h cannot reach 1.1.1.1"
  fi
done

echo "=== Windows hosts must NOT reach the public internet ==="
for h in "${WIN_HOSTS[@]}"; do
  echo "[$h]"
  # Tailscale SSH on Windows = OpenSSH server. Use PowerShell over SSH.
  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${AD_DOMAIN_ADMIN}@${h}" \
       "powershell -NoProfile -Command 'try { (Invoke-WebRequest -Uri https://1.1.1.1 -TimeoutSec 5 -UseBasicParsing).StatusCode } catch { 0 }'" \
       2>/dev/null | grep -qE '^[23]'; then
    err "$h reached 1.1.1.1"
  else
    pass "$h cannot reach 1.1.1.1"
  fi
done

echo "=== Intra-lab reachability must STILL work ==="
if ssh -o ConnectTimeout=5 "${RANGE_ID}-kali" "nc -z -w3 10.${RANGE_ID}.20.10 8000" 2>/dev/null; then
  pass "kali can reach splunk:8000 over lab VLAN"
else
  err "kali cannot reach splunk:8000 — intra-VLAN traffic broken"
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "ALL ISOLATION CHECKS PASSED."
  exit 0
fi
echo "ONE OR MORE ISOLATION CHECKS FAILED — lab is NOT safe to run." >&2
exit 1
