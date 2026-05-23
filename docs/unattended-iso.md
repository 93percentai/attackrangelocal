# Unattended ISO pipeline

A single bootable USB takes a bare-metal x86_64 box from **factory** to
**fully-deployed range + continuous attacks running** with zero operator
interaction after power-on.

## How it works

Three stages baked into one ISO:

### Stage A — Proxmox auto-install

Proxmox VE 8.2+ ships an [auto-installer](https://pve.proxmox.com/wiki/Automated_Installation)
that consumes a TOML answer file (`iso/answer.toml.j2`, rendered from your
`.env` at build time) and a custom first-boot script. `iso/build-iso.sh`
wraps the official `proxmox-auto-install-assistant` tool to bake both into
the official Proxmox ISO.

### Stage B — First-boot bootstrap

`iso/first-boot.sh` is copied onto the installed system and run **once** by
a systemd oneshot unit Proxmox's installer registers. It:

1. Waits for the network
2. Extracts the payload tarball (this whole repo + your secrets.env)
3. Installs Tailscale on the Proxmox host itself and joins your tailnet
   → you can `ssh root@ludus-host.<tailnet>` from minute ~3 to watch
4. Runs `scripts/bootstrap-ludus.sh` (Ludus install)
5. Runs `scripts/install-roles.sh` (Galaxy roles + Ludus template build,
   ~60–90 min — the long pole)
6. Runs `scripts/deploy-range.sh` (Ludus deploys all 6 VMs, ~45 min)
7. Runs `scripts/lock-down.sh` (strips bootstrap egress rules — no more
   internet from lab VMs)
8. Runs `scripts/start-continuous-sim.sh --windows` (Atomic Runner service
   on win-client1)
9. Disables itself so it never re-runs

### Stage C — Operator visibility

- **Tailscale on host**: `ssh root@ludus-host.<tailnet>` from minute ~3
- **Status file**: `cat /var/lib/ludus-bootstrap/status` shows the current
  phase: `wait-for-network`, `install-tailscale-on-host`, `install-ludus`,
  `install-roles-and-templates`, `deploy-range`, `lock-down-egress`,
  `start-continuous-simulation`, `range-up-continuous-sim-running`
- **Logs**: `journalctl -u proxmox-firstboot -f` or
  `tail -f /var/log/attackrangelocal-firstboot.log`
- **Optional webhook**: set `NOTIFY_WEBHOOK=...` in `.env` to get a Slack
  or Discord ping on every phase transition

Total wall-clock time from USB-insertion to "Splunk reachable + continuous
attacks firing": **~3 hours** on a 64 GB host.

## Build the ISO

```bash
# On your laptop (Debian/Ubuntu recommended)
sudo apt install proxmox-auto-install-assistant gettext-base
cp ludus/.env.example .env
$EDITOR .env                # fill in every REPLACE_ME
./iso/build-iso.sh
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
3. ~3 min after reboot: Proxmox host joins Tailscale → `ssh root@ludus-host.<tailnet>` works
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
ssh root@ludus-host.<tailnet>
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
