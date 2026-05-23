#!/usr/bin/env bash
# Builds the unattended attackrangelocal ISO.
#
# Inputs:
#   - .env at the repo root, fully populated (no REPLACE_ME values)
#   - The official Proxmox VE 8.2+ ISO (auto-downloaded if missing)
#   - `proxmox-auto-install-assistant` installed on this host
#       Debian/Ubuntu: apt install proxmox-auto-install-assistant
#       (Or build from source: github.com/proxmox/pve-installer)
#
# Output:
#   - iso/build/attackrangelocal-<RANGE_ID>-<DATE>.iso
#   - SHA256 printed to stdout
#
# After build:
#   sudo dd if=<ISO> of=/dev/sdX bs=4M status=progress conv=fsync
#   ... then boot the target machine from the USB.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ISO_DIR="${REPO_ROOT}/iso"
BUILD_DIR="${ISO_DIR}/build"
CACHE_DIR="${ISO_DIR}/cache"
PAYLOAD_STAGE="${BUILD_DIR}/payload"
mkdir -p "$BUILD_DIR" "$CACHE_DIR" "$PAYLOAD_STAGE"

# ---------- 1. Validate environment ----------
ENV_FILE="${REPO_ROOT}/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing .env. Copy ludus/.env.example to .env at the repo root first." >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

required=(RANGE_ID TS_AUTHKEY TS_API_KEY AD_DOMAIN_FQDN AD_DOMAIN_ADMIN
          AD_PASSWORD LUDUS_ADMIN_PASSWORD OPERATOR_SSH_PUBKEY TS_TAG)
for v in "${required[@]}"; do
  val="${!v:-}"
  if [[ -z "$val" || "$val" == REPLACE_ME* ]]; then
    echo "Required env var $v is unset or still a placeholder" >&2
    exit 1
  fi
done

if ! command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
  echo "proxmox-auto-install-assistant not found." >&2
  echo "Install on Debian/Ubuntu: sudo apt install proxmox-auto-install-assistant" >&2
  exit 1
fi
if ! command -v envsubst >/dev/null 2>&1; then
  echo "envsubst not found (apt install gettext-base)" >&2
  exit 1
fi

# ---------- 2. Render answer.toml + secrets.env into stage ----------
echo "==> Rendering answer.toml and secrets.env..."
envsubst < "${ISO_DIR}/answer.toml.j2" > "${BUILD_DIR}/answer.toml"

# secrets.env is just the operator-supplied .env, baked into the ISO.
# It is NOT pulled from the network at runtime. Destroy the ISO after use.
cp "$ENV_FILE" "${PAYLOAD_STAGE}/secrets.env"
chmod 600 "${PAYLOAD_STAGE}/secrets.env"

# ---------- 3. Stage the payload tarball ----------
echo "==> Staging payload..."
TAR_STAGE="${BUILD_DIR}/payload-root"
rm -rf "$TAR_STAGE"
mkdir -p "$TAR_STAGE/iso/payload"
cp "${PAYLOAD_STAGE}/secrets.env" "$TAR_STAGE/iso/payload/secrets.env"
# Copy everything except .env, build artifacts, and the cloned upstream.
rsync -a \
  --exclude='.git/' \
  --exclude='.env' \
  --exclude='iso/build/' \
  --exclude='iso/cache/' \
  --exclude='attack_range_fork/upstream/' \
  "${REPO_ROOT}/" "$TAR_STAGE/"

tar -czf "${BUILD_DIR}/attackrangelocal-payload.tar.gz" -C "$TAR_STAGE" .
chmod 600 "${BUILD_DIR}/attackrangelocal-payload.tar.gz"
rm -rf "$TAR_STAGE"

# ---------- 4. Download Proxmox ISO (cached) ----------
: "${PROXMOX_ISO_URL:=https://enterprise.proxmox.com/iso/proxmox-ve_8.2-1.iso}"
PROXMOX_ISO_NAME="$(basename "$PROXMOX_ISO_URL")"
PROXMOX_ISO="${CACHE_DIR}/${PROXMOX_ISO_NAME}"
if [[ ! -f "$PROXMOX_ISO" ]]; then
  echo "==> Downloading $PROXMOX_ISO_URL ..."
  curl -fL --retry 4 -o "$PROXMOX_ISO" "$PROXMOX_ISO_URL"
fi

# ---------- 5. Validate the answer file ----------
echo "==> Validating answer.toml..."
proxmox-auto-install-assistant validate-answer "${BUILD_DIR}/answer.toml"

# ---------- 6. Bake the ISO ----------
DATE_TAG="$(date +%Y%m%d)"
OUT_ISO="${BUILD_DIR}/attackrangelocal-${RANGE_ID}-${DATE_TAG}.iso"
echo "==> Preparing custom ISO -> $OUT_ISO ..."
proxmox-auto-install-assistant prepare-iso \
  "$PROXMOX_ISO" \
  --fetch-from iso \
  --answer-file "${BUILD_DIR}/answer.toml" \
  --on-first-boot "${ISO_DIR}/first-boot.sh" \
  --extra-data "${BUILD_DIR}/attackrangelocal-payload.tar.gz:/var/lib/proxmox-firstboot/attackrangelocal-payload.tar.gz" \
  --output "$OUT_ISO"

# ---------- 7. Hash + flash instructions ----------
echo
echo "============================================================"
echo "Built: $OUT_ISO"
sha256sum "$OUT_ISO"
echo "============================================================"
echo
echo "Flash to USB (replace /dev/sdX with the actual USB device):"
echo "  sudo dd if=$OUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync"
echo
echo "Then boot the target Proxmox box from that USB. The install is"
echo "fully unattended; you'll be able to ssh root@ludus-host.<tailnet>"
echo "within ~5 minutes via Tailscale, and the full range will be UP"
echo "in roughly 3 hours."
