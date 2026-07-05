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

detect_ludus_nat_interface() {
  local nat="${LUDUS_NAT_INTERFACE:-vmbr1000}"
  if command -v pvesh >/dev/null 2>&1; then
    local node
    node="$(hostname -s)"
    if pvesh get "/nodes/${node}/network" --output-format json 2>/dev/null \
      | grep -q '"iface":"vmbr1000"'; then
      echo "WARN: vmbr1000 already exists on this host; set LUDUS_NAT_INTERFACE to a free vmbr name" >&2
    fi
  fi
  echo "$nat"
}

ludus_config_is_complete() {
  local config_path="$1"
  [[ -f "$config_path" ]] || return 1
  grep -q '^ludus_nat_interface:' "$config_path" \
    && grep -q '^license_key:' "$config_path" \
    && grep -q '^database_encryption_key:' "$config_path"
}

# Prints a Ludus 2.x server config.yml on stdout. Override any field with LUDUS_* env vars.
render_ludus_server_config() {
  local iface ip gateway prefix netmask node pool nat db_key

  iface="${LUDUS_PROXMOX_INTERFACE:-$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')}"
  [[ -z "$iface" ]] && iface=vmbr0

  gateway="${LUDUS_PROXMOX_GATEWAY:-$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')}"
  ip="${LUDUS_PROXMOX_LOCAL_IP:-$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)}"
  prefix="${LUDUS_PROXMOX_PREFIX:-$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f2 | head -1)}"
  prefix="${prefix:-24}"
  netmask="${LUDUS_PROXMOX_NETMASK:-$(cidr_to_netmask "$prefix")}"
  node="${LUDUS_PROXMOX_NODE:-$(hostname -s)}"
  pool="${LUDUS_PROXMOX_VM_STORAGE_POOL:-$(detect_ludus_storage_pool)}"
  nat="$(detect_ludus_nat_interface)"
  db_key="${LUDUS_DATABASE_ENCRYPTION_KEY:-$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 32)}"

  if [[ -z "$ip" || -z "$gateway" ]]; then
    echo "Could not detect Ludus network settings (iface=${iface}, ip=${ip:-empty}, gateway=${gateway:-empty})" >&2
    echo "Set LUDUS_PROXMOX_* overrides or fix host routing before installing Ludus." >&2
    return 1
  fi

  cat <<EOF
---
proxmox_node: ${node}
proxmox_invalid_cert: true
proxmox_url: https://127.0.0.1:8006
proxmox_interface: ${iface}
proxmox_local_ip: ${ip}
proxmox_public_ip: ${ip}
proxmox_gateway: ${gateway}
proxmox_netmask: ${netmask}
proxmox_vm_storage_pool: ${pool}
proxmox_vm_storage_format: qcow2
proxmox_iso_storage_pool: ${pool}
ludus_nat_interface: ${nat}
prevent_user_ansible_add: false
license_key: community
expose_admin_port: false
port: 8080
admin_port: 8081
data_directory: /opt/ludus/db
database_encryption_key: ${db_key}
wireguard_port: 51820
max_log_history: 100
register_default_source: true
sync_sources_on_startup: true
EOF
}

ensure_ludus_server_config() {
  local config_path="$1"
  local existing_key=""

  if ludus_config_is_complete "$config_path"; then
    return 0
  fi

  if [[ -f "$config_path" ]]; then
    existing_key="$(awk -F': ' '/^database_encryption_key:/{print $2; exit}' "$config_path" | tr -d "'\" ")"
    cp -a "$config_path" "${config_path}.bak-attackrangelocal"
    echo "Replacing incomplete Ludus config (backup: ${config_path}.bak-attackrangelocal)"
  fi

  if [[ -n "$existing_key" ]]; then
    export LUDUS_DATABASE_ENCRYPTION_KEY="$existing_key"
  fi

  render_ludus_server_config >"$config_path"
}
