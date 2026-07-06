#!/usr/bin/env bash
# First-boot / WiFi / Tailscale triage on the Proxmox host. Run as root.
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
  echo "WIFI_ENABLE=${WIFI_ENABLE:-<unset>}"
  echo "WIFI_SSID=${WIFI_SSID:-<unset>}"
  echo "WIFI_COUNTRY=${WIFI_COUNTRY:-US}"
  echo "PROXMOX_FQDN=${PROXMOX_FQDN:-<unset>}"
  echo "TS_AUTHKEY set: $([[ -n "${TS_AUTHKEY:-}" ]] && echo yes || echo NO)"
  echo "TS_TAG=${TS_TAG:-<unset>}"
else
  echo "MISSING $SECRETS"
fi

section "Repo clone"
if [[ -d /opt/attackrangelocal/.git ]]; then
  git -C /opt/attackrangelocal rev-parse --short HEAD 2>/dev/null || true
  git -C /opt/attackrangelocal log -1 --oneline 2>/dev/null || true
else
  echo "MISSING /opt/attackrangelocal — clone-repo phase likely failed"
fi

section "Network interfaces"
ip -br link
echo
ip -4 addr show
echo
ip -4 route show

section "Internet reachability"
ping -c2 -W3 1.1.1.1 2>&1 || echo "no default-route ping to 1.1.1.1"
WIFI_IF="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')"
if [[ -n "$WIFI_IF" ]]; then
  ping -c2 -W3 -I "$WIFI_IF" 1.1.1.1 2>&1 || echo "WiFi bind-ping failed on $WIFI_IF"
fi

section "vmbr0 (WiFi NAT pivot?)"
if grep -q 'vmbr0 reconfigured for WiFi NAT' /etc/network/interfaces 2>/dev/null; then
  echo "vmbr0 NAT pivot: configured in /etc/network/interfaces"
else
  echo "vmbr0 NAT pivot: NOT applied yet"
fi
ip -4 addr show dev vmbr0 2>/dev/null || true

section "Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  systemctl is-active tailscaled 2>/dev/null || true
  tailscale status 2>&1 || true
else
  echo "tailscale CLI not installed — install-tailscale-on-host phase never completed"
fi

section "WiFi (quick)"
if [[ -n "$WIFI_IF" ]]; then
  wpa_cli -i "$WIFI_IF" status 2>/dev/null || echo "wpa_cli failed"
else
  echo "no WiFi interface detected (iw dev)"
fi
if [[ -f "${REPO_ROOT}/scripts/diagnose-wifi.sh" ]]; then
  bash "${REPO_ROOT}/scripts/diagnose-wifi.sh" "$WIFI_IF" 2>/dev/null || true
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
If phase stuck before setup-wifi-uplink:
  - Keep ethernet plugged in; check /var/log/attackrangelocal-firstboot.log for git/apt errors

If WiFi failed but wired works:
  cd /opt/attackrangelocal && git pull origin main
  bash scripts/repair-wifi-uplink.sh

If WiFi works but Tailscale missing:
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
