#!/usr/bin/env bash
# Builds the unattended attackrangelocal ISO.
#
# Inputs:
#   - .env at the repo root, fully populated (no REPLACE_ME values)
#   - The official Proxmox VE ISO (auto-downloaded if missing; 9.2 by default)
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

# Target disk for the Proxmox install, as a PLAIN device name (no
# brackets, no quotes) e.g. nvme0n1 / sda / vda. We build the TOML array
# ourselves below -- asking users to embed `["nvme0n1"]` in .env is a
# quoting trap: `set -a; source .env` strips the inner double quotes and
# renders invalid TOML.
#   nvme0n1   NVMe: modern laptops, M.2 SSDs -- DEFAULT
#   sda       SATA / SCSI: older laptops, server SATA
#   vda       VirtIO: nested QEMU/KVM testing
# PVE 9's auto-installer accepts exactly ONE disk for ext4/xfs.
: "${DISK_DEVICE:=nvme0n1}"
if [[ ! "$DISK_DEVICE" =~ ^[a-z0-9]+$ ]]; then
  echo "DISK_DEVICE must be a bare device name like nvme0n1 or sda" >&2
  echo "  (got: '$DISK_DEVICE')" >&2
  exit 1
fi
# Rendered into iso/answer.toml.j2 as: disk-list = ["nvme0n1"]
DISK_DEVICE_LIST="[\"${DISK_DEVICE}\"]"
export DISK_DEVICE DISK_DEVICE_LIST

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
  echo "Install it with: sudo scripts/install-pai.sh" >&2
  echo "(It picks the build your glibc can run — Proxmox's trixie .deb needs" >&2
  echo " glibc >= 2.39 and will not install on Ubuntu 22.04 or older.)" >&2
  exit 1
fi
# PAI 8.x bakes PVE 9 ISOs correctly, but it does not warn about deprecated
# snake_case answer keys, so the deprecation check below cannot fire. Say so
# rather than implying the full gate ran.
PAI_VERSION="$(proxmox-auto-install-assistant --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ "${PAI_VERSION%%.*}" == "8" ]]; then
  echo "NOTE: proxmox-auto-install-assistant ${PAI_VERSION} (8.x) builds PVE 9 ISOs"
  echo "      fine, but it does not flag deprecated snake_case answer keys, so"
  echo "      that part of the validation gate is inert. answer.toml.j2 ships"
  echo "      kebab-case, so this only matters if you hand-edit it."
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

# ---------- 3. Pack the repo into the payload ----------
# The whole repo rides along inside the first-boot script, so the target box
# never clones anything: what you built is exactly what runs, and the ISO
# works on a host that cannot reach GitHub.
#
# This is only possible because the repo is small. Sizes as of writing:
#   repo.tar.gz  ~150 KB   ->  base64  ~200 KB   =  ~19% of PAI's 1 MiB cap
# The size guard further down fails the build if that ever stops being true.
#
# We tar the WORKING TREE, not `git archive HEAD`, so uncommitted edits ship
# too -- if you changed a script and are building an ISO from it, you meant
# to deploy that change. It also means the build works outside a git
# checkout (e.g. from the released tarball).
echo "==> Packing repo into the first-boot payload..."
REPO_TGZ="${BUILD_DIR}/repo.tar.gz"

# WHICH files ship matters as much as how. .gitignore lists things that must
# never leave this machine -- ludus/splunk-users.yml (plaintext passwords),
# rendered range-config.yml / inventory.yml, *.pem, *.key, **/secrets.env.
# An --exclude list has to re-state all of that and silently ships anything
# it forgets, so drive the file list from git instead: `git ls-files` is
# exactly "tracked, therefore not ignored".
#
# tar reads the WORKING TREE copy of each listed path, so uncommitted edits
# to tracked files do ship -- if you changed a script and are building an ISO
# from it, you meant to deploy that change. Brand-new untracked files do not;
# the build warns about them so it is never a silent surprise.
if git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  UNTRACKED="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard)"
  if [[ -n "$UNTRACKED" ]]; then
    echo "    WARN: untracked files will NOT be in the ISO payload:" >&2
    printf '      %s\n' $UNTRACKED >&2
    echo "      (git add them if they should ship)" >&2
  fi
  git -C "$REPO_ROOT" ls-files -z \
    | tar -C "$REPO_ROOT" --null -T - -czf "$REPO_TGZ"
