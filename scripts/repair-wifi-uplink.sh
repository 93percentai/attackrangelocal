#!/usr/bin/env bash
# Recover from a partial/failed first-boot WiFi setup (older ISO bugs:
# vmbr0 rewritten before WiFi worked, invalid ifreload usage, missing firmware
# apt repos, secrets not exported to subprocess).
#
# Run as root while ethernet is STILL plugged in. Idempotent.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP="${REPO_ROOT}/scripts/setup-wifi-uplink.sh"
FINISH="${REPO_ROOT}/scripts/finish-wifi-uplink.sh"
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

wifi_wpa_state() {
  wpa_cli -i "$1" status 2>/dev/null | awk -F= '/^wpa_state=/{print $2; exit}'
}

wifi_is_associated() {
  [[ "$(wifi_wpa_state "$1")" == "COMPLETED" ]]
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
  log "WiFi wpa_state:      $(wifi_wpa_state "$WIFI_IF" || echo unknown)"
  log "WiFi internet:       $(wifi_can_reach_internet "$WIFI_IF" && echo yes || echo no)"
fi

# Already on WiFi NAT — nothing to do.
if vmbr0_is_nat_pivot && [[ -n "$WIFI_IF" ]] && wifi_can_reach_internet "$WIFI_IF"; then
  log "WiFi NAT uplink already working."
  exit 0
fi

# WiFi associated but missing DHCP and/or NAT — do NOT restore wired or reset wpa.
if [[ -n "$WIFI_IF" ]] && wifi_is_associated "$WIFI_IF"; then
  log "WiFi already associated to SSID — finishing DHCP + NAT only..."
  log "NOTE: SSH over ethernet WILL drop when vmbr0 pivots to 10.10.10.1."
  if command -v tailscale >/dev/null 2>&1 \
    && tailscale status --json 2>/dev/null | grep -q '"BackendState":"Running"'; then
    log "      Reconnect via Tailscale: ssh root@$(hostname -s 2>/dev/null || hostname)"
  else
    log "      Use local console if SSH drops (Tailscale may not be up yet)."
  fi
  [[ -f "$FINISH" ]] || fail "missing ${FINISH}"
  exec bash "$FINISH"
fi

# Classic failure mode: vmbr0 NAT without working WiFi.
if vmbr0_is_nat_pivot && [[ -n "$WIFI_IF" ]] && ! wifi_can_reach_internet "$WIFI_IF"; then
  log "Detected broken partial WiFi pivot (vmbr0 NAT without working WiFi)."
  if [[ -f "$BACKUP" ]]; then
    log "Restoring pre-WiFi wired/vmbr0 config from backup..."
    bash "$RESTORE"
  else
    fail "no ${BACKUP} — plug ethernet and fix /etc/network/interfaces manually, then re-run"
  fi
fi

# Truly offline and not associated — restore wired backup once.
if ! host_can_reach_internet && [[ -f "$BACKUP" ]] && \
   { [[ -z "$WIFI_IF" ]] || ! wifi_is_associated "$WIFI_IF"; }; then
  log "Host has no internet and WiFi is not associated — restoring wired uplink..."
  bash "$RESTORE"
fi

host_can_reach_internet || fail "still no internet on wired — check: ip route; ip -4 addr; ifreload -a"

if [[ -n "$WIFI_IF" ]]; then
  reset_stale_wifi_state "$WIFI_IF"
fi

[[ -f "$SETUP" ]] || fail "missing ${SETUP} — run: cd ${REPO_ROOT} && git fetch origin && git pull"

log "Running full setup-wifi-uplink.sh (keep ethernet plugged in until it finishes)..."
exec bash "$SETUP"
