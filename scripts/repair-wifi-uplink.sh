#!/usr/bin/env bash
# Recover from a partial/failed first-boot WiFi setup (older ISO bugs:
# vmbr0 rewritten before WiFi worked, invalid ifreload usage, missing firmware
# apt repos, secrets not exported to subprocess).
#
# Run as root while ethernet is STILL plugged in. Idempotent.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/scripts/setup-wifi-uplink.sh"
RESTORE="${REPO_ROOT}/scripts/restore-wired-uplink.sh"
BACKUP=/var/lib/proxmox-firstboot/interfaces.bak-attackrangelocal

log()  { echo "[repair-wifi] $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run as root"

detect_wifi_iface() {
  local iface="${WIFI_INTERFACE:-}"
  if [[ -z "$iface" ]]; then
    for secrets in /var/lib/proxmox-firstboot/secrets.env \
                   "${REPO_ROOT}/.env" /opt/attackrangelocal/.env; do
      if [[ -f "$secrets" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$secrets"
        set +a
        iface="${WIFI_INTERFACE:-}"
        break
      fi
    done
  fi
  if [[ -z "$iface" ]]; then
    iface="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')"
  fi
  echo "$iface"
}

vmbr0_is_nat_pivot() {
  grep -q 'vmbr0 reconfigured for WiFi NAT by attackrangelocal' /etc/network/interfaces 2>/dev/null \
    || ip -4 addr show vmbr0 2>/dev/null | grep -q '10\.10\.10\.1/'
}

wifi_can_reach_internet() {
  local iface="$1"
  [[ -n "$iface" ]] && ping -c1 -W2 -I "$iface" 1.1.1.1 >/dev/null 2>&1
}

host_can_reach_internet() {
  ping -c1 -W2 1.1.1.1 >/dev/null 2>&1
}

reset_stale_wifi_state() {
  local iface="$1"
  log "clearing stale WiFi state for a clean retry..."
  ifdown "$iface" 2>/dev/null || true
  ip link set "$iface" down 2>/dev/null || true
  rm -f "/etc/network/interfaces.d/wifi"
  rm -f "/etc/wpa_supplicant/wpa_supplicant-${iface}.conf"
  systemctl stop "wpa_supplicant@${iface}" 2>/dev/null || true
  systemctl stop wpa_supplicant 2>/dev/null || true
}

log "=== WiFi repair preflight ==="
WIFI_IF="$(detect_wifi_iface)"
log "WiFi interface: ${WIFI_IF:-<none detected>}"
log "Internet (any path): $(host_can_reach_internet && echo yes || echo no)"
log "vmbr0 NAT pivot:     $(vmbr0_is_nat_pivot && echo yes || echo no)"
if [[ -n "$WIFI_IF" ]]; then
  log "WiFi internet:       $(wifi_can_reach_internet "$WIFI_IF" && echo yes || echo no)"
fi

# Classic failure mode from older first-boot: vmbr0 moved to NAT but WiFi never worked.
if vmbr0_is_nat_pivot && [[ -n "$WIFI_IF" ]] && ! wifi_can_reach_internet "$WIFI_IF"; then
  log "Detected broken partial WiFi pivot (vmbr0 NAT without working WiFi)."
  if [[ -f "$BACKUP" ]]; then
    log "Restoring pre-WiFi wired/vmbr0 config from backup..."
    bash "$RESTORE"
  else
    fail "no ${BACKUP} — plug ethernet and fix /etc/network/interfaces manually, then re-run"
  fi
fi

# No route at all but we have a backup — restore wired first.
if ! host_can_reach_internet && [[ -f "$BACKUP" ]]; then
  log "Host has no internet; restoring wired uplink from backup..."
  bash "$RESTORE"
fi

host_can_reach_internet || fail "still no internet — fix wired uplink before WiFi repair"

if [[ -n "$WIFI_IF" ]]; then
  reset_stale_wifi_state "$WIFI_IF"
fi

[[ -f "$SETUP" ]] || fail "missing ${SETUP} — run: cd ${REPO_ROOT} && git fetch origin && git pull"

log "Running fixed setup-wifi-uplink.sh (keep ethernet plugged in until it finishes)..."
bash "$SETUP"