else
  # Released tarball / no git. Fall back to explicit excludes, mirroring
  # every secret pattern in .gitignore.
  echo "    (not a git checkout — using the exclude list)"
  tar -C "$REPO_ROOT" -czf "$REPO_TGZ" \
    --exclude='./.git' --exclude='./.env' --exclude='./ludus/.env' \
    --exclude='*secrets.env' --exclude='*.pem' --exclude='*.key' \
    --exclude='./ssh-keys' --exclude='./ludus/splunk-users.yml' \
    --exclude='./ansible/splunk-users.yml' \
    --exclude='./ludus/range-config.yml' --exclude='./ansible/inventory.yml' \
    --exclude='./iso/cache' --exclude='./iso/build' --exclude='*.iso' \
    --exclude='./ui/node_modules' --exclude='./ui/dist' --exclude='./ui/.astro' \
    --exclude='./attack_range_fork/upstream' --exclude='__pycache__' \
    --exclude='*.log' \
    .
fi

# Provenance: .git does not ship, so record what this was built from.
# scripts/diagnose-firstboot.sh reads this on the target box.
GIT_DESC="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo 'not-a-git-checkout')"
GIT_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
  GIT_DIRTY=" (working tree had uncommitted changes -- they ARE in this ISO)"
else
  GIT_DIRTY=""
fi
echo "    source: ${GIT_BRANCH} @ ${GIT_DESC}${GIT_DIRTY}"
echo "    payload: $(du -h "$REPO_TGZ" | cut -f1) ($(stat -c '%s' "$REPO_TGZ") bytes)"

# ---------- 4. Download Proxmox ISO (cached) ----------
# Pinned to a specific Proxmox VE release for reproducible builds.
# PVE 9.x is Debian 13 (Trixie) based. Ludus supports Proxmox 8 and 9.
# The answer.toml in iso/answer.toml.j2 validates unchanged on both
# 8.4 and 9.2 (all keys already kebab-case).
# To build against a different release, set PROXMOX_ISO_URL and use a
# matching proxmox-auto-install-assistant (8.x <-> bookworm, 9.x <-> trixie).
: "${PROXMOX_ISO_URL:=https://enterprise.proxmox.com/iso/proxmox-ve_9.2-1.iso}"
PROXMOX_ISO_NAME="$(basename "$PROXMOX_ISO_URL")"
PROXMOX_ISO="${CACHE_DIR}/${PROXMOX_ISO_NAME}"
if [[ ! -f "$PROXMOX_ISO" ]]; then
  echo "==> Downloading $PROXMOX_ISO_URL ..."
  curl -fL --retry 4 -o "$PROXMOX_ISO" "$PROXMOX_ISO_URL"
fi

# ---------- 5. Validate the answer file ----------
# NOTE: `validate-answer` in every PVE 9 PAI (verified on 9.0.9 - 9.2.8)
# exits 0 even for malformed TOML and for deprecated keys. PAI 8.x exited
# non-zero correctly. So we must NOT trust $? here -- inspect the output.
echo "==> Validating answer.toml..."
VALIDATE_OUT="$(proxmox-auto-install-assistant validate-answer \
                  "${BUILD_DIR}/answer.toml" 2>&1 || true)"
printf '%s\n' "$VALIDATE_OUT" | sed 's/^/    /'

