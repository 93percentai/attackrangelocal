#!/usr/bin/env bash
# Emergency rollback: restore Proxmox networking after a failed WiFi pivot.
# Run as root on the Proxmox host (local console if SSH is down).
set -euo pipefail

BACKUP=/var/lib/proxmox-firstboot/interfaces.bak-attackrangelocal
BACKUP_D=/var/lib/proxmox-firstboot/interfaces.d.bak-attackrangelocal

if [[ $EUID -ne 0 ]]; then
  echo "Run as root" >&2
  exit 1
fi

if [[ ! -f "$BACKUP" ]]; then
  echo "No backup at $BACKUP" >&2
  echo "Manual fix: put vmbr0 back on DHCP with bridge-ports <your-nic> in /etc/network/interfaces"
  echo "  ip link   # find eno1 / enp* wired NIC"
  exit 1
fi

echo "Restoring /etc/network/interfaces from $BACKUP ..."
cp -a "$BACKUP" /etc/network/interfaces
rm -f /etc/network/interfaces.d/wifi
if [[ -d "$BACKUP_D" ]]; then
  rm -rf /etc/network/interfaces.d
  cp -a "$BACKUP_D" /etc/network/interfaces.d
fi

echo "Reloading networking..."
if command -v ifreload >/dev/null 2>&1; then
  ifreload -a 2>&1 || true
else
  for nic in $(ls /sys/class/net | grep -E '^(en|eth)'); do
    ip link set "$nic" up 2>/dev/null || true
    ifup "$nic" 2>/dev/null || true
  done
  ifup vmbr0 2>/dev/null || true
fi

# Wired NIC may have been `ip link set down` by a failed WiFi pivot.
for nic in $(ls /sys/class/net 2>/dev/null | grep -E '^(en|eth)'); do
  [[ -e "/sys/class/net/$nic/wireless" ]] && continue
  ip link set "$nic" up 2>/dev/null || true
  ifup "$nic" 2>/dev/null || true
done
ifup vmbr0 2>/dev/null || true

echo "Done. Test: ping -c2 1.1.1.1"
ip -4 route show default 2>/dev/null || echo "(no default route — check gateway in /etc/network/interfaces)"
ip -4 addr show vmbr0 2>/dev/null || ip -4 route show default
