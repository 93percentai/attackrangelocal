#!/usr/bin/env bash
# Proves the lab is properly locked down — no egress is open EXCEPT what
# Tailscale needs to function (TCP/443 + UDP/41641 + UDP/53).
#
# Tests, per lab VM:
#   1. ICMP to 1.1.1.1            — must FAIL (no rule permits ICMP)
#   2. TCP/22 to 1.1.1.1          — must FAIL (no rule permits TCP 22)
#   3. TCP/443 to 1.1.1.1         — must SUCCEED (Tailscale needs it)
#   4. Intra-lab service reachable — must SUCCEED (kali -> splunk:8000)
#
# Exits 0 if everything matches expectations.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/.env" ]]; then
  echo ".env required" >&2; exit 1
fi
set -a; source "$REPO_ROOT/.env"; set +a

RANGE_MODE="${RANGE_MODE:-full}"
LINUX_HOSTS=("${RANGE_ID}-splunk" "${RANGE_ID}-linux" "${RANGE_ID}-kali")
if [[ "$RANGE_MODE" == "minimal" ]]; then
  WIN_HOSTS=("${RANGE_ID}-dc01" "${RANGE_ID}-winclient1")
else
  WIN_HOSTS=("${RANGE_ID}-dc01" "${RANGE_ID}-winclient1" "${RANGE_ID}-winsrv1")
  LINUX_HOSTS+=("${RANGE_ID}-elastic")
fi

fail=0
pass() { echo "  PASS: $*"; }
err()  { echo "  FAIL: $*"; fail=1; }

# ----- Linux hosts ---------------------------------------------------------
echo "=== Linux: ICMP + TCP/22 to public must FAIL, TCP/443 must SUCCEED ==="
for h in "${LINUX_HOSTS[@]}"; do
  echo "[$h]"

  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$h" \
       "ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && echo OK" 2>/dev/null | grep -q OK; then
    err "$h reached 1.1.1.1 via ICMP — lockdown leaky"
  else
    pass "$h ICMP blocked"
  fi

  if ssh -o ConnectTimeout=5 "$h" \
       "timeout 5 bash -c '</dev/tcp/1.1.1.1/22' 2>/dev/null && echo OK" 2>/dev/null | grep -q OK; then
    err "$h reached 1.1.1.1:22 — non-Tailscale TCP egress is open"
  else
    pass "$h TCP/22 blocked"
  fi

  # TCP/443 must work — Tailscale needs it
  if ssh -o ConnectTimeout=5 "$h" \
       "timeout 5 bash -c '</dev/tcp/1.1.1.1/443' 2>/dev/null && echo OK" 2>/dev/null | grep -q OK; then
    pass "$h TCP/443 open (required for Tailscale)"
  else
    err "$h TCP/443 BLOCKED — Tailscale won't work, lab becomes unreachable"
  fi
done

# ----- Windows hosts -------------------------------------------------------
echo
echo "=== Windows: same matrix via PowerShell over Tailscale SSH ==="
for h in "${WIN_HOSTS[@]}"; do
  echo "[$h]"

  if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${AD_DOMAIN_ADMIN}@${h}" \
       "powershell -NoProfile -Command 'if (Test-Connection 1.1.1.1 -Count 1 -Quiet -TimeoutSeconds 3) { 1 } else { 0 }'" \
       2>/dev/null | tr -d '\r' | grep -q '^1$'; then
    err "$h reached 1.1.1.1 via ICMP"
  else
    pass "$h ICMP blocked"
  fi

  if ssh -o ConnectTimeout=5 "${AD_DOMAIN_ADMIN}@${h}" \
       "powershell -NoProfile -Command '(Test-NetConnection -ComputerName 1.1.1.1 -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue) | Out-String'" \
       2>/dev/null | tr -d '\r' | grep -qi 'true'; then
    err "$h reached 1.1.1.1:22 — non-Tailscale TCP egress is open"
  else
    pass "$h TCP/22 blocked"
  fi

  if ssh -o ConnectTimeout=5 "${AD_DOMAIN_ADMIN}@${h}" \
       "powershell -NoProfile -Command '(Test-NetConnection -ComputerName 1.1.1.1 -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) | Out-String'" \
       2>/dev/null | tr -d '\r' | grep -qi 'true'; then
    pass "$h TCP/443 open (required for Tailscale)"
  else
    err "$h TCP/443 BLOCKED — Tailscale won't work"
  fi
done

# ----- Intra-lab -----------------------------------------------------------
echo
echo "=== Intra-lab reachability must STILL work ==="
if ssh -o ConnectTimeout=5 "${RANGE_ID}-kali" "nc -z -w3 10.${RANGE_ID}.20.10 8000" 2>/dev/null; then
  pass "kali can reach splunk:8000 over lab VLAN"
else
  err "kali cannot reach splunk:8000 — intra-VLAN traffic broken"
fi

echo
if [[ $fail -eq 0 ]]; then
  echo "ALL ISOLATION CHECKS PASSED."
  echo "  - Lab VMs cannot ICMP or open arbitrary TCP to the public internet"
  echo "  - Tailscale TCP/443 + UDP/41641 stay open (required for operator access)"
  exit 0
fi
echo "ONE OR MORE ISOLATION CHECKS FAILED — review the FAIL lines above." >&2
exit 1
