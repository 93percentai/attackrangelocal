# Unattended ISO pipeline

A single bootable USB takes a bare-metal x86_64 box from **factory** to
**fully-deployed range + continuous attacks running** with zero operator
interaction after power-on.

## How it works

Three stages baked into one ISO:

### Stage A — Proxmox auto-install

Proxmox VE ships an [auto-installer](https://pve.proxmox.com/wiki/Automated_Installation)
(we pin **PVE 9.2-1**; the pipeline is validated on 8.4 and 9.2)
that consumes a TOML answer file (`iso/answer.toml.j2`, rendered from your
`.env` at build time) and a custom first-boot script. `iso/build-iso.sh`
wraps the official `proxmox-auto-install-assistant` tool to bake both into
the official Proxmox ISO.

### Stage B — First-boot bootstrap

`iso/build-iso.sh` generates a wrapper around `iso/first-boot.sh` that
embeds your `secrets.env` (~1 KB, base64) plus a `REPO_URL`/`REPO_REF` pin,
and PAI bakes that wrapper onto the ISO. A systemd oneshot unit runs it
**once** after install. Phases, in order:

| # | Phase | What |
|---|---|---|
| 1 | `wait-for-network` | ping until the uplink is live |
| 2 | `install-git` | `apt-get install git` (not in the PVE base image) |
| 3 | `clone-repo` | `git clone` this repo at the pinned `REPO_REF`, drop in `.env` |
| 4 | `install-tailscale-on-host` | join the tailnet → you can SSH in from ~minute 3 |
| 5 | `install-ludus` | `scripts/bootstrap-ludus.sh` |
| 6 | `install-roles-and-templates` | Galaxy roles + Ludus template build (~60–90 min, the long pole) |
| 7 | `deploy-range` | `scripts/deploy-range.sh` — 5 or 7 VMs depending on `RANGE_MODE` (~45 min) |
| 8 | `install-monitoring` | Splunk users, plus Elastic stack + agents when `RANGE_MODE=full` |
| 9 | `install-extended-attacks` | APT Simulator, PurpleSharp, CALDERA, EICAR, optional defused samples |
| 10 | `lock-down-egress` | strip every `bootstrap-*` rule — only Tailscale ports survive |
| 11 | `start-continuous-simulation` | Atomic Runner service on win-client1 |
| 12 | `range-up-continuous-sim-running` | done; unit disables itself |

The repo is **git-cloned at first boot**, not shipped in the ISO: PAI caps
the first-boot executable at 1 MiB, which the repo far exceeds. Pinning
`REPO_REF` to the build-time commit keeps deploys reproducible.

If phase 8 or 9 fails, first-boot **halts before lockdown** (phase
`abort-before-lockdown`) rather than cutting egress on a half-built lab —
it prints the exact commands to finish by hand over SSH.

### Stage C — Operator visibility

- **Tailscale on host**: `ssh root@ludus-attackrangelocal.<tailnet>` from minute ~3
- **Status file**: `cat /var/lib/ludus-bootstrap/status` shows the current
  phase (see the table above for the full sequence)
- **Logs**: `journalctl -u proxmox-firstboot -f` or
  `tail -f /var/log/attackrangelocal-firstboot.log`
- **Optional webhook**: set `NOTIFY_WEBHOOK=...` in `.env` to get a Slack
  or Discord ping on every phase transition

Total wall-clock time from USB-insertion to "Splunk reachable + continuous
attacks firing": **~3 hours** on a 32 GB host.

## Build the ISO

```bash
# On your laptop (Debian/Ubuntu recommended).
# PAI must match the Proxmox major version you build:
#   PVE 9.x -> trixie repo     PVE 8.x -> bookworm repo
curl -fsSLo /tmp/paia.deb \
  http://download.proxmox.com/debian/pve/dists/trixie/pve-no-subscription/binary-amd64/proxmox-auto-install-assistant_9.2.8_amd64.deb
sudo apt install -y /tmp/paia.deb gettext-base

cp ludus/.env.example .env
$EDITOR .env                # fill in every REPLACE_ME
./iso/build-iso.sh

# Or just run the wizard, which does all of the above interactively:
./scripts/build-iso-wizard.sh
# -> iso/build/attackrangelocal-<RANGE_ID>-<DATE>.iso
```

## Flash to USB

```bash
sudo dd if=iso/build/attackrangelocal-*.iso \
        of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with your USB stick's actual device. Triple-check with
`lsblk` — `dd` will happily wipe the wrong disk.

## Boot the target

1. Insert USB, boot
2. ~15 min: Proxmox is installed, machine reboots automatically
3. ~3 min after reboot: Proxmox host joins Tailscale → `ssh root@ludus-attackrangelocal.<tailnet>` works
4. ~90 min later: templates built
5. ~45 min later: range up, lab VMs reachable via Tailscale
6. Immediately after: `lock-down.sh` runs → no more egress
7. Atomic Runner service registered on `win-client1` → fires forever

## Re-running

The first-boot service disables itself on success. To re-run the whole
pipeline (e.g. if Proxmox installed fine but Ludus deploy failed), on the
host:

```bash
systemctl enable proxmox-firstboot.service
systemctl start  proxmox-firstboot.service
```

To do *just* a range redeploy (skipping Proxmox/Ludus install):

```bash
ssh root@ludus-attackrangelocal.<tailnet>
cd /opt/attackrangelocal
scripts/deploy-range.sh
```

## Security notes

- **secrets.env is baked into the ISO unencrypted.** Treat the ISO file
  like a secret. Destroy it after the install completes.
- The Proxmox root password from `.env` is the root password on the
  installed system — choose a strong one and rotate it after install.
- The Tailscale auth key should be reusable but with **short expiry**
  (24 h is fine — the VMs only need it during one bootstrap). The API key
  needs device-removal scope so teardown is clean.
