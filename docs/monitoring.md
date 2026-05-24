# Monitoring: Splunk + Elastic, side-by-side

The range ships with **two SIEMs running in parallel** against the same
telemetry. This lets you author and compare detections in both stacks.

| Stack | Where | Web UI | API |
|---|---|---|---|
| **Splunk Enterprise** | `${RANGE_ID}-splunk:8000`   | http://splunk:8000   | `:8089` (REST) |
| **Elastic / Kibana**  | `${RANGE_ID}-elastic:5601`  | http://elastic:5601  | `:9200` (ES) · `:8220` (Fleet) |

Both are reachable over Tailscale by MagicDNS hostname.

## What runs where

`splunk` VM (Ubuntu 22.04, 5 GB / 2 vCPU):
- Splunk Enterprise 9.3 — installed by `P4T12ICK.ludus_ar_splunk`
- Universal Forwarders on every other host already forward to `:9997`
- Apps: SA-CIM, DA-ESS-ContentUpdate (ESCU), Sysmon TA, Windows TA, Unix/Linux TA

`elastic` VM (Ubuntu 22.04, 4 GB / 2 vCPU):
- Elasticsearch 8.x (single-node, 1 GB heap)
- Kibana (512 MB heap)
- Fleet Server (port 8220)
- All three brought up via Docker compose by `ansible/elastic-stack.yml`

Every Windows + Linux lab host runs **both**:
- Splunk Universal Forwarder → `splunk:9997` (TCP)
- Elastic Agent → `elastic:8220` (Fleet enrolment, agent then ships to ES)

Result: the same Sysmon event lands in Splunk's `index=*` and Elastic's
`logs-*` data streams within seconds of each other.

## Default credentials

| User | Where | Password |
|---|---|---|
| `admin` | Splunk | `${SPLUNK_ADMIN_PASSWORD}` (default `changeme123!`) |
| `elastic` | Elastic + Kibana | `${ELASTIC_PASSWORD}` from `.env` |

**Change these.** The `.env.example` ships placeholders; set strong
values before building the ISO or running `scripts/deploy-range.sh`.

## Multi-user Splunk

There are two ways to add additional Splunk users — pick whichever fits.

### 1. Inline (simple)

Set `SPLUNK_USERS` in `.env`:

```
SPLUNK_USERS=alice:Wxy!Zzz_16chars:admin,bob:Bbb!Bb_16chars:power,charlie:Cc!Cc_16chars:user
```

Format: `user:password:role[,user:password:role]...`
Roles: `admin` · `power` · `user` · `can_delete` · (any built-in Splunk role)

Then either:
- Run `scripts/install-monitoring.sh` (idempotent — applies users), or
- Let the unattended ISO bootstrap apply them in the `install-monitoring`
  phase

### 2. Rich schema (production-style)

Copy `ludus/splunk-users.example.yml` → `ludus/splunk-users.yml` (the
copy is git-ignored). Edit:

```yaml
- name: alice
  password: "ChangeMe!Alice_16chars"
  role: admin
  email: alice@range.local
- name: bob
  password: "ChangeMe!Bob_16chars"
  role: power
  email: bob@range.local
```

Then `scripts/install-monitoring.sh` (or `ansible-playbook ansible/splunk-users.yml`
directly) applies it. Idempotent — existing users aren't touched.

### 3. One-off add

```bash
scripts/add-splunk-user.sh dave power
# (prompts for password, SSHes to splunk over Tailscale)
```

## Multi-user Elastic / Kibana

Elastic's RBAC is richer than Splunk's, so the lab ships only the
`elastic` superuser. Add per-team users via Kibana → Stack Management →
Users (or via the ES API):

```bash
curl -u elastic:${ELASTIC_PASSWORD} \
  -X POST "http://${RANGE_ID}-elastic:9200/_security/user/alice" \
  -H 'content-type: application/json' \
  -d '{
    "password": "ChangeMe!Alice_16chars",
    "roles":    ["viewer", "kibana_admin"],
    "full_name":"Alice",
    "email":    "alice@range.local"
  }'
```

Common pre-defined Elastic roles: `superuser`, `kibana_admin`,
`editor`, `viewer`, `monitoring_user`. Full list:
<https://www.elastic.co/guide/en/elasticsearch/reference/current/built-in-roles.html>

## Useful starter queries

**Splunk** — anything Sysmon EID 1 in the last hour:
```
index=* sourcetype="WinEventLog:Sysmon" EventCode=1 earliest=-60m
| stats count by host, Image, CommandLine
```

**Elastic** — same data, Kibana KQL in Discover:
```
event.module : "sysmon" and event.code : "1" and @timestamp > now-1h
```

**Splunk** — Atomic Red Team detonations:
```
index=* (sourcetype="WinEventLog:Microsoft-Windows-PowerShell/Operational" OR sourcetype="WinEventLog:Sysmon")
| search "Invoke-AtomicTest" OR Image="*AtomicRunner*"
```

**Elastic** — Atomic Red Team detonations:
```
process.name : ("powershell.exe" or "pwsh.exe") and
process.command_line : ("*Invoke-AtomicTest*" or "*AtomicRunner*")
```

## Lockdown interaction

The Elastic stack and all agents install **during the bootstrap window**,
when egress to `artifacts.elastic.co` and `docker.elastic.co` is allowed.
After `scripts/lock-down.sh` runs:

- Images / agent binaries are on disk
- Elastic Agent <-> Fleet Server <-> Elasticsearch traffic is intra-VLAN
- No data leaves the lab — both SIEMs index locally, forever

If you want to push detections to a managed Elastic Cloud later: that's
a deliberate egress rule you'd add manually in `range-config.yml.j2`.

## Resource budget

The full stack fits inside **30 GB RAM / 16 threads** end-to-end:

| Component | RAM | vCPU |
|---|---:|---:|
| Lab VMs (7) | 22 GB | 12 |
| Proxmox host | ~3 GB | ~1 |
| Ludus router VM | ~1 GB | ~1 |
| Headroom | ~4 GB | ~2 |
| **Total** | **~30 GB** | **~16** |

Pinching one further? Drop `winsrv1` (saves 2 GB / 1 vCPU) — the AD
forest still works with just the DC + winclient1.
