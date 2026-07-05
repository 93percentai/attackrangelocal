#!/usr/bin/env bash
# Quick WiFi diagnostics on the Proxmox host. Run as root.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
IFACE="${1:-}"

if [[ -z "$IFACE" ]]; then
  IFACE="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')"
fi

if [[ -f /var/lib/proxmox-firstboot/secrets.env ]]; then
  set -a
  # shellcheck disable=SC1091
  source /var/lib/proxmox-firstboot/secrets.env
  set +a
elif [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi

echo "=== diagnose-wifi ==="
echo "interface: ${IFACE:-<none>}"
echo "WIFI_SSID: ${WIFI_SSID:-<unset>}"
echo "WIFI_COUNTRY: ${WIFI_COUNTRY:-US}"
echo

rfkill list
echo
iw dev "$IFACE" link || true
echo
ip -4 addr show dev "$IFACE" 2>/dev/null || true
echo
wpa_cli -i "$IFACE" status 2>/dev/null || echo "wpa_cli failed"
echo
if [[ -n "${WIFI_SSID:-}" ]]; then
  echo "Scan (looking for ${WIFI_SSID}):"
  iw dev "$IFACE" scan 2>/dev/null | grep -E 'SSID:|signal:' | head -30 || true
fi
echo
journalctl -u "wpa_supplicant@${IFACE}" --no-pager -n 20 2>/dev/null || \
  journalctl -u wpa_supplicant --no-pager -n 20 2>/dev/null || true
