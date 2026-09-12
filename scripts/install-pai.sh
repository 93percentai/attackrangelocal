#!/usr/bin/env bash
# Install proxmox-auto-install-assistant (PAI), the tool iso/build-iso.sh
# uses to bake the answer file and first-boot script into the Proxmox ISO.
#
# Proxmox ships PAI per Debian suite, and the suite decides which glibc the
# binary needs:
#
#   trixie   (PVE 9.x)  -> needs glibc >= 2.39, libssl3t64, libzstd >= 1.5.5
#                          i.e. Debian 13, Ubuntu 24.04+
#   bookworm (PVE 8.x)  -> needs glibc >= 2.34 only
#                          i.e. Debian 12, Ubuntu 22.04+
#
# On Ubuntu 22.04 the trixie build CANNOT be installed (glibc 2.35 < 2.39)
# and apt fails with "Depends: libc6 (>= 2.39) ... libssl3t64 ... is not
# installable". Use the bookworm build there.
#
# The PAI major version does NOT have to match the Proxmox ISO's major
# version: PAI 8.4.6 bakes a PVE 9.2 ISO correctly (verified — answer.toml,
# auto-installer-capable, auto-installer-mode.toml and proxmox-first-boot
# all land on the output ISO).
#
# One caveat for 8.x: it does not warn about deprecated snake_case answer
# keys, so iso/build-iso.sh's deprecation check is inert under it. Our
# answer.toml.j2 is kebab-case already, so this only matters if you
# hand-edit it.
#
# Usage:  sudo scripts/install-pai.sh
set -euo pipefail

BASE=http://download.proxmox.com/debian/pve/dists
TRIXIE_PAI=proxmox-auto-install-assistant_9.2.8_amd64.deb
BOOKWORM_PAI=proxmox-auto-install-assistant_8.4.6_amd64.deb

if command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
  echo "Already installed: $(proxmox-auto-install-assistant --version 2>&1 | head -1)"
  exit 0
fi

if ! command -v ldd >/dev/null 2>&1; then
  echo "Cannot detect glibc (no ldd). Install PAI manually; see the comments" >&2
  echo "at the top of this script for which suite to pick." >&2
  exit 1
fi

GLIBC="$(ldd --version | head -1 | grep -oE '[0-9]+\.[0-9]+$' || true)"
if [[ -z "$GLIBC" ]]; then
  echo "Could not parse a glibc version from 'ldd --version'." >&2
  exit 1
fi

# Pick trixie only when glibc is >= 2.39 (sort -V puts the smaller first).
if [[ "$(printf '%s\n2.39\n' "$GLIBC" | sort -V | head -1)" == "2.39" ]]; then
  SUITE=trixie; PKG="$TRIXIE_PAI"
else
  SUITE=bookworm; PKG="$BOOKWORM_PAI"
fi

echo "glibc $GLIBC detected -> using the $SUITE build ($PKG)"

DEB="$(mktemp --suffix=.deb)"
trap 'rm -f "$DEB"' EXIT
curl -fsSL --retry 4 -o "$DEB" "${BASE}/${SUITE}/pve-no-subscription/binary-amd64/${PKG}"

if [[ $EUID -ne 0 ]]; then
  echo "Re-run with sudo to install: sudo scripts/install-pai.sh" >&2
  echo "(downloaded .deb kept at $DEB)" >&2
  trap - EXIT
  exit 1
fi

apt-get install -y "$DEB"
echo "Installed: $(proxmox-auto-install-assistant --version 2>&1 | head -1)"
