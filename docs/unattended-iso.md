# Unattended ISO pipeline

> New to the ISO tool? Start with [`docs/iso-quick-start.md`](iso-quick-start.md)
> for where to get every config value and the hardware specs required per
> `RANGE_MODE`. This doc covers what happens under the hood once you build
> and boot the ISO.

A single bootable USB takes a bare-metal x86_64 box from **factory** to
**fully-deployed range + continuous attacks running** with zero operator
interaction after power-on.

## How it works

Three stages baked into one ISO:

### Stage A — Proxmox auto-install

Proxmox VE ships an [auto-installer](https://pve.proxmox.com/wiki/Automated_Installation)
(default **PVE 8.4-1**, set by `PROXMOX_VERSION`; validated on 8.4 and 9.2 —
see [PXE booting](#pxe-booting) before choosing 9.x)
that consumes a TOML answer file (`iso/answer.toml.j2`, rendered from your
`.env` at build time) and a custom first-boot script. `iso/build-iso.sh`
wraps the official `proxmox-auto-install-assistant` tool to bake both into
the official Proxmox ISO.

### Stage B — First-boot bootstrap

`iso/build-iso.sh` generates a wrapper around `iso/first-boot.sh` that embeds
your `secrets.env` (~1 KB) **and the whole repo** (~150 KB gzipped, ~200 KB
base64'd — about 20% of PAI's 1 MiB first-boot limit), and PAI bakes that
wrapper onto the ISO. A systemd oneshot unit runs it **once** after install.
Phases, in order:

| # | Phase | What |
|---|---|---|
| 1 | `unpack-repo` | untar the embedded repo to `/opt/attackrangelocal`, drop in `.env` |
| 2 | `wait-for-network` | ping until the uplink is live |
| 3 | `install-git` | `apt-get install git vim` — for ansible-galaxy and the Ludus installer |
| 4 | `install-tailscale-on-host` | join the tailnet → you can SSH in from ~minute 3 |
| 5 | `install-ludus` | `scripts/bootstrap-ludus.sh` |
| 6 | `install-roles-and-templates` | Galaxy roles + Ludus template build (~60–90 min, the long pole) |
| 7 | `deploy-range` | `scripts/deploy-range.sh` — 5 or 7 VMs depending on `RANGE_MODE` (~45 min) |
| 8 | `install-monitoring` | Splunk users, plus Elastic stack + agents when `RANGE_MODE=full` |
| 9 | `install-extended-attacks` | APT Simulator, PurpleSharp, CALDERA, EICAR, optional defused samples |
| 10 | `lock-down-egress` | strip every `bootstrap-*` rule — only Tailscale ports survive |
| 11 | `start-continuous-simulation` | Atomic Runner service on win-client1 |
| 12 | `range-up-continuous-sim-running` | done; unit disables itself |

The repo ships **inside the ISO**, not cloned at boot. That means:

- the code that runs is byte-for-byte the code you built the ISO from —
  there is no ref to pin, push, or verify, and no window in which someone
  else's push changes what your USB deploys
- uncommitted edits in your working tree ship too. `build-iso.sh` tars the
  working tree deliberately: if you changed a script and built an ISO from
  it, you meant to deploy that change. It prints whether the tree was dirty
  and records it in `/opt/attackrangelocal/.build-info`
- `unpack-repo` runs **before** `wait-for-network`, so
  `scripts/diagnose-firstboot.sh` is on disk even if the uplink never comes
  up and every later phase fails
- the build verifies the payload before baking: the tarball must survive the
  base64 round-trip byte-for-byte, untar cleanly, and still contain the six
  scripts first-boot calls, with their executable bits intact

Internet is still required *after* this point — Tailscale, Ludus, the Galaxy
roles and the Windows templates are all fetched during bootstrap. Embedding
the repo only removes the clone.

If phase 8 or 9 fails, first-boot **halts before lockdown** (phase
`abort-before-lockdown`) rather than cutting egress on a half-built lab —
it prints the exact commands to finish by hand over SSH.

### Stage C — Operator visibility

- **Tailscale on host**: `ssh root@ludus-attackrangelocal.<tailnet>` from minute ~3
- **Status file**: `cat /var/lib/ludus-bootstrap/status` shows the current
  phase (see the table above for the full sequence)
- **Logs**: `journalctl -u proxmox-first-boot -f` or
  `tail -f /var/log/attackrangelocal-firstboot.log`
- **Optional webhook**: set `NOTIFY_WEBHOOK=...` in `.env` to get a Slack
  or Discord ping on every phase transition

Total wall-clock time from USB-insertion to "Splunk reachable + continuous
attacks firing": **~3 hours** on a 32 GB host.

## Build the ISO

```bash
# On your laptop (Debian/Ubuntu recommended).
sudo apt install -y gettext-base
sudo scripts/install-pai.sh

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
systemctl enable proxmox-first-boot.service
systemctl start  proxmox-first-boot.service
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

## PXE booting

PXE is supported, but it changes the memory maths completely, because iPXE
hands the kernel **two** initrds:

```
kernel  .../linux26 initrd=initrd.img ramdisk_size=... proxmox-start-auto-installer
initrd  .../initrd.img
initrd  .../<the ISO> proxmox.iso      <- the whole ISO becomes /proxmox.iso
```

The installer's `init` looks for `/proxmox.iso` first and only scans block
devices if it is absent. So on PXE the entire ISO has to be unpacked into
the initramfs, in RAM, before anything runs. Booting from USB does not pay
this — the ISO stays on the stick.

Measured by PXE-booting the same VM at the same RAM:

| Proxmox | initrd (unpacked) | ISO | initramfs | PXE @ 4 GB | @ 5.5 GB | @ 6 GB |
|---|---:|---:|---:|---|---|---|
| 8.4-1 | 202 MiB | 1.46 GiB | **1.66 GiB** | fails | **boots** | boots |
| 9.2-1 | 344 MiB | 1.59 GiB | **1.93 GiB** | fails | **fails** | boots |

That ~270 MiB of extra initramfs is why `PROXMOX_VERSION` defaults to
**8.4-1**. Set `PROXMOX_VERSION=9.2-1` if you boot from USB, or if your PXE
target has 8 GB or more.

### "no device with valid ISO found" on PXE

The give-away is the line *above* it, which scrolls past easily:

```
[    2.344025] Initramfs unpacking failed: write error
...
found proxmox ISO image inside initrd image
[ERROR] no device with valid ISO found, please check your installation medium
```

Read it bottom-up. The unpack ran out of memory, so `/proxmox.iso` is
truncated; the installer still takes its PXE branch because the path exists,
fails to loop-mount it, and then reports the generic "check your
installation medium". **Your media is fine** — the installer never scanned
any device, because that only happens in the `else` branch.

Fixes, in order of preference: give the target more RAM; set
`PROXMOX_VERSION=8.4-1` (smaller by ~270 MiB of initramfs); or boot from USB
instead, which needs about 4 GB.
