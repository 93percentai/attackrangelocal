# ISO build tool — quick start

This is the fast path from a clean laptop to a flashable
`attackrangelocal-<RANGE_ID>-<DATE>.iso`. It covers:

1. What your **build laptop** and **target box** need
2. Exactly **where to get** every piece of information the tool asks for
3. The **spec/format** each config value must satisfy, per `RANGE_MODE`
4. How to actually **run the tool** (wizard or manual)

For the full phase-by-phase explanation of what happens after you boot the
ISO, see [`docs/unattended-iso.md`](unattended-iso.md). This doc is only
about getting the ISO built correctly on the first try.

## The tool, in one picture

```
scripts/build-iso-wizard.sh   (recommended — interactive, validates as you type)
        │
        ├─ prompts you for every value below, writes .env (chmod 600)
        └─ calls ↓
iso/build-iso.sh               (the actual builder — also runnable standalone)
        │
        ├─ validates .env (fails fast if anything required is missing)
        ├─ renders iso/answer.toml.j2 → build/answer.toml  (Proxmox auto-install answer file)
        ├─ bakes .env → build/payload/secrets.env           (baked into the ISO, unencrypted)
        ├─ downloads + caches the Proxmox VE ISO
        ├─ wraps iso/first-boot.sh into a first-boot script (must stay < 1 MiB)
        └─ runs `proxmox-auto-install-assistant prepare-iso` → build/attackrangelocal-*.iso
```

Use the wizard unless you're scripting a repeatable build (e.g. CI) —
`iso/build-iso.sh` alone assumes `.env` is already complete and correct.

## 1. Build-laptop requirements

