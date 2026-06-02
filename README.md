# attackrangelocal

Run **Splunk Attack Range v5 locally**, with **Tailscale for access**, on
a single Proxmox box, **fully isolated from the open internet**, with
**continuous fire-and-forget Atomic Red Team** firing against a generated
AD forest — built from **a single unattended ISO**.

Splunk officially dropped local mode in Attack Range v3 ("ongoing
challenges with VirtualBox and Vagrant") and v5 is cloud-only (AWS / Azure
/ GCP) with WireGuard for access. This repo is the substrate to get all of
v5's goodness (web UI, REST API, simulator) on bare metal you own, with
the WireGuard piece swapped for Tailscale.

## What this repo gives you

- A **Ludus** range definition (`ludus/range-config.yml.j2`) for a 7-VM
  topology: AD forest (DC + 2 members), Splunk, **Elastic / Kibana**,
  Linux victim, Kali attacker — all on one isolated VLAN, all joined to
  your tailnet
- **Two SIEMs running in parallel** (Splunk + Elastic) against the same
  telemetry. Sysmon / Winlogbeat / auditd ship to BOTH stacks via
  Universal Forwarder + Elastic Agent. Multi-user Splunk supported via
  `.env` or `ludus/splunk-users.yml`.
- A **patched Attack Range v5 fork** (`attack_range_fork/`) with:
  - new `local_ludus` provider (no Terraform, no cloud)
  - WireGuard phase bypassed (Tailscale already provides VPN)
  - new `simulate --loop --random --interval` for continuous attacks
- A **replacement web UI** (`ui/`) built for this deployment — VM
  status, AD info, isolation checks, continuous-sim controls — instead
  of upstream's cloud-provider/WireGuard-sharing UI
- **Deny-by-default egress** at the Ludus router — after bootstrap, the
  only outbound the lab keeps is what Tailscale needs (TCP/443, UDP/41641,
  UDP/53). Operators on a different network reach the lab through this
  Tailscale path; everything else (ICMP, arbitrary TCP, etc.) is dropped
- An **unattended ISO** (`iso/build-iso.sh`) that installs Proxmox,
  bootstraps Ludus, builds templates, deploys the range, locks down
  egress, and starts continuous Atomic Red Team — all from a single USB
  with zero operator input
- **Tailscale ACLs** that confine lab access to your operator device only

## Why not LocalStack Hobby?

LocalStack Hobby is a free AWS-API emulator. It doesn't run real VMs
(Docker-backed EC2 is a Pro feature and even Pro can't boot the Windows
Server / Splunk AMIs Attack Range expects). It cannot host the actual
Splunk + Windows + Kali workloads. Documented as a rejected alternative;
Ludus is the only viable substrate.

## Repo layout

```
attackrangelocal/
├── ludus/                       # Ludus range definition + role list + .env template
├── attack_range_fork/           # Cloner + patcher for splunk/attack_range v5
│   ├── bootstrap.sh             #   clones upstream, applies patches
│   ├── apply-patches.py         #   string-based patcher (idempotent)
│   └── new-files/               #   files copied in (local_ludus_provider.py, template)
├── docker/                      # Compose override that wires the patched fork to Ludus
├── ui/                          # Replacement Astro web UI (port 4321)
├── ansible/                     # Inventory + Atomic Runner + Elastic stack + Splunk-users playbooks
├── iso/                         # Unattended Proxmox ISO build pipeline
│   ├── answer.toml.j2           #   Proxmox auto-installer answer file
│   ├── first-boot.sh            #   runs once on the freshly-installed host
│   └── build-iso.sh             #   bakes everything into one bootable ISO
├── scripts/                     # Operator helpers (deploy, lock-down, verify, teardown)
└── docs/                        # Detailed per-topic runbooks
```

## Two ways to use it

### Path 1 — Fully unattended (recommended)

Burn one USB, boot one box, walk away. ~3 hours later you have a fully
running, isolated lab.

**Easiest:** run the interactive wizard, which prompts for every config
option with descriptions + validation, then builds the ISO and decodes
any errors that come back.

```bash
./scripts/build-iso-wizard.sh
```

If you'd rather edit the .env by hand and call the build script directly:

```bash
# On your laptop
cp ludus/.env.example .env
$EDITOR .env                                          # fill in every field
sudo apt install proxmox-auto-install-assistant gettext-base
./iso/build-iso.sh
sudo dd if=iso/build/attackrangelocal-*.iso of=/dev/sdX bs=4M status=progress
# Boot target box from USB. Done.
```

Full details: [`docs/unattended-iso.md`](docs/unattended-iso.md).

### Path 2 — Manual, step-by-step (if you already have Proxmox)

