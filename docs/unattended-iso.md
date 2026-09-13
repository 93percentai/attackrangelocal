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
(default **PVE 9.2-1**, set by `PROXMOX_VERSION`; validated on 8.4 and 9.2 —
see [PXE booting](#pxe-booting) if you netboot)
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

PXE works, but the memory maths is completely different from USB, and the
failure mode when you run out is actively misleading.

iPXE hands the kernel **two** initrds:

```
kernel  .../linux26 initrd=initrd.img ramdisk_size=... proxmox-start-auto-installer
initrd  .../initrd.img
initrd  .../<the ISO> proxmox.iso      <- the whole ISO becomes /proxmox.iso
```

The installer's `init` checks `/proxmox.iso` first and only scans block
devices if it is absent, so on PXE the entire ISO must be unpacked into the
initramfs, in RAM, before anything runs. USB boot never pays this — the ISO
stays on the stick, and 4 GB is plenty.

Measured by PXE-booting the same VM at the same memory size:

| ISO served | initrd (unpacked) | ISO | initramfs | @4 GB | @5 GB | @5.5 GB | @6 GB |
|---|---:|---:|---:|---|---|---|---|
| 8.4-1 | 202 MiB | 1.46 GiB | 1.66 GiB | fails | fails | **boots** | boots |
| 9.2-1 | 344 MiB | 1.59 GiB | 1.93 GiB | fails | fails | **fails** | boots |
| 9.2-1, `/boot` stripped | 344 MiB | 1.50 GiB | 1.83 GiB | — | — | **boots** | — |

Rule of thumb from those points: you need roughly **3× the initramfs size**
in client RAM. ~6 GB for a stock 9.2 ISO, ~5 GB for 8.4.

### Fixing this in the PXE server

The third row is the fix, and it belongs in the PXE server rather than here.
On PXE the kernel and initrd are served as their own files, so the copies
inside the ISO's `/boot` (`linux26` 16 MiB + `initrd.img` 56 MiB, 92 MiB of
ISO once filesystem overhead is counted) are pure duplication — downloaded,
held in RAM by iPXE, and unpacked into the initramfs for nothing.

Strip them from the copy you serve as `proxmox.iso`:

```bash
xorriso -indev proxmox-ve_9.2-1.iso -outdev pxe-proxmox.iso \
        -boot_image any keep -rm_r /boot -- -commit
```

That alone booted 9.2 at the memory where the stock ISO failed. Do it to the
*served* copy only — this repo's ISO keeps `/boot` because it must also boot
from USB.

Two things not worth doing: compressing the ISO (it is ~97% squashfs and
`.deb`s already, so zstd buys 2%), and serving it as a network block device
(the installer initrd ships `iscsi_tcp.ko` and `nbd.ko` but no userspace
initiator — its own comment says "we have no iscsi daemon").

If you cannot change the PXE server, set `PROXMOX_VERSION=8.4-1` in `.env`.

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
installation medium". **Your media is fine** — no device was ever scanned,
because scanning only happens in the `else` branch.
