# Minimal mode

When you don't have a 30 GB / 16-thread box, set `RANGE_MODE=minimal`.
The whole thing fits a **16 GB RAM / 12 thread / 256 GB SSD** host.

## Topology

| VM | RAM | vCPU | Disk | Role |
|---|---:|---:|---:|---|
| `dc01` | 4 GB | 2 | 32 GB | **DC + member-server combined** — AD root for `range.local`, file/IIS surface |
| `winclient1` | 3 GB | 2 | 32 GB | Win 11, domain-joined, Atomic Runner + EICAR + APT Simulator target |
| `splunk` | 4 GB | 2 | 24 GB | Splunk Enterprise — the **only SIEM** in this mode |
| `linux` | 1 GB | 1 | 12 GB | Ubuntu victim with Sysmon-for-Linux + Splunk UF |
| `kali` | 2 GB | 2 | 16 GB | Attacker — CALDERA server + atomic-red-team + automated red team tools |

**Lab total: ~14 GB RAM, 9 vCPU, ~116 GB disk allocated.** With Proxmox
+ Ludus router + headroom, the whole host sits around **~16 GB / 12
threads / ~140 GB used** (thin-provisioned).

## What's NOT in minimal mode

- **No Elasticsearch / Kibana / Fleet** — Splunk is the only SIEM. The
  `ELASTIC_*` and `KIBANA_*` env vars aren't needed; the wizard skips
  those prompts when `RANGE_MODE=minimal`.
- **No winsrv1** — the DC absorbs the member-server role. If you need a
  separate file/IIS server, switch to full mode or add it manually.
- **No Elastic Agent** on Windows / Linux hosts. Splunk Universal
  Forwarder still ships every event to `splunk:9997`.
- **No `ansible/elastic-stack.yml` / `ansible/elastic-agents.yml` run**
  during bootstrap — `install-monitoring.sh` short-circuits past them.

Everything else carries over from full mode:
- AD forest, Tailscale mesh, Splunk + Sysmon TAs
- Atomic Runner continuous simulation
- APT Simulator, PurpleSharp, CALDERA, EICAR, defused malware path
- Network lockdown after bootstrap
- Replacement UI (the Kibana card is hidden when `RANGE_MODE=minimal`)

## How to enable it

### Via the wizard (recommended)

```bash
./scripts/build-iso-wizard.sh
```

The first prompt is "Range mode: full or minimal" — pick `minimal`.
Elastic prompts are skipped automatically.

### Via .env directly

```bash
echo 'RANGE_MODE=minimal' >> .env
./iso/build-iso.sh
```

`scripts/deploy-range.sh` reads `RANGE_MODE` and selects
`ludus/range-config-minimal.yml.j2`. Inventory scripts pick
`ansible/inventory-minimal.yml.j2`. `scripts/install-monitoring.sh`
skips the two Elastic playbooks.

## Storage budget (256 GB host)

| Allocated | Size |
|---|---:|
| Lab VM disks (thin) | 116 GB |
| Ludus templates (Win2022 + Win11 + Ubuntu + Kali) | ~80 GB |
| Proxmox host system | ~20 GB |
| Ludus state + logs | ~5 GB |
| Headroom for Splunk indexes growing | ~30 GB |
| **Total** | **~250 GB** |

If indexes grow past the budget, either:
- Set Splunk's retention shorter (default 90 days is generous for a lab),
- Or `vm_disk_gb: 32` on the splunk VM is the field to bump.

## Resource budget (16 GB host)

| Component | RAM | vCPU |
|---|---:|---:|
| Lab VMs (5) | 14 GB | 9 |
| Proxmox host | ~1.5 GB | ~1 |
| Ludus router VM | ~0.5 GB | ~1 |
| **Total** | **~16 GB** | **~11** |

The host needs **at least 12 threads**; if you only have 8, drop
`winclient1` cpus to 1 and `splunk` cpus to 1 — they'll still work, just
slower at scale.

## Switching between modes after deploy

`RANGE_MODE` is read at deploy time. To switch:

```bash
# Tear down first — the VM topology differs
scripts/teardown.sh --confirm

# Edit .env
sed -i 's/^RANGE_MODE=.*/RANGE_MODE=full/' .env   # or minimal

# Re-deploy
scripts/deploy-range.sh
scripts/install-monitoring.sh
scripts/install-extended-attacks.sh
scripts/lock-down.sh
```

You can't hot-swap a running range between modes — the inventory and
network rules differ.
