#!/usr/bin/env bash
# Runs ONCE on the freshly-installed Proxmox host. Drives the rest of the
# pipeline (Tailscale, Ludus, role install, template build, range deploy,
# lockdown, continuous simulation) without any operator interaction.
#
# Triggered by the [first-boot] stanza in answer.toml. The Proxmox auto-
# installer copies this file into the installed system and registers a
# systemd oneshot unit that calls it after network is up.
#
# IMPORTANT: this file is a TEMPLATE. iso/build-iso.sh generates the real
# script (first-boot-wrapped.sh) by prepending:
#   - An embedded `secrets.env` (your .env contents)
#   - An embedded `repo.tar.gz` (this whole repo, base64'd)
#   - A `build-info` provenance stamp
# and then inlining the rest of THIS file. All of it fits inside PAI's 1 MiB
# first-boot limit (~20% of it), so the target box never clones anything:
# the code that runs is byte-for-byte the code the ISO was built from, and
# first-boot works even if the host cannot reach GitHub.
#
# Logs to /var/log/attackrangelocal-firstboot.log (also visible via
# `journalctl -u proxmox-first-boot`).
set -euo pipefail
exec > >(tee -a /var/log/attackrangelocal-firstboot.log) 2>&1

PAYLOAD_DIR=/opt/attackrangelocal
SECRETS_FILE=/var/lib/proxmox-firstboot/secrets.env
STATUS_FILE=/var/lib/ludus-bootstrap/status

mkdir -p "$(dirname "$STATUS_FILE")"
echo "first-boot-started" > "$STATUS_FILE"

phase() {
  echo "[$(date -u +%FT%TZ)] === $1 ==="
  echo "$1" > "$STATUS_FILE"
  if [[ -n "${NOTIFY_WEBHOOK:-}" ]]; then
    curl -fsS -X POST -H 'content-type: application/json' \
      -d "{\"text\":\"[attackrangelocal] phase: $1\"}" \
      "${NOTIFY_WEBHOOK}" >/dev/null 2>&1 || true
  fi
}

phase unpack-repo
# The repo was baked into this script by iso/build-iso.sh -- no clone, so
# this works before the network is up. Doing it first means the diagnostic
# tooling (scripts/diagnose-firstboot.sh) is on disk even if every later
# phase fails.
REPO_TGZ=/var/lib/proxmox-firstboot/repo.tar.gz
if [[ ! -f "$REPO_TGZ" ]]; then
  echo "FATAL: $REPO_TGZ missing — the first-boot wrapper was not generated" >&2
  echo "       by iso/build-iso.sh, or was truncated." >&2
  exit 1
fi
rm -rf "$PAYLOAD_DIR"
mkdir -p "$PAYLOAD_DIR"
tar -xzf "$REPO_TGZ" -C "$PAYLOAD_DIR"
if [[ ! -x "$PAYLOAD_DIR/scripts/bootstrap-ludus.sh" ]]; then
  echo "FATAL: payload unpacked but scripts/bootstrap-ludus.sh is missing or" >&2
  echo "       not executable — refusing to continue on a broken payload." >&2
  exit 1
fi
cp -f /var/lib/proxmox-firstboot/build-info "$PAYLOAD_DIR/.build-info" 2>/dev/null || true
echo "Unpacked $(tar -tzf "$REPO_TGZ" | wc -l) files to $PAYLOAD_DIR"

# secrets.env was written by the wrapper before this script's main body ran.
# Source it for the rest of the phases, and drop it into the payload as .env
# so deploy-range.sh / install-monitoring.sh find it.
if [[ -f "$SECRETS_FILE" ]]; then
  set -a; source "$SECRETS_FILE"; set +a
  install -m 600 "$SECRETS_FILE" "$PAYLOAD_DIR/.env"
fi

phase wait-for-network
until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do sleep 2; done

