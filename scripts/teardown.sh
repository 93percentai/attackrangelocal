#!/usr/bin/env bash
# Cleanly removes the range:
#   1) Flips tailscale_state to "absent" on every VM
#   2) Redeploys ONLY the tailscale role so each VM de-registers from your tailnet
#   3) `ludus range rm` to destroy the VMs in Proxmox
#
# DESTRUCTIVE — all lab data is lost. Requires explicit --confirm.
set -euo pipefail

if [[ "${1:-}" != "--confirm" ]]; then
  echo "Refusing to run without --confirm. This destroys the range and removes Tailscale devices."
  exit 1
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/ludus/range-config.yml"

if [[ ! -f "$CONFIG" ]]; then
  echo "$CONFIG missing — assuming range never deployed. Just running 'ludus range rm'."
  ludus range rm --force
  exit 0
fi

sed -i.bak 's/tailscale_state: present/tailscale_state: absent/g' "$CONFIG"
ludus range config set -f "$CONFIG"
echo "Deregistering Tailscale devices..."
ludus range deploy -t user-defined-roles --only-roles ludus_tailscale || true

echo "Destroying range VMs..."
ludus range rm --force
echo "Teardown complete."
