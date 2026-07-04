#!/usr/bin/env bash
# Renders the Attack Range config file used by simulate/API (status=running).
# Requires .env and a bootstrapped upstream checkout.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
UPSTREAM="${REPO_ROOT}/attack_range_fork/upstream"
OUT_DIR="${UPSTREAM}/config"

if [[ ! -f "$ENV_FILE" ]]; then
  echo ".env not found at $ENV_FILE" >&2
  exit 1
fi
if [[ ! -d "$UPSTREAM" ]]; then
  echo "Upstream not found. Run attack_range_fork/bootstrap.sh first." >&2
  exit 1
fi

set -a; source "$ENV_FILE"; set +a
RANGE_MODE="${RANGE_MODE:-full}"
mkdir -p "$OUT_DIR"
OUT="${OUT_DIR}/${RANGE_ID}.yml"

{
  cat <<EOF
general:
  attack_range_password: ${AD_PASSWORD}
  cloud_provider: local_ludus
  attack_range_name: attackrangelocal
  attack_range_id: ${RANGE_ID}
  status: running
  ip_whitelist: 0.0.0.0/0
  description: Local Ludus range ${RANGE_ID} (${RANGE_MODE})

attack_range:
  - name: ${RANGE_ID}-dc01
    windows: true
    ip_last_octet: 5
  - name: ${RANGE_ID}-winclient1
    windows: true
    ip_last_octet: 20
EOF
  if [[ "$RANGE_MODE" == "full" ]]; then
    cat <<EOF
  - name: ${RANGE_ID}-winsrv1
    windows: true
    ip_last_octet: 21
  - name: ${RANGE_ID}-elastic
    linux: true
    ip_last_octet: 50
EOF
  fi
  cat <<EOF
  - name: ${RANGE_ID}-splunk
    linux: true
    ip_last_octet: 10
  - name: ${RANGE_ID}-linux
    linux: true
    ip_last_octet: 30
  - name: ${RANGE_ID}-kali
    linux: true
    ip_last_octet: 40
EOF
} > "$OUT"

echo "Attack Range config -> $OUT (RANGE_MODE=${RANGE_MODE})"
