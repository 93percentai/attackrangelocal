#!/usr/bin/env bash
# Configures the Proxmox host to use WiFi as its only uplink, with NAT
# (MASQUERADE) from vmbr0 → wlan. Designed to run on a freshly installed
# Proxmox VE host, called from iso/first-boot.sh when WIFI_ENABLE=true.
#
# Why NAT and not a bridge:
#   802.11 STA mode only accepts frames whose source MAC matches the
#   station. A Linux bridge would forward frames using the VM's MAC and
#   the AP would silently drop them. The canonical Proxmox-recommended
#   workaround (https://pve.proxmox.com/wiki/WLAN) is to NAT instead.
#
# Required env vars (typically sourced from /var/lib/proxmox-firstboot/secrets.env):
#   WIFI_SSID       Network name (1-32 chars)
#   WIFI_PASSWORD   WPA2-PSK pre-shared key
#   WIFI_COUNTRY    2-letter ISO regulatory code (default US)
#   WIFI_INTERFACE  Override the auto-detected interface (optional)
#   WIFI_DISABLE_WIRED_AFTER_BOOT  true = stop the install-time wired NIC
#
# Idempotent: re-running fixes a partial setup but does not break a
# working one. Exit non-zero on the first hard error.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INTERFACES_BACKUP=/var/lib/proxmox-firstboot/interfaces.bak-attackrangelocal
INTERFACES_D_BACKUP=/var/lib/proxmox-firstboot/interfaces.d.bak-attackrangelocal

# Load baked secrets when invoked manually (`source secrets.env` in the parent
# shell does NOT export vars to this subprocess unless you used `set -a`).
if [[ -z "${WIFI_SSID:-}" || -z "${WIFI_PASSWORD:-}" ]]; then
  for secrets in /var/lib/proxmox-firstboot/secrets.env \
                 "${SCRIPT_DIR}/../.env" \
                 /opt/attackrangelocal/.env; do
    if [[ -f "$secrets" ]]; then
      set -a
      # shellcheck disable=SC1090
      source "$secrets"
      set +a
      break
    fi
  done
fi

: "${WIFI_SSID:?WIFI_SSID must be set (check /var/lib/proxmox-firstboot/secrets.env)}"
: "${WIFI_PASSWORD:?WIFI_PASSWORD must be set (check /var/lib/proxmox-firstboot/secrets.env)}"
WIFI_COUNTRY="${WIFI_COUNTRY:-US}"
WIFI_INTERFACE="${WIFI_INTERFACE:-}"
WIFI_DISABLE_WIRED_AFTER_BOOT="${WIFI_DISABLE_WIRED_AFTER_BOOT:-false}"
NAT_SUBNET="${NAT_SUBNET:-10.10.10.0/24}"
NAT_GATEWAY="${NAT_GATEWAY:-10.10.10.1/24}"

