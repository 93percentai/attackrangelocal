#!/usr/bin/env bash
# First-boot / Tailscale triage on the Proxmox host. Run as root.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATUS_FILE=/var/lib/ludus-bootstrap/status
LOG=/var/log/attackrangelocal-firstboot.log
SECRETS=/var/lib/proxmox-firstboot/secrets.env

section() { echo; echo "========== $* =========="; }

[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

section "Host"
hostname -f 2>/dev/null || hostname
uptime
echo "time: $(date -u +%FT%TZ)"

section "First-boot phase (status file)"
if [[ -f "$STATUS_FILE" ]]; then
  cat "$STATUS_FILE"
else
  echo "(no $STATUS_FILE — first-boot may not have started)"
fi

section "proxmox-first-boot.service"
systemctl is-enabled proxmox-first-boot.service 2>/dev/null || echo "unit not enabled"
systemctl is-active proxmox-first-boot.service 2>/dev/null || echo "unit not active"
systemctl status proxmox-first-boot.service --no-pager -l 2>/dev/null | tail -20 || true

section "Secrets baked into ISO"
if [[ -f "$SECRETS" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS"
  set +a
  echo "PROXMOX_FQDN=${PROXMOX_FQDN:-<unset>}"
  echo "TS_AUTHKEY set: $([[ -n "${TS_AUTHKEY:-}" ]] && echo yes || echo NO)"
  echo "TS_TAG=${TS_TAG:-<unset>}"
else
  echo "MISSING $SECRETS"
fi

section "Payload"
# The repo is unpacked from the ISO, not cloned, so there is no .git here.
# iso/build-iso.sh stamps what it was built from into .build-info.
if [[ -d /opt/attackrangelocal ]]; then
  echo "files: $(find /opt/attackrangelocal -type f | wc -l)"
  if [[ -f /opt/attackrangelocal/.build-info ]]; then
    cat /opt/attackrangelocal/.build-info
  else
    echo "no .build-info — payload may predate the embedded-repo change"
  fi
else
  echo "MISSING /opt/attackrangelocal — unpack-repo phase likely failed"
fi

section "Network interfaces"
ip -br link
echo
ip -4 addr show
echo
ip -4 route show

section "Internet reachability"
ping -c2 -W3 1.1.1.1 2>&1 || echo "no default-route ping to 1.1.1.1"

section "vmbr0"
ip -4 addr show dev vmbr0 2>/dev/null || true

section "Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  systemctl is-active tailscaled 2>/dev/null || true
  tailscale status 2>&1 || true
else
  echo "tailscale CLI not installed — install-tailscale-on-host phase never completed"
fi

section "Last 40 lines of first-boot log"
if [[ -f "$LOG" ]]; then
  tail -40 "$LOG"
else
  echo "(no $LOG)"
  journalctl -u proxmox-first-boot --no-pager -n 30 2>/dev/null || true
fi

section "Likely next steps"
cat <<'EOF'
If phase stuck early:
  - Check ethernet is plugged in and has a DHCP lease
  - Check /var/log/attackrangelocal-firstboot.log for git/apt errors

If the uplink works but Tailscale is missing:
  source /var/lib/proxmox-firstboot/secrets.env
  curl -fsSL https://tailscale.com/install.sh | sh
  tailscale up --authkey="$TS_AUTHKEY" --hostname="${PROXMOX_FQDN%%.*}" \
    --advertise-tags="$TS_TAG" --ssh

If TS_AUTHKEY expired (tailscale up fails):
  - Generate new reusable key at https://login.tailscale.com/admin/settings/keys
  - Rebuild ISO with new key OR run tailscale up manually on host

If completely stuck (no network):
  - Local console on laptop; plug USB-ethernet for recovery
EOF