```bash
# On your laptop, render .env
cp ludus/.env.example .env && $EDITOR .env

# On the Proxmox host (root)
scp -r ./ root@proxmox:/opt/attackrangelocal/
ssh root@proxmox
cd /opt/attackrangelocal
scripts/bootstrap-ludus.sh         # installs Ludus
scripts/install-roles.sh           # roles + templates (~75 min)
scripts/deploy-range.sh            # deploys 5 or 7 VMs depending on RANGE_MODE
scripts/install-monitoring.sh      # Splunk users (+ Elastic stack if RANGE_MODE=full)
scripts/install-extended-attacks.sh # APT Simulator, CALDERA, defused samples (optional)
scripts/lock-down.sh               # cuts off internet egress
scripts/start-continuous-sim.sh    # kicks off Atomic Runner on win-client1
scripts/verify-isolation.sh        # MUST return 0
```

Then on your laptop, to drive ad-hoc simulations via the Attack Range UI:

```bash
attack_range_fork/bootstrap.sh     # clones + patches upstream Attack Range
scripts/start-attack-range.sh      # docker compose up (UI on :4321, API :4000)
```

## Hardware

Two presets, picked by `RANGE_MODE` in `.env` (the wizard prompts you):

| Mode | RAM | Threads | SSD | What you get |
|---|---:|---:|---:|---|
| `minimal` | **16 GB** | **12** | **256 GB** | 5 VMs: DC+server, win client, splunk, linux, kali. Splunk only — no Elastic. |
| `full` (default) | **30 GB** | **16** | **500 GB** | 7 VMs: DC, 2 win members, splunk, **elastic**, linux, kali. Both SIEMs. |

Either way: x86_64 host (Passmark > 6,000), wired internet during the
~90-min bootstrap window only.

Full-mode footprint (lab 22 GB / 12 vCPU + Proxmox + router):

Footprint (lab 22 GB / 12 vCPU + Proxmox + router):

| Component | RAM | vCPU |
|---|---:|---:|
| dc01        | 3 GB | 2 |
| winclient1  | 4 GB | 2 |
| winsrv1     | 2 GB | 1 |
| splunk      | 5 GB | 2 |
| elastic     | 4 GB | 2 |
| linux       | 2 GB | 1 |
| kali        | 2 GB | 2 |
| Proxmox host | ~3 GB | ~1 |
| Ludus router | ~1 GB | ~1 |
| Headroom | ~4 GB | ~2 |
| **Total** | **~30 GB** | **~16** |

Drop `winsrv1` from the range config (-2 GB / -1 vCPU) if you need to fit a smaller box.

## Verification (after deploy + lockdown)

1. `tailscale status` lists 8 hosts (Proxmox + 7 VMs)
2. `http://<RANGE_ID>-splunk:8000` over tailnet — `admin / changeme123!`,
   plus any extra users from `SPLUNK_USERS` / `splunk-users.yml`
3. `http://<RANGE_ID>-elastic:5601` over tailnet — `elastic / $ELASTIC_PASSWORD`
4. Splunk **and** Kibana: Sysmon EID 1 from `winclient1` lands in both
   within 5 min
5. `scripts/verify-isolation.sh` exits 0 (no internet from lab VMs)
6. From `kali`: `nmap 10.${RANGE_ID}.20.0/24` enumerates lab hosts
7. Every ~30 min: a randomly chosen ATT&CK technique fires and lands in
   both SIEMs

## Teardown

```bash
ssh root@ludus-host
cd /opt/attackrangelocal
scripts/teardown.sh --confirm
```

Cleanly deregisters Tailscale devices, then destroys the VMs in Proxmox.

## Further reading

- [`docs/unattended-iso.md`](docs/unattended-iso.md) — how the ISO pipeline works
- [`docs/attack-range-patches.md`](docs/attack-range-patches.md) — what we change in upstream
- [`docs/network-isolation.md`](docs/network-isolation.md) — every layer of the egress block
- [`docs/tailscale-acls.md`](docs/tailscale-acls.md) — keep the range off other tailnet devices
- [`docs/ad-forest.md`](docs/ad-forest.md) — forest topology, credentials, extending
- [`docs/continuous-simulation.md`](docs/continuous-simulation.md) — Atomic Runner schedule, both loop paths
- [`docs/extended-attacks.md`](docs/extended-attacks.md) — APT Simulator, PurpleSharp, CALDERA, defused malware samples
- [`docs/monitoring.md`](docs/monitoring.md) — Splunk + Elastic side-by-side, multi-user setup
- [`docs/minimal-mode.md`](docs/minimal-mode.md) — 16 GB / 256 GB topology, what's dropped vs full
- [`docs/ui.md`](docs/ui.md) — replacement web UI tour + dev loop

## Credits

- [splunk/attack_range](https://github.com/splunk/attack_range) — upstream v5
- [Ludus](https://ludus.cloud) — the cyber-range platform
- [P4T12ICK/ludus_ar_*](https://github.com/P4T12ICK) — community Ludus + Attack Range roles
- [NocteDefensor/ludus_tailscale](https://github.com/NocteDefensor/ludus_tailscale) — Tailscale role
- [Red Canary's invoke-atomicredteam](https://github.com/redcanaryco/invoke-atomicredteam) — Atomic Runner
