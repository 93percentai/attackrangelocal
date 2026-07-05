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

# Normalise boolean-ish env vars so case-insensitive checks work safely.
# (Bash's `${VAR:-default,,}` parses `,,` as part of the default string,
# NOT as a case modifier — silent bug if you do that.)
WIFI_ENABLE_NORM="${WIFI_ENABLE:-false}"
export WIFI_ENABLE_NORM
# Single target disk for the Proxmox install. PVE 8.4 only allows ONE disk
# in disk-list for ext4. Default = nvme0n1 (most modern laptops & 2020+ SSDs).
# Common overrides:
#   sda        SATA / SCSI drives (older laptops, server SATA)
#   nvme0n1    NVMe (modern laptops, M.2 SSDs) -- DEFAULT
#   vda        VirtIO (nested QEMU/KVM testing)
: "${DISK_DEVICE_LIST:='["nvme0n1"]'}"
export DISK_DEVICE_LIST

required=(RANGE_ID TS_AUTHKEY TS_API_KEY AD_DOMAIN_FQDN AD_DOMAIN_ADMIN
          AD_PASSWORD LUDUS_ADMIN_PASSWORD OPERATOR_SSH_PUBKEY TS_TAG
          PROXMOX_FQDN)
# Defaults for vars the build needs but downstream may have left empty on
# an old .env. Keep this in sync with DEFAULTS in scripts/build-iso-wizard.sh.
: "${PROXMOX_FQDN:=ludus-attackrangelocal.range.local}"
export PROXMOX_FQDN
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

# ---------- 3. Resolve the git ref to pin the wrapper to ----------
# The wrapped first-boot script `git clone`s the repo and checks out this
# exact commit, so the deployed range matches the one that built the ISO.
echo "==> Resolving git ref for reproducible deploy..."
: "${REPO_URL:=$(git -C "${REPO_ROOT}" config --get remote.origin.url 2>/dev/null || true)}"
# Translate sandbox proxy URLs to the canonical GitHub URL if applicable.
case "$REPO_URL" in
  *93percentai/attackrangelocal*) REPO_URL="https://github.com/93percentai/attackrangelocal.git" ;;
  *dgxn4/attackrangelocal*)       REPO_URL="https://github.com/93percentai/attackrangelocal.git" ;;
esac
: "${REPO_URL:=https://github.com/93percentai/attackrangelocal.git}"
: "${REPO_REF:=$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || true)}"
if [[ -z "$REPO_REF" ]]; then
  REPO_REF=main
  echo "WARN: not a git checkout — pinning first-boot to REPO_REF=main" >&2
  echo "       Clone with git for a reproducible deploy, or set REPO_REF explicitly." >&2
fi
echo "    repo: $REPO_URL"
echo "    ref:  $REPO_REF"

# ---------- 4. Download Proxmox ISO (cached) ----------
# Pin to a Proxmox VE 8.x release. The auto-installer answer.toml format is
# stable across 8.2–8.4; PVE 9.x reorganised the installer and we haven't
# validated against it yet.
: "${PROXMOX_ISO_URL:=https://enterprise.proxmox.com/iso/proxmox-ve_8.4-1.iso}"
PROXMOX_ISO_NAME="$(basename "$PROXMOX_ISO_URL")"
PROXMOX_ISO="${CACHE_DIR}/${PROXMOX_ISO_NAME}"
if [[ ! -f "$PROXMOX_ISO" ]]; then
  echo "==> Downloading $PROXMOX_ISO_URL ..."
  curl -fL --retry 4 -o "$PROXMOX_ISO" "$PROXMOX_ISO_URL"
fi

# ---------- 4b. Download WiFi firmware (only when WIFI_ENABLE=true) ----------
# The first-boot wrapper is capped at 1 MiB, so we can't embed entire
# firmware-*.deb files (50+ MiB total). What we DO bundle: the iwlwifi
# .ucode blobs — most modern laptops use Intel WiFi, and these are
# self-contained binary blobs the kernel mmaps directly. ~5-8 MiB
# uncompressed, ~3 MiB compressed. We stash them in /var/lib/proxmox-
# firstboot/firmware/ via a side-channel staging dir on the ISO (NOT in
# the first-boot wrapper) so first-boot can dpkg/cp them post-install.
FW_DEBS=()
if [[ "${WIFI_ENABLE_NORM,,}" == "true" ]]; then
  echo "==> WIFI_ENABLE=true — downloading firmware .debs for offline install..."
  FW_CACHE="${CACHE_DIR}/firmware"
  mkdir -p "$FW_CACHE"

  # Resolve current filenames from the Debian non-free repo. The version
  # is part of the filename, so we scrape the directory listing.
  : "${FIRMWARE_URL_BASE:=https://deb.debian.org/debian/pool/non-free-firmware/f/firmware-nonfree}"
  echo "    (catalog: $FIRMWARE_URL_BASE)"
  FW_INDEX="$(curl -fsSL "$FIRMWARE_URL_BASE/" || echo "")"
  for pkg in firmware-iwlwifi firmware-realtek firmware-atheros firmware-brcm80211 firmware-misc-nonfree; do
    # Pick the latest .deb for that package (filename sort).
    fn=$(echo "$FW_INDEX" \
         | grep -oE "href=\"${pkg}_[^\"]+_all\\.deb\"" \
         | sed 's/href="\(.*\)"/\1/' \
         | sort -V | tail -1)
    if [[ -z "$fn" ]]; then
      echo "    WARN: could not resolve $pkg in $FIRMWARE_URL_BASE — skipping"
      continue
    fi
    if [[ ! -f "$FW_CACHE/$fn" ]]; then
      echo "    fetching $fn..."
      curl -fL --retry 4 -o "$FW_CACHE/$fn" "$FIRMWARE_URL_BASE/$fn"
    fi
    FW_DEBS+=("$FW_CACHE/$fn")
  done

  echo "    bundled $(printf '%s\n' "${FW_DEBS[@]}" | wc -l) firmware .deb(s):"
  printf '      %s\n' "${FW_DEBS[@]##*/}"
