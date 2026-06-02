#!/usr/bin/env bash
# Interactive wizard for building the attackrangelocal unattended ISO.
#
# What this does:
#   1. Runs pre-flight checks (tools, disk space, network)
#   2. Walks you through every required and optional .env value,
#      explaining what each one is for and what format it needs
#   3. Writes .env at the repo root
#   4. Invokes iso/build-iso.sh, capturing stderr
#   5. If anything fails, decodes the error and tells you how to fix it
#
# Re-run safe: an existing .env is loaded and shown as the default for each
# prompt, so you can iterate without re-typing everything.
#
# Usage:
#   scripts/build-iso-wizard.sh             # interactive
#   scripts/build-iso-wizard.sh --build-only # skip prompts, just build
#   scripts/build-iso-wizard.sh --dry-run    # collect inputs, don't build

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
EXAMPLE="${REPO_ROOT}/ludus/.env.example"
BUILD_SCRIPT="${REPO_ROOT}/iso/build-iso.sh"

MODE=interactive
case "${1:-}" in
  --build-only) MODE=build-only ;;
  --dry-run)    MODE=dry-run ;;
  -h|--help)
    sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; /^set -euo/d'
    exit 0
    ;;
esac

# ----- pretty output -------------------------------------------------------
if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YEL=$'\033[33m'; CYAN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; CYAN=""; RST=""
fi
info()   { printf "%s\n" "$*"; }
note()   { printf "${DIM}  %s${RST}\n" "$*"; }
ok()     { printf "${GRN}✓${RST} %s\n" "$*"; }
warn()   { printf "${YEL}!${RST} %s\n" "$*"; }
err()    { printf "${RED}✗ %s${RST}\n" "$*" >&2; }
hdr()    { printf "\n${BOLD}${CYAN}── %s ──${RST}\n" "$*"; }

# ----- pre-flight ----------------------------------------------------------
preflight() {
  hdr "Pre-flight checks"
  local fail=0

  for t in envsubst curl tar rsync dd sha256sum xorriso; do
    if command -v "$t" >/dev/null 2>&1; then
      ok "$t found"
    else
      err "$t missing"
      case "$t" in
        envsubst)    note "install: apt install gettext-base   (or: brew install gettext)" ;;
        sha256sum)   note "install: apt install coreutils" ;;
        rsync)       note "install: apt install rsync          (needed by iso/build-iso.sh)" ;;
        xorriso)     note "install: apt install xorriso        (Proxmox tool depends on it)" ;;
        *)           note "install: apt install $t" ;;
      esac
      fail=1
    fi
  done

  if command -v proxmox-auto-install-assistant >/dev/null 2>&1; then
    ok "proxmox-auto-install-assistant found"
  else
    # Not fatal during dry-run — you can collect inputs first, install the
    # tool later, then build.
    if [[ "$MODE" == "dry-run" ]]; then
      warn "proxmox-auto-install-assistant not on PATH (ok for --dry-run)"
    else
      warn "proxmox-auto-install-assistant not on PATH"
    fi
    note "Required to bake the ISO. Install via Proxmox's repo:"
    note "  echo 'deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription' \\"
    note "    | sudo tee /etc/apt/sources.list.d/pve.list"
    note "  curl https://enterprise.proxmox.com/debian/proxmox-release-bookworm.gpg \\"
    note "    | sudo tee /etc/apt/trusted.gpg.d/proxmox-release.gpg >/dev/null"
    note "  sudo apt update && sudo apt install proxmox-auto-install-assistant"
    note "Or build from source: https://git.proxmox.com/?p=pve-installer.git"
    [[ "$MODE" != "dry-run" ]] && fail=1
  fi

  # Disk space: need ~4 GB for cache + build (ISO is ~1.5 GB, payload ~500 MB,
  # rebuilt ISO ~1.5 GB).
  local avail_kb
  avail_kb=$(df -k "${REPO_ROOT}" | tail -1 | awk '{print $4}')
  local avail_gb=$((avail_kb / 1024 / 1024))
  if [[ $avail_gb -ge 4 ]]; then
    ok "${avail_gb} GB free on $(df -h "${REPO_ROOT}" | tail -1 | awk '{print $1}')"
  else
    err "only ${avail_gb} GB free — need ≥ 4 GB"
    note "free up space, then re-run"
    fail=1
  fi

  if curl -fsSL --max-time 5 -o /dev/null https://enterprise.proxmox.com/iso/ 2>/dev/null; then
    ok "enterprise.proxmox.com reachable"
  else
    warn "couldn't reach enterprise.proxmox.com (5s timeout)"
    note "ISO download will fail unless this host has internet. Continuing anyway."
  fi

  if [[ $fail -ne 0 ]]; then
    err "Fix the issues above, then re-run."
    exit 1
  fi
}

