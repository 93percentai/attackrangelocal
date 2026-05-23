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

- A **Ludus** range definition (`ludus/range-config.yml.j2`) for a 6-VM
  topology: AD forest (DC + 2 members), Splunk, Linux victim, Kali
  attacker — all on one isolated VLAN, all joined to your tailnet
- A **patched Attack Range v5 fork** (`attack_range_fork/`) with:
  - new `local_ludus` provider (no Terraform, no cloud)
  - WireGuard phase bypassed (Tailscale already provides VPN)
  - new `simulate --loop --random --interval` for continuous attacks
- A **replacement web UI** (`ui/`) built for this deployment — VM
  status, AD info, isolation checks, continuous-sim controls — instead
  of upstream's cloud-provider/WireGuard-sharing UI
- **Deny-by-default egress** at the Ludus router — lab VMs cannot dial
  the public internet after bootstrap completes
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
├── ansible/                     # Static inventory + Atomic Runner playbook + schedule
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
scripts/deploy-range.sh            # deploys all 6 VMs  (~45 min)
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

- x86_64 host, Passmark > 6,000
- **≥ 64 GB RAM** (44 GB allocated to lab VMs, headroom for Proxmox)
- **≥ 500 GB SSD**
- **Wired** internet (during bootstrap only)

## Verification (after deploy + lockdown)

1. `tailscale status` lists 7 hosts (Proxmox + 6 VMs)
2. `https://<RANGE_ID>-splunk:8000` over tailnet — `admin / changeme123!`
3. Splunk: `index=* host=*winclient1*` shows Sysmon EID 1 within 5 min
4. `scripts/verify-isolation.sh` exits 0 (no internet from lab VMs)
5. From `kali`: `nmap 10.${RANGE_ID}.20.0/24` enumerates lab hosts
6. Every ~30 min: a randomly chosen ATT&CK technique fires and lands in
   Splunk

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
- [`docs/ui.md`](docs/ui.md) — replacement web UI tour + dev loop

## Credits

- [splunk/attack_range](https://github.com/splunk/attack_range) — upstream v5
- [Ludus](https://ludus.cloud) — the cyber-range platform
- [P4T12ICK/ludus_ar_*](https://github.com/P4T12ICK) — community Ludus + Attack Range roles
- [NocteDefensor/ludus_tailscale](https://github.com/NocteDefensor/ludus_tailscale) — Tailscale role
- [Red Canary's invoke-atomicredteam](https://github.com/redcanaryco/invoke-atomicredteam) — Atomic Runner
