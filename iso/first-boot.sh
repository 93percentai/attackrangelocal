#!/usr/bin/env bash
# Runs ONCE on the freshly-installed Proxmox host. Drives the rest of the
# pipeline (Tailscale, Ludus, role install, template build, range deploy,
# lockdown, continuous simulation) without any operator interaction.
#
# Triggered by the [first-boot] stanza in answer.toml. The Proxmox auto-
# installer copies this file to /var/lib/proxmox-firstboot and registers a
# systemd oneshot unit that calls it after network is up.
#
# Logs to /var/log/attackrangelocal-firstboot.log (also visible via
# `journalctl -u proxmox-firstboot`).
set -euo pipefail
exec > >(tee -a /var/log/attackrangelocal-firstboot.log) 2>&1

PAYLOAD_TAR=/var/lib/proxmox-firstboot/attackrangelocal-payload.tar.gz
PAYLOAD_DIR=/opt/attackrangelocal
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

phase wait-for-network
until ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; do sleep 2; done

phase extract-payload
mkdir -p "$PAYLOAD_DIR"
tar -xzf "$PAYLOAD_TAR" -C "$PAYLOAD_DIR"

# secrets.env was rendered into the payload by build-iso.sh.
if [[ -f "$PAYLOAD_DIR/iso/payload/secrets.env" ]]; then
  set -a; source "$PAYLOAD_DIR/iso/payload/secrets.env"; set +a
fi
# Also make .env available at repo root so deploy-range.sh works.
cp "$PAYLOAD_DIR/iso/payload/secrets.env" "$PAYLOAD_DIR/.env"

phase install-tailscale-on-host
# Operator can immediately ssh root@<host> via Tailscale once this finishes.
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up --authkey="${TS_AUTHKEY}" --hostname="ludus-host" \
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
bash "$PAYLOAD_DIR/scripts/install-monitoring.sh" || \
  echo "WARN: monitoring install failed (range still up, continue)"

phase install-extended-attacks
# Pull APT Simulator, PurpleSharp, EICAR, CALDERA + (optionally) defused
# samples from abuse.ch. Runs BEFORE lockdown so external pulls still work.
bash "$PAYLOAD_DIR/scripts/install-extended-attacks.sh" || \
  echo "WARN: extended attacks install failed (range still up, continue)"

phase lock-down-egress
bash "$PAYLOAD_DIR/scripts/lock-down.sh"

phase start-continuous-simulation
# Use --windows so the loop is hosted on win-client1 itself (not the Proxmox
# host's docker, which we don't run here). Atomic Runner survives reboots.
bash "$PAYLOAD_DIR/scripts/start-continuous-sim.sh" --windows || true

phase range-up-continuous-sim-running
echo "Range is fully up. Access Splunk at https://<RANGE_ID>-splunk:8000 over Tailscale."

# Disable ourselves so we don't run again on the next boot.
systemctl disable proxmox-firstboot.service || true