| Requirement | Detail |
|---|---|
| OS | Debian/Ubuntu recommended (Fedora/RHEL/Arch work — see package substitutions in the [README](../README.md#quick-start)). macOS is **not** supported (needs Linux `xorriso` + `dd`) — use a Linux VM or WSL2. |
| Disk space | ≥ 4 GB free (Proxmox ISO ~1.5 GB cached + build output ~1.5 GB + payload) |
| Network | Reachable `enterprise.proxmox.com` (ISO download) and `deb.debian.org` (only if `WIFI_ENABLE=true`, for firmware blobs) |
| Tools | `proxmox-auto-install-assistant`, `envsubst` (gettext-base), `curl`, `tar`, `rsync`, `xorriso`, `sha256sum`, `openssl` |

The wizard's pre-flight check (`scripts/build-iso-wizard.sh`) verifies all of
this for you and prints the exact install command for anything missing —
you don't need to check it by hand.

## 2. Target-box hardware specs (pick your `RANGE_MODE` first)

Everything else you configure depends on which topology you're deploying, so
decide this before you start collecting values.

| `RANGE_MODE` | RAM | Threads | SSD | VMs | SIEMs |
|---|---:|---:|---:|---|---|
| `minimal` | **16 GB** | **12** | **256 GB** | 5: `dc01` (DC+member combined), `winclient1`, `splunk`, `linux`, `kali` | Splunk only |
| `full` (default) | **30 GB** | **16** | **500 GB** | 7: `dc01`, `winclient1`, `winsrv1`, `splunk`, `elastic`, `linux`, `kali` | Splunk **and** Elastic |

Both modes additionally require:

- **x86_64** CPU, PassMark score > 6,000
- **Wired ethernet** for the ~15-minute Proxmox install phase, even if you
  plan to run on WiFi afterward (see [optional values](#optional-values) below)
- A target disk the installer can wipe entirely — see `DISK_DEVICE_LIST`
  below for how to identify it

Full per-VM RAM/vCPU breakdowns: [`docs/minimal-mode.md`](minimal-mode.md)
(minimal) and the [README hardware table](../README.md#hardware) (full).

Changing `RANGE_MODE` after a range is deployed requires a teardown +
redeploy — see the "Switching between modes" section of
[`docs/minimal-mode.md`](minimal-mode.md).

## 3. Getting the info you'll be asked for

Collect these *before* running the wizard so you're not context-switching
mid-run. Grouped in the same order the wizard asks for them.

### Required — range identity

| Value | Spec | Where to get it |
|---|---|---|
| `RANGE_MODE` | `full` or `minimal` | Your choice — see the hardware table above |
| `RANGE_ID` | Integer `1`–`255` | Pick anything unused on your tailnet/subnet. Becomes the second octet of `10.<RANGE_ID>.20.0/24` and prefixes every VM name. Default `42`. |

### Required — Tailscale

| Value | Spec | Where to get it |
|---|---|---|
| `TS_AUTHKEY` | Starts with `tskey-auth-` | Tailscale Admin Console → **Settings → Keys → Generate auth key**. Mark **Reusable**; a short expiry (24 h) is fine — it's only needed during first-boot bootstrap. |
| `TS_API_KEY` | Starts with `tskey-api-` | Tailscale Admin Console → **Settings → Keys → Generate API access token**. Needs **device-removal** scope so `scripts/teardown.sh` can deregister devices cleanly. |
| `TS_TAG` | e.g. `tag:lab-range` | Your choice. Must have a matching `tagOwners` entry in your tailnet ACL policy — see [`docs/tailscale-acls.md`](tailscale-acls.md) for the exact policy to paste in. |

### Required — Active Directory

| Value | Spec | Where to get it |
|---|---|---|
| `AD_DOMAIN_FQDN` | DNS-like name, e.g. `range.local` | Your choice. This is the forest root Ludus promotes `dc01` into. |
| `AD_DOMAIN_ADMIN` | Any username, avoid `Administrator` (reserved on Windows) | Your choice, e.g. `rangeadmin` |
| `AD_PASSWORD` | ≥ 12 characters | Your choice — pick something AD's password policy won't reject. Also used as the default for several lab credentials. |

### Required — Proxmox / target host

| Value | Spec | Where to get it |
|---|---|---|
| `LUDUS_ADMIN_PASSWORD` | ≥ 12 characters | Your choice — becomes the Proxmox `root` password on the installed system. Rotate after first boot if you like. |
| `OPERATOR_SSH_PUBKEY` | A public key (`ssh-ed25519 AAAA...`) **or** a file path | Usually `~/.ssh/id_ed25519.pub` on your build laptop. No key yet? `ssh-keygen -t ed25519`. |
| `DISK_DEVICE_LIST` | TOML array with **exactly one** device, e.g. `["nvme0n1"]` | Boot any Linux live USB on the **target** box and run `lsblk -d -o NAME,SIZE,MODEL,TRAN`. Common values: `nvme0n1` (modern M.2 SSDs, default), `sda` (SATA/SCSI), `vda` (VirtIO, nested KVM testing). PVE 8.4's ext4 install only accepts a single disk. |
| `PROXMOX_FQDN` | FQDN, e.g. `ludus-attackrangelocal.range.local` | Your choice, or accept the default. Becomes `/etc/hostname` on Proxmox **and** the Tailscale device's short name — i.e. how you'll `ssh root@<short-name>.<tailnet>`. |

### Required — monitoring

| Value | Spec | Where to get it | Needed for |
|---|---|---|---|
| `SPLUNK_ADMIN_PASSWORD` | ≥ 12 characters | Your choice | Both modes |
| `ELASTIC_PASSWORD` | ≥ 12 characters | Your choice | `full` mode only (wizard skips this prompt under `minimal`) |
| `KIBANA_ENCRYPTION_KEY` | ≥ 32 characters | Generate with `openssl rand -hex 32` | `full` mode only |

### Optional values

| Value | Spec | Where to get it | Notes |
|---|---|---|---|
| `WIFI_ENABLE` | `true`/`false` | Your choice | Only for laptop deployments where the target reaches the internet via WiFi post-install. The Proxmox installer itself **always** needs wired ethernet for the initial ~15 min (USB-ethernet dongle or phone tether works). |
| `WIFI_SSID` / `WIFI_PASSWORD` | SSID ≤ 32 chars, WPA2-PSK | Your network credentials | Required only if `WIFI_ENABLE=true` |
| `WIFI_COUNTRY` | 2-letter ISO code, uppercase | Your regulatory domain, e.g. `US`, `GB`, `DE` | Wrong value can disable channels your AP uses |
| `WIFI_INTERFACE` | e.g. `wlp2s0` or empty | Leave empty to auto-detect via `iw dev`; set explicitly if the box has multiple radios |
| `WIFI_DISABLE_WIRED_AFTER_BOOT` | `true`/`false` | Your choice | `true` if the wired NIC was a temporary dongle you'll unplug |
| `NOTIFY_WEBHOOK` | `https://...` or empty | Slack/Discord "Incoming Webhook" URL | Posts phase-transition pings during the ~3 h unattended build |
| `SIM_INTERVAL_MINUTES` | Positive integer | Your choice, default `30` | Laptop-side `simulate --loop` cadence |
| `SIM_EXCLUDE` | Comma-separated MITRE T-IDs | Default excludes destructive techniques (`T1485,T1486,T1490,T1491,T1561,T1565,T1529,T1499,T1496`) | Edit only if you want different exclusions |
| `CALDERA_PASSWORD` | Any string | Your choice, default `changeme` | CALDERA admin on the `kali` VM (port 8888) |
| `MALWARE_BAZAAR_API_KEY` | Any string, or empty | Free at <https://bazaar.abuse.ch/account/> | Leave empty to skip pulling defused malware samples (EICAR/APT Simulator/PurpleSharp install regardless) |
| `SPLUNK_USERS` | `user:password:role[,...]`, roles `admin\|power\|user` | Your choice | Leave empty for admin-only, or edit `ludus/splunk-users.yml` directly for advanced setups |

## 4. Run the tool

### Recommended: interactive wizard

```bash
./scripts/build-iso-wizard.sh
```

Walks pre-flight checks → every prompt above (with the description and spec
inline) → writes `.env` → offers to build immediately. Re-run anytime; an
existing `.env` is loaded and shown as the default for each prompt, so you
can fix one value without retyping everything.

Useful flags:

```bash
./scripts/build-iso-wizard.sh --dry-run     # collect + write .env only, don't build
./scripts/build-iso-wizard.sh --build-only  # skip prompts, build from existing .env
```

### Manual: edit `.env` yourself, then build directly

```bash
cp ludus/.env.example .env
$EDITOR .env                # fill in every REPLACE_ME using the tables above
./iso/build-iso.sh
```

`iso/build-iso.sh` fails fast with a clear message naming the first missing
or still-`REPLACE_ME` required variable — no half-built ISOs.

### Output

```
iso/build/attackrangelocal-<RANGE_ID>-<DATE>.iso
```

with its SHA256 printed to stdout. Flash it:

```bash
sudo dd if=iso/build/attackrangelocal-*.iso \
        of=/dev/sdX bs=4M status=progress conv=fsync
```

Triple-check `/dev/sdX` with `lsblk` first — this is a full-disk overwrite.

## 5. If the build fails

The wizard decodes the most common failures automatically (missing tool,
DNS failure, disk full, 404'd Proxmox ISO URL, answer.toml validation
error, etc.) and tells you the fix. If you're calling `iso/build-iso.sh`
directly, match the error text against the diagnosis list at the bottom of
`scripts/build-iso-wizard.sh`, or re-run through the wizard to get the
decoded version.

## Where to go next

- [`docs/unattended-iso.md`](unattended-iso.md) — what the three build
  stages (Proxmox auto-install → first-boot bootstrap → operator
  visibility) actually do after you boot the ISO, plus re-running/recovery
- [`docs/minimal-mode.md`](minimal-mode.md) — full per-VM resource/storage
  breakdown for `RANGE_MODE=minimal`
- [`docs/tailscale-acls.md`](tailscale-acls.md) — the ACL policy to paste
  in so only your operator device can reach the lab
- [`docs/network-isolation.md`](network-isolation.md) — what egress lockdown
  actually blocks post-bootstrap
