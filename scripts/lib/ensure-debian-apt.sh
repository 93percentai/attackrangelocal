#!/usr/bin/env bash
# Idempotent: add Debian bookworm apt sources (incl. non-free-firmware) on a
# Proxmox VE host so firmware-iwlwifi and friends are installable. PVE-only
# repos replace those packages with pve-firmware; Debian repos unblock WiFi
# setup when ISO-bundled .debs are absent.
#
# Usage (as root):
#   source scripts/lib/ensure-debian-apt.sh
#   ensure_debian_bookworm_apt
#   apt-get update

ensure_debian_bookworm_apt() {
  if [[ $EUID -ne 0 ]]; then
    echo "ensure_debian_bookworm_apt must run as root" >&2
    return 1
  fi

  # Prefer Proxmox packages on upgrade; pull firmware/tools from Debian when asked.
  if [[ ! -f /etc/apt/preferences.d/99-attackrangelocal-proxmox.pref ]]; then
    cat >/etc/apt/preferences.d/99-attackrangelocal-proxmox.pref <<'EOF'
Package: *
Pin: release o=Proxmox VE
Pin-Priority: 1002

Package: *
Pin: release o=Proxmox,a=pve-no-subscription
Pin-Priority: 1002

Package: *
Pin: release o=Debian
Pin-Priority: 500
EOF
  fi

  if [[ ! -f /etc/apt/sources.list.d/debian-bookworm.list ]]; then
    cat >/etc/apt/sources.list.d/debian-bookworm.list <<'EOF'
# attackrangelocal — WiFi firmware + wpa tools from upstream Debian.
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF
    echo "Added Debian bookworm apt sources (non-free-firmware)."
  fi

  # Extend the installer’s stock Debian line when sources.list is still in use.
  if [[ -f /etc/apt/sources.list ]] && \
     grep -qE '^deb[[:space:]]+.*bookworm[[:space:]]+main' /etc/apt/sources.list && \
     ! grep -qE 'non-free-firmware' /etc/apt/sources.list; then
    sed -i 's/^\(deb[[:space:]].*bookworm[[:space:]]\+main\)$/\1 contrib non-free non-free-firmware/' \
      /etc/apt/sources.list
    echo "Extended /etc/apt/sources.list with contrib non-free non-free-firmware."
  fi
}