fi

# ---------- 5. Validate the answer file ----------
echo "==> Validating answer.toml..."
proxmox-auto-install-assistant validate-answer "${BUILD_DIR}/answer.toml"

# ---------- 6. Build the first-boot wrapper ----------
# PAI's prepare-iso accepts ONE first-boot executable, max 1 MiB. We can't
# embed the whole repo there, so the wrapper:
#   1. Drops the secrets.env (~1 KB) into /var/lib/proxmox-firstboot/
#   2. Exports REPO_URL + REPO_REF for the inlined first-boot body
#   3. Runs the first-boot body which `git clone`s and proceeds
# Total wrapper size: ~10 KB, well under the 1 MiB cap.
echo "==> Building first-boot wrapper..."
WRAPPED_FB="${BUILD_DIR}/first-boot-wrapped.sh"
SECRETS_B64=$(base64 -w0 "${PAYLOAD_STAGE}/secrets.env")
{
  echo '#!/usr/bin/env bash'
  echo "# Generated by iso/build-iso.sh on $(date -u +%FT%TZ)"
  echo "# DO NOT EDIT — regenerate with: ./iso/build-iso.sh"
  echo 'set -euo pipefail'
  echo
  echo 'mkdir -p /var/lib/proxmox-firstboot'
  echo "echo '$SECRETS_B64' | base64 -d > /var/lib/proxmox-firstboot/secrets.env"
  echo 'chmod 600 /var/lib/proxmox-firstboot/secrets.env'
  echo
  echo "export REPO_URL='$REPO_URL'"
  echo "export REPO_REF='$REPO_REF'"
  echo
  echo '# --- inlined iso/first-boot.sh body ---'
  # Skip the template's shebang + initial `set -euo pipefail`.
  sed '1,/^set -euo pipefail$/d' "${ISO_DIR}/first-boot.sh"
} > "$WRAPPED_FB"
chmod +x "$WRAPPED_FB"
echo "    Wrapper: $WRAPPED_FB  ($(du -h "$WRAPPED_FB" | cut -f1))"

# Pre-flight check the size limit so we fail clearly instead of via PAI.
WRAPPER_BYTES=$(stat -c '%s' "$WRAPPED_FB")
if [[ $WRAPPER_BYTES -gt 1048576 ]]; then
  echo "ERROR: wrapper is ${WRAPPER_BYTES} bytes; PAI caps first-boot at 1 MiB" >&2
  echo "       (likely cause: secrets.env grew unexpectedly)" >&2
  exit 1
fi

# ---------- 7. Bake the ISO ----------
DATE_TAG="$(date +%Y%m%d)"
OUT_ISO="${BUILD_DIR}/attackrangelocal-${RANGE_ID}-${DATE_TAG}.iso"
BASE_ISO="${BUILD_DIR}/attackrangelocal-${RANGE_ID}-${DATE_TAG}-base.iso"
echo "==> Preparing custom ISO via PAI..."
proxmox-auto-install-assistant prepare-iso \
  "$PROXMOX_ISO" \
  --fetch-from iso \
  --answer-file "${BUILD_DIR}/answer.toml" \
  --on-first-boot "$WRAPPED_FB" \
  --output "$BASE_ISO"

# ---------- 7b. Inject WiFi firmware via xorriso (only if WIFI_ENABLE=true) ----------
# PAI doesn't let us add extra files. We post-process the ISO with xorriso
# to add a /firmware/ tree (the .debs + a MANIFEST marker first-boot scans
# for) while preserving the El Torito boot record.
if [[ "${WIFI_ENABLE_NORM,,}" == "true" && ${#FW_DEBS[@]} -gt 0 ]]; then
  echo "==> Injecting ${#FW_DEBS[@]} firmware .deb(s) into ISO..."
  STAGE="${BUILD_DIR}/firmware-stage"
  rm -rf "$STAGE"
  mkdir -p "$STAGE/firmware"
  for d in "${FW_DEBS[@]}"; do cp "$d" "$STAGE/firmware/"; done
  # MANIFEST is the marker first-boot's media-scan looks for.
  cat > "$STAGE/firmware/MANIFEST" <<EOF
# attackrangelocal firmware bundle
# built: $(date -u +%FT%TZ)
# range: ${RANGE_ID}
$(cd "$STAGE/firmware" && sha256sum *.deb)
EOF

  # Copy the PAI-built ISO to the final location first, then add /firmware/
  # in place. -boot_image any keep preserves PAI's GRUB + El Torito records.
  # -commit flushes the modified session to disk.
  cp "$BASE_ISO" "$OUT_ISO"
  xorriso \
    -dev "$OUT_ISO" \
    -boot_image any keep \
    -map "$STAGE/firmware" /firmware \
    -commit 2>&1 \
    | tail -8

  if ! xorriso -indev "$OUT_ISO" -find /firmware/MANIFEST 2>/dev/null \
       | grep -q "/firmware/MANIFEST"; then
    echo "ERROR: firmware injection didn't land on the ISO" >&2
    exit 1
  fi

  rm -rf "$STAGE" "$BASE_ISO"
  echo "    ISO post-processed; firmware .debs visible at /firmware/ on the disc."
else
  # No firmware bundle requested — just rename the PAI output.
  mv "$BASE_ISO" "$OUT_ISO"
fi

# ---------- 8. Hash + flash instructions ----------
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
