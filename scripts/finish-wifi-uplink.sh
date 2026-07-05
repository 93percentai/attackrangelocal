#!/usr/bin/env bash
# Complete WiFi uplink when association already works (wpa_state=COMPLETED)
# but DHCP or vmbr0 NAT was never applied. Does NOT tear down wpa_supplicant.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export WIFI_FINISH_ONLY=1
exec bash "${REPO_ROOT}/scripts/setup-wifi-uplink.sh"
