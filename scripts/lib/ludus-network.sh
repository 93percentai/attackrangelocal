#!/usr/bin/env bash
# Detect Proxmox host network settings for Ludus server config.yml.
set -euo pipefail

cidr_to_netmask() {
  local pfx="${1:-24}"
  if command -v ipcalc >/dev/null 2>&1; then
    ipcalc -m "0.0.0.0/${pfx}" 2>/dev/null | awk -F= '/NETMASK=/{print $2; exit}'
    return 0
  fi
  case "$pfx" in
    32) echo 255.255.255.255 ;;
    24) echo 255.255.255.0 ;;
    16) echo 255.0.0.0 ;;
    8)  echo 255.0.0.0 ;;
    *)  echo 255.255.255.0 ;;
  esac
}

detect_ludus_storage_pool() {
  local pool=local
  if command -v pvesm >/dev/null 2>&1; then
    pool="$(pvesm status -content images 2>/dev/null | awk 'NR==2 {print $1; exit}')"
    [[ -z "$pool" ]] && pool=local
  fi
  echo "$pool"
}

# Prints a Ludus server config.yml on stdout. Override any field with LUDUS_PROXMOX_* env vars.
render_ludus_server_config() {
  local iface ip gateway prefix netmask node pool

  iface="${LUDUS_PROXMOX_INTERFACE:-$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')}"
  [[ -z "$iface" ]] && iface=vmbr0

  gateway="${LUDUS_PROXMOX_GATEWAY:-$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')}"
  ip="${LUDUS_PROXMOX_LOCAL_IP:-$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)}"
  prefix="${LUDUS_PROXMOX_PREFIX:-$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f2 | head -1)}"
  prefix="${prefix:-24}"
  netmask="${LUDUS_PROXMOX_NETMASK:-$(cidr_to_netmask "$prefix")}"
  node="${LUDUS_PROXMOX_NODE:-$(hostname -s)}"
  pool="${LUDUS_PROXMOX_VM_STORAGE_POOL:-$(detect_ludus_storage_pool)}"

  if [[ -z "$ip" || -z "$gateway" ]]; then
    echo "Could not detect Ludus network settings (iface=${iface}, ip=${ip:-empty}, gateway=${gateway:-empty})" >&2
    echo "Set LUDUS_PROXMOX_* overrides or fix host routing before installing Ludus." >&2
    return 1
  fi

  cat <<EOF
---
proxmox_node: ${node}
proxmox_invalid_cert: true
proxmox_interface: ${iface}
proxmox_local_ip: ${ip}
proxmox_public_ip: ${ip}
proxmox_gateway: ${gateway}
proxmox_netmask: ${netmask}
proxmox_vm_storage_pool: ${pool}
proxmox_vm_storage_format: qcow2
proxmox_iso_storage_pool: ${pool}
EOF
}
