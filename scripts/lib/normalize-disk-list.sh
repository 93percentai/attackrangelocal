#!/usr/bin/env bash
# Normalize DISK_DEVICE_LIST to a TOML array literal for answer.toml.j2:
#   disk-list = ${DISK_DEVICE_LIST}  →  disk-list = ["nvme0n1"]
#
# Usage:
#   source scripts/lib/normalize-disk-list.sh
#   DISK_DEVICE_LIST="$(normalize_disk_device_list "${DISK_DEVICE_LIST:-}")"

normalize_disk_device_list() {
  local v="${1:-}"
  v="${v//$'\r'/}"
  v="${v//$'\n'/}"
  v="${v// /}"
  # Strip shell-style wrapping quotes from wizard / hand-edited .env files.
  while [[ "$v" =~ ^\'.*\'$ || "$v" =~ ^\".*\"$ ]]; do
    v="${v#\'}"; v="${v%\'}"
    v="${v#\"}"; v="${v%\"}"
  done
  v="${v//\\\"/\"}"
  if [[ "$v" =~ ^\[\"[^\"]+\"\]$ ]]; then
    printf '%s' "$v"
  elif [[ "$v" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    printf '%s' "[\"${v}\"]"
  elif [[ "$v" =~ ^\[([a-zA-Z0-9_.-]+)\]$ ]]; then
    printf '%s' "[\"${BASH_REMATCH[1]}\"]"
  else
    echo "ERROR: DISK_DEVICE_LIST must be like [\"nvme0n1\"] (got: ${1})" >&2
    return 1
  fi
}