# PAI emits errors as lines beginning "Error" (e.g. "Error parsing answer
# file: ..." / "Error: Found issues in the answer file."). Anchor to line
# start so the success text "no errors found!" doesn't false-positive.
if printf '%s\n' "$VALIDATE_OUT" | grep -qE '^Error'; then
  echo "ERROR: answer.toml failed validation (see above)." >&2
  echo "       File: ${BUILD_DIR}/answer.toml" >&2
  exit 1
fi
if printf '%s' "$VALIDATE_OUT" | grep -qi 'deprecated'; then
  echo "ERROR: answer.toml uses deprecated keys. PVE 9 warns today and will" >&2
  echo "       hard-fail in a future release. Fix iso/answer.toml.j2 to use" >&2
  echo "       kebab-case keys (root-password, root-ssh-keys, disk-list)." >&2
  exit 1
fi
if ! printf '%s' "$VALIDATE_OUT" | grep -q 'parsed successfully'; then
  echo "ERROR: validate-answer did not report success. Output above." >&2
  exit 1
fi

# ---------- 6. Build the first-boot wrapper ----------
# PAI's prepare-iso accepts ONE first-boot executable, max 1 MiB. Everything
# the target box needs goes in it:
#   1. secrets.env (~1 KB)  -> /var/lib/proxmox-firstboot/secrets.env
#   2. the repo tarball     -> /var/lib/proxmox-firstboot/repo.tar.gz
#   3. a provenance stamp   -> /var/lib/proxmox-firstboot/build-info
#   4. the inlined first-boot body, which unpacks (2) and proceeds
# No git clone, no REPO_URL/REPO_REF, no network needed to obtain the code.
echo "==> Building first-boot wrapper..."
WRAPPED_FB="${BUILD_DIR}/first-boot-wrapped.sh"
{
  echo '#!/usr/bin/env bash'
  echo "# Generated by iso/build-iso.sh on $(date -u +%FT%TZ)"
  echo "# DO NOT EDIT — regenerate with: ./iso/build-iso.sh"
  echo 'set -euo pipefail'
  echo
  echo 'mkdir -p /var/lib/proxmox-firstboot'
  echo
  echo '# --- operator .env, baked at build time ---'
  echo "base64 -d > /var/lib/proxmox-firstboot/secrets.env <<'SECRETS_B64_EOF'"
  base64 "${PAYLOAD_STAGE}/secrets.env"
  echo 'SECRETS_B64_EOF'
  echo 'chmod 600 /var/lib/proxmox-firstboot/secrets.env'
  echo
  echo '# --- the repo itself, baked at build time ---'
  echo "base64 -d > /var/lib/proxmox-firstboot/repo.tar.gz <<'REPO_B64_EOF'"
  base64 "$REPO_TGZ"
  echo 'REPO_B64_EOF'
  echo
  echo "cat > /var/lib/proxmox-firstboot/build-info <<'BUILD_INFO_EOF'"
  echo "built:  $(date -u +%FT%TZ)"
  echo "branch: ${GIT_BRANCH}"
  echo "commit: ${GIT_DESC}"
  echo "dirty:  $([[ -n "$GIT_DIRTY" ]] && echo yes || echo no)"
  echo "range:  ${RANGE_ID}"
  echo 'BUILD_INFO_EOF'
  echo
  echo '# --- inlined iso/first-boot.sh body ---'
  # Skip the template's shebang + initial `set -euo pipefail`.
  sed '1,/^set -euo pipefail$/d' "${ISO_DIR}/first-boot.sh"
} > "$WRAPPED_FB"
chmod +x "$WRAPPED_FB"

# Pre-flight the size limit so we fail clearly instead of via PAI.
WRAPPER_BYTES=$(stat -c '%s' "$WRAPPED_FB")
WRAPPER_PCT=$(( WRAPPER_BYTES * 100 / 1048576 ))
echo "    Wrapper: $WRAPPED_FB"
echo "             ${WRAPPER_BYTES} bytes — ${WRAPPER_PCT}% of PAI's 1 MiB cap"
if [[ $WRAPPER_BYTES -gt 1048576 ]]; then
  echo "ERROR: wrapper is ${WRAPPER_BYTES} bytes; PAI caps first-boot at 1 MiB" >&2
  echo "       The embedded repo tarball is the big contributor. Either trim" >&2
  echo "       what section 3 packs (add --exclude patterns), or go back to" >&2
  echo "       fetching the repo at first boot." >&2
  exit 1
