#!/usr/bin/env bash
# Safely detonates ONE defused malware sample inside win-client1.
#
# Safety rails:
#   1. Confirms with the operator (echoes hash + name)
#   2. Refuses to run unless scripts/verify-isolation.sh exits 0
#      (so the lab cannot leak the detonation if the sample tries to
#       phone home or pivot)
#   3. Extracts the password-protected ZIP in place, runs the inner
#      binary with a 60-second watchdog, then snapshots event logs
#      so detections land in Splunk immediately
#   4. Does NOT copy anything off the VM — the sample stays in
#      C:\Quarantine\ at all times
#
# Usage:
#   scripts/detonate-sample.sh <sha256-hash>
#   scripts/detonate-sample.sh --eicar     # special case: drops EICAR
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${REPO_ROOT}/.env"; set +a

TARGET="${RANGE_ID}-winclient1"
HASH="${1:-}"
if [[ -z "$HASH" ]]; then
  echo "usage: $0 <sha256> | --eicar" >&2
  exit 2
fi

# ---- Safety rail 1: isolation must be locked down --------------------
echo "[1/4] Verifying isolation (lab MUST be air-gapped before detonating)..."
if ! "${REPO_ROOT}/scripts/verify-isolation.sh" >/dev/null 2>&1; then
  echo "ISOLATION CHECK FAILED — refusing to detonate." >&2
  echo "  Run scripts/lock-down.sh and then scripts/verify-isolation.sh first." >&2
  exit 1
fi

# ---- Safety rail 2: explicit operator confirmation -------------------
if [[ "$HASH" == "--eicar" ]]; then
  echo "About to drop EICAR test file on ${TARGET}."
else
  echo "About to detonate sample ${HASH} on ${TARGET}."
fi
read -rp "Type 'DETONATE' to proceed: " confirm
if [[ "$confirm" != "DETONATE" ]]; then
  echo "Aborted."; exit 1
fi

# ---- The detonation --------------------------------------------------
if [[ "$HASH" == "--eicar" ]]; then
  PS='powershell -NoProfile -Command "'\
'$e = '"'"'X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'"'"';'\
'[System.IO.File]::WriteAllText(\"C:\\Users\\Public\\Documents\\eicar.com\", $e);'\
'Write-Output \"EICAR dropped\""'
else
  PS=$(cat <<PS
powershell -NoProfile -Command "
  \$pw  = '${MALWARE_ARCHIVE_PASSWORD:-infected}';
  \$zip = 'C:\\Quarantine\\${HASH}.zip';
  \$dst = 'C:\\Quarantine\\${HASH}.run';
  if (-not (Test-Path \$zip)) { throw 'sample missing' }
  Remove-Item -Recurse -Force \$dst -ErrorAction SilentlyContinue;
  New-Item -ItemType Directory -Force \$dst | Out-Null;
  # Use 7-Zip (shipped on the win base image by Ludus) to handle pw zips.
  & 'C:\\Program Files\\7-Zip\\7z.exe' x \$zip ('-p' + \$pw) ('-o' + \$dst) -y;
  \$exe = Get-ChildItem -Path \$dst -Recurse -File |
           Where-Object { \$_.Extension -in '.exe', '.dll', '.bat', '.ps1', '.js' } |
           Select-Object -First 1;
  if (-not \$exe) { throw 'no executable found in sample' }
  Write-Output ('Detonating ' + \$exe.FullName);
  # 60-second watchdog
  \$p = Start-Process -FilePath \$exe.FullName -PassThru -ErrorAction SilentlyContinue;
  Start-Sleep -Seconds 60;
  if (\$p -and -not \$p.HasExited) { Stop-Process -Id \$p.Id -Force; Write-Output 'killed after 60s' }
  Write-Output 'detonation complete';
"
PS
  )
fi

ssh -o StrictHostKeyChecking=accept-new "${AD_DOMAIN_ADMIN}@${TARGET}" "$PS"

echo
echo "Detonation complete. Check Splunk:"
echo "  index=* host=*${RANGE_ID}-winclient1* (Sysmon EID 1 OR EventCode IN (1116,1117))"
echo "  | table _time, EventCode, Image, CommandLine, Threat*"