# ----- prompt helpers ------------------------------------------------------
# Load any existing .env so saved values become defaults.
declare -A CURRENT
if [[ -f "$ENV_FILE" ]]; then
  while IFS='=' read -r k v; do
    [[ -z "$k" || "$k" == \#* ]] && continue
    v="${v#\"}"; v="${v%\"}"
    CURRENT["$k"]="$v"
  done < "$ENV_FILE"
fi

# Ask a question with description, default, and validation.
# Usage: ask VAR_NAME "Display name" "Description (multi-line ok)" \
#            "default-or-empty" "secret|plain" validator-func
ask() {
  local var="$1" name="$2" desc="$3" default="$4" kind="${5:-plain}" validator="${6:-}"
  local current="${CURRENT[$var]:-$default}"
  local input

  printf "\n${BOLD}%s${RST}  ${DIM}(\$%s)${RST}\n" "$name" "$var"
  printf "%s\n" "$desc" | sed 's/^/  /'

  while :; do
    if [[ "$kind" == "secret" ]]; then
      local shown
      if [[ -n "$current" ]]; then shown="(unchanged)"; else shown="(empty)"; fi
      printf "  ${CYAN}>${RST} %s: " "$shown"
      read -rs input
      echo
      [[ -z "$input" ]] && input="$current"
    else
      local hint
      if [[ -n "$current" ]]; then hint="[${current}]"; else hint=""; fi
      printf "  ${CYAN}>${RST} %s " "$hint"
      read -r input
      [[ -z "$input" ]] && input="$current"
    fi

    if [[ -n "$validator" ]] && ! "$validator" "$input"; then
      continue
    fi
    break
  done

  ANSWERS["$var"]="$input"
}

# Validators -- each returns 0 to accept, 1 (with err output) to re-prompt.
v_range_id() {
  if [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 255 )); then return 0; fi
  err "must be an integer 1..255"; return 1
}
v_range_mode() {
  case "$1" in full|minimal) return 0 ;; esac
  err "must be 'full' (30 GB host, 7 VMs + Elastic) or 'minimal' (16 GB host, 5 VMs, Splunk only)"
  return 1
}
v_ts_auth() {
  [[ "$1" =~ ^tskey-auth- ]] && return 0
  err "must start with 'tskey-auth-' (Tailscale admin -> Settings -> Keys -> Auth keys)"
  return 1
}
v_ts_api() {
  [[ "$1" =~ ^tskey-api- ]] && return 0
  err "must start with 'tskey-api-' (Tailscale admin -> Settings -> Keys -> API access tokens)"
  return 1
}
v_fqdn() {
  [[ "$1" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] && return 0
  err "must look like 'range.local' or 'lab.example.com'"
  return 1
}
v_strong_pw() {
  if (( ${#1} < 12 )); then err "password must be ≥ 12 characters"; return 1; fi
  return 0
}
v_long_key() {
  if (( ${#1} < 32 )); then err "must be ≥ 32 characters (used as AES-256 key)"; return 1; fi
  return 0
}
v_ssh_key() {
  # Accept the key itself, or a path to a file containing the key.
  if [[ -f "$1" ]]; then
    if grep -qE '^(ssh-rsa|ssh-ed25519|ssh-ecdsa|ecdsa-sha2)' "$1"; then return 0; fi
    err "file '$1' doesn't contain a recognised SSH public key"; return 1
  fi
  if [[ "$1" =~ ^(ssh-rsa|ssh-ed25519|ssh-ecdsa|ecdsa-sha2) ]]; then return 0; fi
  err "paste a public key starting with ssh-ed25519 / ssh-rsa / ..., OR give a file path"
  err "tip: $HOME/.ssh/id_ed25519.pub is the usual location"
  return 1
}
v_url_or_empty() {
  [[ -z "$1" ]] && return 0
  [[ "$1" =~ ^https?:// ]] && return 0
  err "must be empty or a https:// URL"
  return 1
}
v_bool() {
  case "${1,,}" in true|false|yes|no|y|n) return 0 ;; esac
  err "must be true/false (or yes/no)"; return 1
}
v_country() {
  if [[ "$1" =~ ^[A-Z]{2}$ ]]; then return 0; fi
  err "must be a 2-letter ISO country code, uppercase (US, GB, DE, JP, ...)"
  return 1
}
v_ssid() {
  if [[ -n "$1" && ${#1} -le 32 ]]; then return 0; fi
  err "SSID must be 1-32 characters"; return 1
}
v_iface_or_empty() {
  [[ -z "$1" ]] && return 0
  [[ "$1" =~ ^[a-z]{2,5}[0-9]+(s[0-9]+(f[0-9]+)?)?$ ]] && return 0
  err "must look like 'wlan0' or 'wlp2s0' (or empty to auto-detect)"
  return 1
}
v_int_or_empty() {
  [[ -z "$1" ]] && return 0
  [[ "$1" =~ ^[0-9]+$ ]] && return 0
  err "must be a positive integer or empty"
  return 1
}
v_anything() { return 0; }

# Expand ~ and possibly read a file for the SSH key.
finalise_ssh_key() {
  local v="${ANSWERS[OPERATOR_SSH_PUBKEY]}"
  [[ "${v:0:1}" == "~" ]] && v="${HOME}${v:1}"
  if [[ -f "$v" ]]; then v="$(< "$v")"; v="${v%$'\n'}"; fi
  ANSWERS[OPERATOR_SSH_PUBKEY]="$v"
}

# ----- collect inputs ------------------------------------------------------
declare -A ANSWERS

collect() {
  hdr "Required: range mode"
  ask RANGE_MODE "Range mode" \
"Pick the topology that fits your host:
  full     7 VMs (DC + 2 win members + splunk + ELASTIC + linux + kali)
           Needs ~30 GB RAM, 16 threads, 500 GB SSD.
  minimal  5 VMs (DC+server combined, win client, splunk, linux, kali)
           Fits 16 GB RAM, 12 threads, 256 GB SSD. No Elastic; Splunk only." \
    "${CURRENT[RANGE_MODE]:-full}" plain v_range_mode

  hdr "Required: range identity"
  ask RANGE_ID "Range ID" \
"A number 1..255. Used as the second octet of the lab subnet
(10.<RANGE_ID>.20.0/24) and as a prefix on every VM name in Proxmox.
Pick anything you like; 42 is the default." \
    "${CURRENT[RANGE_ID]:-42}" plain v_range_id

  hdr "Required: Tailscale"
  ask TS_AUTHKEY "Tailscale auth key" \
"Reusable auth key. Used to join every lab VM and the Proxmox host
itself to your tailnet. Generate at Tailscale Admin Console ->
Settings -> Keys -> 'Generate auth key' (mark Reusable + short
expiry, e.g. 24 h)." \
    "${CURRENT[TS_AUTHKEY]:-}" secret v_ts_auth

  ask TS_API_KEY "Tailscale API key" \
"Needed for clean teardown — scripts/teardown.sh uses it to deregister
the 7 lab devices from your tailnet. Generate at Tailscale Admin
Console -> Settings -> Keys -> 'Generate API access token'." \
    "${CURRENT[TS_API_KEY]:-}" secret v_ts_api

  ask TS_TAG "Tailscale tag" \
"Every lab VM gets this tag so your tailnet ACLs can restrict who
reaches them (see docs/tailscale-acls.md)." \
    "${CURRENT[TS_TAG]:-tag:lab-range}" plain v_anything

  hdr "Required: Active Directory"
  ask AD_DOMAIN_FQDN "AD forest root domain" \
"The DNS-like name of the forest root, e.g. 'range.local'. Ludus
promotes dc01 to a domain controller for this domain on first boot." \
    "${CURRENT[AD_DOMAIN_FQDN]:-range.local}" plain v_fqdn

  ask AD_DOMAIN_ADMIN "AD domain admin username" \
"Username for the domain admin Ludus creates. Avoid 'Administrator'
(reserved on Windows)." \
    "${CURRENT[AD_DOMAIN_ADMIN]:-rangeadmin}" plain v_anything

  ask AD_PASSWORD "AD domain admin password" \
"At least 12 chars; Windows AD will reject weak passwords. Used for
the domain admin AND defaults for several lab credentials." \
    "${CURRENT[AD_PASSWORD]:-}" secret v_strong_pw

  hdr "Required: Proxmox host"
  ask LUDUS_ADMIN_PASSWORD "Proxmox root password" \
"Set as the root password on the freshly installed Proxmox host.
You can rotate it after first boot." \
    "${CURRENT[LUDUS_ADMIN_PASSWORD]:-}" secret v_strong_pw

  ask OPERATOR_SSH_PUBKEY "Operator SSH public key" \
"Authorised key for root@proxmox. Paste the key (e.g. 'ssh-ed25519
AAAA... you@laptop') OR a file path like ~/.ssh/id_ed25519.pub.
Lets you ssh into the Proxmox host the moment it joins Tailscale." \
    "${CURRENT[OPERATOR_SSH_PUBKEY]:-${HOME}/.ssh/id_ed25519.pub}" plain v_ssh_key
  finalise_ssh_key

  if [[ "${ANSWERS[RANGE_MODE]}" == "minimal" ]]; then
    hdr "Required: monitoring (Splunk only — Elastic skipped in minimal mode)"
  else
    hdr "Required: monitoring (Splunk + Elastic)"
  fi
  ask SPLUNK_ADMIN_PASSWORD "Splunk admin password" \
"Sets the splunk 'admin' account password on the splunk VM." \
    "${CURRENT[SPLUNK_ADMIN_PASSWORD]:-changeme123!}" secret v_strong_pw

  if [[ "${ANSWERS[RANGE_MODE]}" != "minimal" ]]; then
    ask ELASTIC_PASSWORD "Elastic admin password" \
"Sets the 'elastic' superuser + Kibana login on the elastic VM." \
      "${CURRENT[ELASTIC_PASSWORD]:-}" secret v_strong_pw

    ask KIBANA_ENCRYPTION_KEY "Kibana encryption key" \
"32+ char random string used by Kibana to encrypt saved objects and
reporting tokens. Generate one with: openssl rand -hex 32" \
      "${CURRENT[KIBANA_ENCRYPTION_KEY]:-}" secret v_long_key
  fi

  hdr "Optional: WiFi uplink (laptop deployments)"
  ask WIFI_ENABLE "Use WiFi as the uplink?" \
"Set to 'true' if this Proxmox host is a laptop or otherwise needs to
reach the internet over WiFi instead of ethernet.

IMPORTANT: the Proxmox installer itself ALWAYS needs a wired connection
for the initial install (~15 min). After install, first-boot.sh switches
to WiFi automatically. Use a USB-ethernet dongle or a phone USB-tether
for the install phase.

Lab VMs reach the internet via a NAT'd vmbr0 — Proxmox can't L2-bridge
over WiFi STA mode (see https://pve.proxmox.com/wiki/WLAN)." \
    "${CURRENT[WIFI_ENABLE]:-false}" plain v_bool

  if [[ "${ANSWERS[WIFI_ENABLE],,}" =~ ^(true|yes|y)$ ]]; then
    ANSWERS[WIFI_ENABLE]=true

    ask WIFI_SSID "WiFi SSID" \
"Network name. Hidden networks work too (we set scan_ssid=1 if needed)." \
      "${CURRENT[WIFI_SSID]:-}" plain v_ssid

    ask WIFI_PASSWORD "WiFi password (WPA2-PSK)" \
"WPA2 pre-shared key. Edited via wpa_passphrase on first-boot so the
hashed PSK ends up in /etc/wpa_supplicant/* — never the plaintext.
For WPA3-SAE, edit the generated wpa_supplicant config post-deploy." \
      "${CURRENT[WIFI_PASSWORD]:-}" secret v_anything

    ask WIFI_COUNTRY "WiFi regulatory country (2-letter ISO code)" \
"Sets the regdomain. Wrong country can disable channels your AP uses
(e.g. US doesn't allow 2.4 GHz ch 12-13). Defaults to US." \
      "${CURRENT[WIFI_COUNTRY]:-US}" plain v_country

    ask WIFI_INTERFACE "WiFi interface name (optional)" \
"Leave empty to auto-detect via 'iw dev'. Override if your laptop has
multiple radios (e.g. wlp2s0, wlp3s0)." \
      "${CURRENT[WIFI_INTERFACE]:-}" plain v_iface_or_empty

    ask WIFI_DISABLE_WIRED_AFTER_BOOT "Disable wired NIC after WiFi is up?" \
"On laptops where the ethernet was a temporary dongle you plan to
unplug, 'true' is right. 'false' keeps both interfaces up (WiFi
becomes the default route; wired stays as failover)." \
      "${CURRENT[WIFI_DISABLE_WIRED_AFTER_BOOT]:-true}" plain v_bool
  else
    # Normalise so .env always contains a clean value.
    ANSWERS[WIFI_ENABLE]=false
    ANSWERS[WIFI_SSID]="${CURRENT[WIFI_SSID]:-}"
    ANSWERS[WIFI_PASSWORD]="${CURRENT[WIFI_PASSWORD]:-}"
    ANSWERS[WIFI_COUNTRY]="${CURRENT[WIFI_COUNTRY]:-US}"
    ANSWERS[WIFI_INTERFACE]="${CURRENT[WIFI_INTERFACE]:-}"
    ANSWERS[WIFI_DISABLE_WIRED_AFTER_BOOT]="${CURRENT[WIFI_DISABLE_WIRED_AFTER_BOOT]:-true}"
  fi

  hdr "Optional"
  ask NOTIFY_WEBHOOK "Slack / Discord webhook URL (optional)" \
"If set, first-boot.sh POSTs phase-transition messages here while
the range builds itself. Leave empty to skip." \
    "${CURRENT[NOTIFY_WEBHOOK]:-}" plain v_url_or_empty

  ask SIM_INTERVAL_MINUTES "Continuous-sim interval (minutes)" \
"How often the laptop-side 'simulate --loop' fires a technique.
Default 30. Doesn't affect the on-host Atomic Runner schedule." \
    "${CURRENT[SIM_INTERVAL_MINUTES]:-30}" plain v_int_or_empty

  ask SIM_EXCLUDE "Technique IDs to NEVER auto-run" \
"Comma-separated MITRE T-IDs to skip in the random loop. Default
excludes destructive techniques (T1485 etc.)." \
    "${CURRENT[SIM_EXCLUDE]:-T1485,T1486,T1490,T1491,T1561,T1565,T1529,T1499,T1496}" \
    plain v_anything

  ask CALDERA_PASSWORD "CALDERA admin password (optional)" \
"MITRE CALDERA server password on the kali VM. Default 'changeme'
if you skip — easy to change later via the CALDERA UI." \
    "${CURRENT[CALDERA_PASSWORD]:-}" secret v_anything

  ask MALWARE_BAZAAR_API_KEY "abuse.ch MalwareBazaar API key (optional)" \
"Free at https://bazaar.abuse.ch/account/. If set, a curated set of
defused malware samples is pulled to win-client1 at bootstrap.
Leave empty to skip the pull (EICAR / APT Simulator / PurpleSharp
install regardless)." \
    "${CURRENT[MALWARE_BAZAAR_API_KEY]:-}" secret v_anything

  ask SPLUNK_USERS "Extra Splunk users (optional)" \
"Format: user:password:role[,user:password:role]...
Roles: admin | power | user
Example: alice:Wxy!Zzz_16ch:admin,bob:Bbb!Bb_16ch:power
Leave empty if you want only the admin account, or you'll use
ludus/splunk-users.yml instead." \
    "${CURRENT[SPLUNK_USERS]:-}" plain v_anything
}

# ----- write .env ----------------------------------------------------------
write_env() {
  hdr "Writing .env"
  local out="$ENV_FILE"
  # Values the wizard doesn't prompt for but downstream scripts expect.
  declare -A DEFAULTS=(
    [RANGE_MODE]=full
    [ELASTIC_VERSION]=8.15.0
    [MALWARE_ARCHIVE_PASSWORD]=infected
    [SKIP_MALWARE_SAMPLES]=0
    [CALDERA_PASSWORD]=changeme
    [WIFI_ENABLE]=false
    [WIFI_COUNTRY]=US
    [WIFI_DISABLE_WIRED_AFTER_BOOT]=true
  )
  {
    echo "# Generated by scripts/build-iso-wizard.sh on $(date -u +%FT%TZ)"
    echo "# Re-run the wizard to update; values you have set are preserved as defaults."
    echo
    for k in RANGE_MODE RANGE_ID \
             TS_AUTHKEY TS_API_KEY TS_TAG \
             AD_DOMAIN_FQDN AD_DOMAIN_ADMIN AD_PASSWORD \
             LUDUS_ADMIN_PASSWORD OPERATOR_SSH_PUBKEY \
             WIFI_ENABLE WIFI_SSID WIFI_PASSWORD WIFI_COUNTRY WIFI_INTERFACE \
             WIFI_DISABLE_WIRED_AFTER_BOOT \
             SPLUNK_ADMIN_PASSWORD SPLUNK_USERS \
             ELASTIC_PASSWORD KIBANA_ENCRYPTION_KEY ELASTIC_VERSION \
             CALDERA_PASSWORD \
             MALWARE_BAZAAR_API_KEY MALWARE_ARCHIVE_PASSWORD SKIP_MALWARE_SAMPLES \
             NOTIFY_WEBHOOK \
             SIM_EXCLUDE SIM_INTERVAL_MINUTES; do
      v="${ANSWERS[$k]:-${CURRENT[$k]:-${DEFAULTS[$k]:-}}}"
      # Quote values containing spaces or special chars.
      if [[ "$v" =~ [[:space:]\"\'$#] ]]; then
        printf '%s="%s"\n' "$k" "${v//\"/\\\"}"
      else
        printf '%s=%s\n' "$k" "$v"
      fi
    done
  } > "$out"
  chmod 600 "$out"
  ok "wrote $out  (chmod 600)"
}

# ----- build + decode errors ----------------------------------------------
do_build() {
  hdr "Building ISO"
  info "Calling: $BUILD_SCRIPT"
  info "This typically takes 5–15 min (Proxmox ISO is ~1.5 GB on first run)."
  echo

  local log
  log=$(mktemp)
  if "$BUILD_SCRIPT" 2>&1 | tee "$log"; then
    hdr "Done"
    local iso
    iso=$(ls -1t "${REPO_ROOT}/iso/build/"attackrangelocal-*.iso 2>/dev/null | head -1)
    [[ -n "$iso" ]] && ok "ISO: $iso  ($(du -h "$iso" | cut -f1))"
    note "Flash with:  sudo dd if=$iso of=/dev/sdX bs=4M status=progress conv=fsync"
    note "Then boot the target Proxmox host from that USB. The install is"
    note "fully unattended; you'll be able to ssh root@ludus-host.<tailnet>"
    note "within ~5 min via Tailscale, and the full range will be up in ~3 h."
    rm -f "$log"
    return 0
  fi

  # Build failed -- try to decode the most common errors.
  hdr "Build failed — diagnosis"
  if grep -q 'proxmox-auto-install-assistant: command not found' "$log"; then
    err "proxmox-auto-install-assistant is missing."
    note "Install per the pre-flight instructions above."
  elif grep -qi 'Could not resolve host: enterprise.proxmox.com' "$log"; then
    err "DNS / network unable to reach enterprise.proxmox.com."
    note "Check internet connectivity. Behind a proxy? Set HTTPS_PROXY before re-running."
  elif grep -qi 'No space left on device' "$log"; then
    err "Disk filled up during build."
    note "Free up space (rm iso/cache/proxmox-ve_*.iso to drop the cache) and retry."
  elif grep -qiE 'curl: \(22\).*404|HTTP/[0-9.]+ 404' "$log"; then
    err "Proxmox ISO URL returned 404."
    note "The release this build script pins may have been retired. Check"
    note "  http://enterprise.proxmox.com/iso/   for the current filename, then"
    note "  PROXMOX_ISO_URL=https://enterprise.proxmox.com/iso/proxmox-ve_X.Y-1.iso \\"
    note "    ./scripts/build-iso-wizard.sh --build-only"
  elif grep -qiE 'curl: \(2[28]\)|Failed to connect' "$log"; then
    err "Network connection died mid-download."
    note "Retry; the cached ISO under iso/cache/ resumes correctly."
  elif grep -qi 'validate-answer' "$log"; then
    err "answer.toml failed Proxmox validation."
    note "Look at iso/build/answer.toml; common causes: weird characters in"
    note "root_password, malformed root_ssh_keys, or a typo in [disk-setup]."
  elif grep -qi 'Required env var' "$log"; then
    err "A required env var was empty when build-iso.sh ran."
    note "Re-run the wizard — one of the required prompts may have been skipped."
  elif grep -qi 'mkisofs\|xorriso' "$log"; then
    err "ISO generation tool failed."
    note "Make sure xorriso (or genisoimage) is installed:  apt install xorriso"
  elif grep -qiE 'rsync: command not found|rsync:.*not installed' "$log"; then
    err "rsync is not installed."
    note "Install with:  apt install rsync"
  elif grep -qiE '(envsubst|gettext): (command not found|not installed)' "$log"; then
    err "envsubst is not installed."
    note "Install with:  apt install gettext-base"
  else
    err "Unrecognised failure. Last 30 log lines:"
    tail -30 "$log" | sed 's/^/  /'
  fi
  echo
  note "Full log: $log"
  return 1
}

# ----- main ----------------------------------------------------------------
banner() {
  cat <<'EOF'

   __ __  ___ _____  ____ _      _____  ___   _   _   ___ ___ _    ___   __  __ _    _
  /_\\_\\/ _ \_   _||  _ \ \    / / _ \/ _ \ | \ | | / __|_ _| |  / _ \ |  \/  | |  | |
 / _ \ _|    / | |  | | |/ /\ \/ / (_) |   /|  \| || (__ | || |_| (_) || |\/| | |__| |
/_/ \_\__\_/  |_|  |_| |_/  \/\/ \___/|___/ |_|\_| \___|___|____\___/ |_|  |_|____|___|

EOF
  info "${BOLD}attackrangelocal — unattended ISO build wizard${RST}"
  info "Repo: ${REPO_ROOT}"
}

banner
preflight
case "$MODE" in
  build-only)
    [[ -f "$ENV_FILE" ]] || { err "no .env — run without --build-only first"; exit 1; }
    # Top up any DEFAULTS values that may be missing in an older .env.
    # (Cheap to do; never overwrites set values because write_env()
    # reads CURRENT first.)
    write_env
    do_build
    ;;
  dry-run)
    collect
    write_env
    info "Skipping build (--dry-run). Run again without --dry-run to build."
    ;;
  interactive)
    collect
    write_env
    echo
    printf "${BOLD}Build the ISO now? [Y/n]${RST} "
    read -r yn
    case "${yn:-y}" in
      [Nn]*) info "Skipping build. Run '$0 --build-only' when ready." ;;
      *) do_build ;;
    esac
    ;;
esac