# Fresh PVE installs default to enterprise.proxmox.com apt repos, which 401
# without a subscription. first-boot needs working apt before git/Ludus/etc.
ensure_pve_apt_no_subscription() {
  local f
  for f in /etc/apt/sources.list.d/pve-enterprise.list \
           /etc/apt/sources.list.d/ceph.list; do
    if [[ -f "$f" ]] && grep -qE '^[[:space:]]*deb[[:space:]]' "$f"; then
      sed -i.bak-attackrange 's/^[[:space:]]*deb /# deb /' "$f"
      echo "Disabled enterprise repo: $f"
    fi
  done
  if [[ ! -f /etc/apt/sources.list.d/pve-no-subscription.list ]]; then
    cat >/etc/apt/sources.list.d/pve-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription
EOF
    echo "Added pve-no-subscription apt source"
  fi
  if [[ ! -f /etc/apt/sources.list.d/ceph-no-subscription.list ]]; then
    cat >/etc/apt/sources.list.d/ceph-no-subscription.list <<'EOF'
deb http://download.proxmox.com/debian/ceph-quincy bookworm no-subscription
EOF
    echo "Added ceph no-subscription apt source"
  fi
}
ensure_pve_apt_no_subscription

phase install-git
# Not needed for the payload any more (it is embedded), but ansible-galaxy
# and the Ludus installer both shell out to git, and vim is a courtesy for
# whoever SSHes in to debug.
apt-get update -qq
apt-get install -y --no-install-recommends git vim >/dev/null

phase install-tailscale-on-host
# Operator can immediately ssh root@<host> via Tailscale once this finishes.
# The Tailscale hostname is the short name from PROXMOX_FQDN so MagicDNS
# resolves `ssh root@ludus-attackrangelocal` cleanly.
TS_HOSTNAME="${PROXMOX_FQDN%%.*}"
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey="${TS_AUTHKEY}" --hostname="${TS_HOSTNAME}" \
             --advertise-tags="${TS_TAG}" --ssh

phase install-ludus
bash "$PAYLOAD_DIR/scripts/bootstrap-ludus.sh"

phase install-roles-and-templates
bash "$PAYLOAD_DIR/scripts/install-roles.sh"

phase deploy-range
bash "$PAYLOAD_DIR/scripts/deploy-range.sh"

phase install-monitoring
# Bring up Elastic stack on `elastic` VM, enroll Elastic Agents on every
# Win/Linux host, apply extra Splunk users. Egress still open for image pulls.
# If this fails we DO NOT proceed to lockdown — running lock-down.sh after
# a half-installed monitoring stack would leave a lab with no telemetry and
# no path to repair (egress cut). Halt loudly instead.
MONITORING_OK=true
bash "$PAYLOAD_DIR/scripts/install-monitoring.sh" || {
  MONITORING_OK=false
  echo "ERROR: monitoring install failed. See above for details."
}

phase install-extended-attacks
# Pull APT Simulator, PurpleSharp, EICAR, CALDERA + (optionally) defused
# samples from abuse.ch. Runs BEFORE lockdown so external pulls still work.
EXTENDED_OK=true
bash "$PAYLOAD_DIR/scripts/install-extended-attacks.sh" || {
  EXTENDED_OK=false
  echo "ERROR: extended attacks install failed. See above for details."
}

if [[ "$MONITORING_OK" != "true" || "$EXTENDED_OK" != "true" ]]; then
  phase abort-before-lockdown
  echo "Halting BEFORE lockdown so you can ssh in and fix the failed step."
  echo "  ssh root@${PROXMOX_FQDN%%.*}.<tailnet>"
  echo "  cd /opt/attackrangelocal"
  echo "  scripts/install-monitoring.sh        # re-run as needed"
  echo "  scripts/install-extended-attacks.sh"
  echo "  scripts/lock-down.sh                 # only after the above succeed"
  echo "  scripts/start-continuous-sim.sh --windows"
  exit 1
fi

phase lock-down-egress
bash "$PAYLOAD_DIR/scripts/lock-down.sh"

phase start-continuous-simulation
# Use --windows so the loop is hosted on win-client1 itself (not the Proxmox
# host's docker, which we don't run here). Atomic Runner survives reboots.
bash "$PAYLOAD_DIR/scripts/start-continuous-sim.sh" --windows || true

phase range-up-continuous-sim-running
echo "Range is fully up. Access Splunk at https://<RANGE_ID>-splunk:8000 over Tailscale."

# Disable ourselves so we don't run again on the next boot.
systemctl disable proxmox-first-boot.service || true