log()  { echo "[$(date -u +%FT%TZ)] wifi: $*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

# shellcheck source=lib/ensure-debian-apt.sh
source "${SCRIPT_DIR}/lib/ensure-debian-apt.sh"

backup_interfaces() {
  if [[ ! -f "$INTERFACES_BACKUP" ]]; then
    mkdir -p "$(dirname "$INTERFACES_BACKUP")"
    cp -a /etc/network/interfaces "$INTERFACES_BACKUP"
    rm -rf "$INTERFACES_D_BACKUP"
    if [[ -d /etc/network/interfaces.d ]]; then
      cp -a /etc/network/interfaces.d "$INTERFACES_D_BACKUP"
    fi
    log "backed up network config to ${INTERFACES_BACKUP}"
  fi
}

reconfigure_vmbr0_for_nat() {
  log "reconfiguring vmbr0 for NAT through ${WIFI_INTERFACE}..."
  python3 - "$WIFI_INTERFACE" "$NAT_SUBNET" "$NAT_GATEWAY" <<'PYEOF'
import re, sys, pathlib
iface, subnet, gateway = sys.argv[1:4]
p = pathlib.Path("/etc/network/interfaces")
text = p.read_text()

new_block = f"""# vmbr0 reconfigured for WiFi NAT by attackrangelocal first-boot.
# Lab VMs (incl. Ludus router uplink) sit on this bridge; iptables
# MASQUERADE rewrites their packets to look like they came from {iface}.
auto vmbr0
iface vmbr0 inet static
    address {gateway}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up   iptables -t nat -C POSTROUTING -s {subnet} -o {iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s {subnet} -o {iface} -j MASQUERADE
    post-up   iptables -C FORWARD -i vmbr0 -o {iface} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i vmbr0 -o {iface} -j ACCEPT
    post-up   iptables -C FORWARD -i {iface} -o vmbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i {iface} -o vmbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT
    post-down iptables -t nat -D POSTROUTING -s {subnet} -o {iface} -j MASQUERADE 2>/dev/null || true
    post-down iptables -D FORWARD -i vmbr0 -o {iface} -j ACCEPT 2>/dev/null || true
    post-down iptables -D FORWARD -i {iface} -o vmbr0 -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
"""

pat = re.compile(
    r"(^|\n)(auto\s+vmbr0\s*\n)?iface\s+vmbr0\s+inet[^\n]*\n(?:[ \t]+[^\n]*\n)*",
    re.MULTILINE,
)
if pat.search(text):
    text = pat.sub("\n" + new_block, text, count=1)
else:
    text += "\n" + new_block
p.write_text(text)
print("rewrote /etc/network/interfaces")
PYEOF
}

backup_interfaces

# ---------- 1. Install firmware + tools (over the WIRED uplink) ----------
log "installing wpa_supplicant + non-free firmware (apt over wired)..."
ensure_debian_bookworm_apt
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  wpasupplicant wireless-tools iw rfkill iptables-persistent \
  firmware-iwlwifi firmware-realtek firmware-misc-nonfree \
  firmware-atheros firmware-brcm80211 || \
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  wpasupplicant wireless-tools iw rfkill iptables-persistent \
  pve-firmware || \
  fail "apt install failed — WiFi firmware not pulled. Wired uplink working?"

# ---------- 2. Unblock the radio + set regdomain ----------
log "unblocking rfkill + setting regdomain to ${WIFI_COUNTRY}..."
rfkill unblock all || true
echo "REGDOMAIN=${WIFI_COUNTRY}" > /etc/default/crda
iw reg set "${WIFI_COUNTRY}" 2>/dev/null || \
  log "WARN: iw reg set failed (kernel may apply at first ifup instead)"

# ---------- 3. Find the WiFi interface ----------
if [[ -z "$WIFI_INTERFACE" ]]; then
  WIFI_INTERFACE="$(iw dev 2>/dev/null | awk '$1=="Interface"{print $2; exit}')"
fi
[[ -z "$WIFI_INTERFACE" ]] && fail "no WiFi interface found. Check 'iw dev' and 'lspci | grep -i wireless'."
log "using WiFi interface: ${WIFI_INTERFACE}"

# ---------- 4. Write wpa_supplicant config (hashed PSK, not plaintext) ----------
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${WIFI_INTERFACE}.conf"
log "writing ${WPA_CONF}..."
install -d -m 0700 /etc/wpa_supplicant
cat > "$WPA_CONF" <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=${WIFI_COUNTRY}

EOF
wpa_passphrase "${WIFI_SSID}" "${WIFI_PASSWORD}" >> "$WPA_CONF"
chmod 600 "$WPA_CONF"

# ---------- 5. Configure WiFi in interfaces.d (wired/vmbr0 left alone for now) ----------
log "writing /etc/network/interfaces.d/wifi..."
cat > /etc/network/interfaces.d/wifi <<EOF
# Generated by scripts/setup-wifi-uplink.sh
auto ${WIFI_INTERFACE}
iface ${WIFI_INTERFACE} inet dhcp
    wpa-conf ${WPA_CONF}
    metric 50
EOF

# ---------- 6. Bring up WiFi ONLY — do not touch vmbr0 until WiFi works ----------
log "bringing up ${WIFI_INTERFACE} (wired/vmbr0 unchanged)..."
if command -v ifreload >/dev/null 2>&1; then
  ifreload -a -u "${WIFI_INTERFACE}" 2>&1 || ifup "${WIFI_INTERFACE}" 2>&1 || \
    log "WARN: ifup ${WIFI_INTERFACE} reported errors"
else
  ifup "${WIFI_INTERFACE}" 2>&1 || log "WARN: ifup ${WIFI_INTERFACE} reported errors"
fi
systemctl restart wpa_supplicant 2>/dev/null || true

# ---------- 7. Wait for WiFi to carry traffic before changing vmbr0 ----------
log "waiting up to 120s for WiFi to provide connectivity..."
ok=0
for i in $(seq 1 60); do
  if ping -c1 -W2 -I "${WIFI_INTERFACE}" 1.1.1.1 >/dev/null 2>&1; then
    ok=1; break
  fi
  sleep 2
done
if [[ $ok -eq 0 ]]; then
  echo "ERROR: WiFi never reached 1.1.1.1. Wired/vmbr0 was NOT changed." >&2
  echo "  journalctl -u wpa_supplicant --no-pager | tail -30" >&2
  echo "  iw ${WIFI_INTERFACE} link; ip addr show ${WIFI_INTERFACE}" >&2
  echo "  wpa_cli -i ${WIFI_INTERFACE} status" >&2
  exit 1
fi
log "WiFi up. IP: $(ip -4 addr show "${WIFI_INTERFACE}" | awk '/inet /{print $2; exit}')"

# ---------- 8. WiFi confirmed — now reconfigure vmbr0 for NAT ----------
reconfigure_vmbr0_for_nat
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-attackrangelocal-forward.conf
sysctl -p /etc/sysctl.d/99-attackrangelocal-forward.conf >/dev/null

log "applying vmbr0 NAT config..."
if command -v ifreload >/dev/null 2>&1; then
  ifreload -a || log "WARN: ifreload reported errors (continuing)"
else
  ifdown vmbr0 2>/dev/null || true
  ifup vmbr0
fi

# ---------- 9. Optionally tear down the install-time wired interface ----------
if [[ "${WIFI_DISABLE_WIRED_AFTER_BOOT,,}" == "true" ]]; then
  log "looking for wired interfaces to disable..."
  for nic in $(ls /sys/class/net 2>/dev/null); do
    case "$nic" in
      lo|vmbr*|"${WIFI_INTERFACE}") continue ;;
      en*|eth*|enp*|eno*|enx*)
        if [[ -e "/sys/class/net/$nic/wireless" ]]; then continue; fi
        log "disabling wired interface: $nic"
        ifdown "$nic" 2>/dev/null || true
        ip link set "$nic" down 2>/dev/null || true
        sed -i "/^auto $nic\b/,/^$/ s/^/# /" /etc/network/interfaces 2>/dev/null || true
        sed -i "/^iface $nic\b/,/^[a-zA-Z]/ { /^[a-zA-Z]/!s/^/# / }" /etc/network/interfaces 2>/dev/null || true
        ;;
    esac
  done
fi

# ---------- 10. Persist iptables rules across reboots ----------
log "persisting iptables rules via netfilter-persistent..."
mkdir -p /etc/iptables
iptables-save  > /etc/iptables/rules.v4
ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
systemctl enable netfilter-persistent >/dev/null 2>&1 || true

log "WiFi uplink configured."
log "  interface: ${WIFI_INTERFACE}"
log "  NAT:       ${NAT_SUBNET} -> ${WIFI_INTERFACE} (MASQUERADE)"
log "  vmbr0:     ${NAT_GATEWAY}"
log "Rollback:   scripts/restore-wired-uplink.sh"