fi
if [[ $WRAPPER_PCT -gt 70 ]]; then
  echo "WARN: wrapper is at ${WRAPPER_PCT}% of the 1 MiB cap — getting tight." >&2
fi

# Prove the payload survives the base64 round-trip before we bake it into an
# ISO that takes ~3 hours to find out otherwise.
echo "==> Verifying embedded payload round-trips..."
VERIFY_DIR="${BUILD_DIR}/verify"
rm -rf "$VERIFY_DIR"; mkdir -p "$VERIFY_DIR"
sed -n "/^base64 -d > \/var\/lib\/proxmox-firstboot\/repo.tar.gz <<'REPO_B64_EOF'$/,/^REPO_B64_EOF$/p" \
  "$WRAPPED_FB" | sed '1d;$d' | base64 -d > "${VERIFY_DIR}/repo.tar.gz"
if ! cmp -s "$REPO_TGZ" "${VERIFY_DIR}/repo.tar.gz"; then
  echo "ERROR: repo tarball does not survive the base64 round-trip." >&2
  exit 1
fi
if ! tar -tzf "${VERIFY_DIR}/repo.tar.gz" >/dev/null 2>&1; then
  echo "ERROR: embedded repo tarball is not a readable tar.gz." >&2
  exit 1
fi
# The scripts first-boot calls must actually be in there, and executable.
tar -xzf "${VERIFY_DIR}/repo.tar.gz" -C "$VERIFY_DIR"
for f in scripts/bootstrap-ludus.sh scripts/install-roles.sh \
         scripts/deploy-range.sh scripts/install-monitoring.sh \
         scripts/lock-down.sh scripts/start-continuous-sim.sh; do
  if [[ ! -f "${VERIFY_DIR}/${f}" ]]; then
    echo "ERROR: embedded payload is missing ${f}" >&2
    exit 1
  fi
  if [[ ! -x "${VERIFY_DIR}/${f}" ]]; then
    echo "ERROR: ${f} lost its executable bit in the payload" >&2
    exit 1
  fi
done
# Belt-and-braces: whatever packed this, nothing secret may be inside. The
# ISO already carries secrets.env by design; it must not ALSO carry an
# operator's private keys or plaintext password files.
# Anchored to the exact paths .gitignore protects. Deliberately NOT a loose
# match on basenames: ansible/splunk-users.yml is a playbook, and the .j2
# templates next to range-config.yml / inventory.yml must ship.
LEAKS="$(tar -tzf "${VERIFY_DIR}/repo.tar.gz" | sed 's|^\./||' | grep -E \
  '^\.env$|^ludus/\.env$|(^|/)secrets\.env$|\.pem$|\.key$|^ssh-keys/|^ludus/splunk-users\.yml$|^ludus/range-config\.yml$|^ansible/inventory\.yml$' \
  || true)"
if [[ -n "$LEAKS" ]]; then
  echo "ERROR: secret-looking files made it into the ISO payload:" >&2
  printf '       %s\n' $LEAKS >&2
  echo "       Refusing to bake them into an ISO. They are .gitignore'd for a" >&2
  echo "       reason; if one is genuinely needed, exclude it explicitly and" >&2
  echo "       pass it through secrets.env instead." >&2
  exit 1
fi
echo "    payload verified: $(tar -tzf "${VERIFY_DIR}/repo.tar.gz" | wc -l) entries, exec bits intact"
rm -rf "$VERIFY_DIR"

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

mv "$BASE_ISO" "$OUT_ISO"

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
