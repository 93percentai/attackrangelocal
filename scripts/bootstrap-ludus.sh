#!/usr/bin/env bash
# Installs Ludus on a fresh Proxmox VE host. Idempotent.
#
# Run as root ON the Proxmox host (not your laptop).
# Called from iso/first-boot.sh during unattended install.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_FILE=/var/lib/ludus-bootstrap/status
mkdir -p "$(dirname "$STATUS_FILE")"

write_status() {
  echo "$1" > "$STATUS_FILE"
  if [[ -n "${NOTIFY_WEBHOOK:-}" ]]; then
    curl -fsS -X POST -H 'content-type: application/json' \
      -d "{\"text\":\"[attackrangelocal] phase: $1\"}" \
      "${NOTIFY_WEBHOOK}" >/dev/null 2>&1 || true
  fi
}

if [[ $EUID -ne 0 ]]; then
  echo "bootstrap-ludus.sh must run as root" >&2
  exit 1
fi

if [[ ! -e /etc/pve ]]; then
  echo "This script must run on a Proxmox VE host (no /etc/pve found)" >&2
  exit 1
fi

write_status proxmox-installed

if command -v ludus >/dev/null 2>&1; then
  echo "Ludus already installed: $(ludus version)"
else
  echo "Installing Ludus..."
  # Upstream installer. Pinned via env var so first-boot.sh can lock the version.
  : "${LUDUS_INSTALL_URL:=https://ludus.cloud/install}"
  curl -fsS "$LUDUS_INSTALL_URL" | bash
fi

# Wait for the Ludus API to come up.
for i in $(seq 1 60); do
  if ludus version >/dev/null 2>&1; then
    echo "Ludus API is up."
    break
  fi
  echo "Waiting for Ludus API ($i/60)..."
  sleep 5
done
if ! ludus version >/dev/null 2>&1; then
  echo "Ludus API never came up" >&2
  exit 1
fi

write_status ludus-installed
echo "Ludus version: $(ludus version)"
