# Attack Range v5 patches

We do not maintain a hard fork of `splunk/attack_range`. Instead,
`attack_range_fork/bootstrap.sh` clones the upstream repo at a pinned tag
(default `v5.0.0`) into `attack_range_fork/upstream/` and applies our
patches programmatically via `attack_range_fork/apply-patches.py`.

This keeps us close to upstream — to follow a new Attack Range release,
bump `ATTACK_RANGE_REF` in `bootstrap.sh` and re-run it.

## The five patches

### Patch 1 — register `local_ludus` as a valid provider

**Why**: Attack Range hard-codes `aws | azure | gcp` as `cloud_provider` values
in `AttackRangeController` and the provider dispatcher.

**Where**:
- `attack_range/attack_range_controller.py` (`cloud_provider_name` check and
  `_init_cloud_provider()`)

**Companion file** (copied in, not patched): `attack_range/cloud_providers/local_ludus_provider.py`
— implements `BaseProvider` methods as no-ops because Ludus already
created the VMs.

### Patch 2 — WireGuard bypass

**Why**: v5's "two-phase build" sets up a WireGuard router in cloud, then
runs lab provisioning behind it. On Ludus, Tailscale already provides
mesh access; there's no WG router to stand up.

**Where**: `attack_range/managers/ansible_manager.py` — gate
  `update_vpn_playbook`, `update_vpn_config_playbook`,
  `_patch_wireguard_allowed_ips`, `_patch_wireguard_server_config`,
  `prompt_vpn_connection`
  behind `if self.cloud_provider == "local_ludus": return`
- `attack_range/attack_range_controller.py::build`, `::build_vpn_phase` —
  early-return with `status: running`

**Frontend**: The `app/` Astro UI is told `VITE_VPN_DISABLED=true` via the
compose override, which hides the "Generate WireGuard config" / "Share"
buttons that would otherwise be broken.

### Patch 3 — static inventory injection

**Why**: Upstream rebuilds Ansible inventory from Terraform outputs every
time it needs to talk to a VM. We have no Terraform outputs — we have a
hand-written inventory of Tailscale MagicDNS hostnames.

**Where**: `attack_range/managers/ansible_manager.py::update_inventory_attack_range_servers`
gets a short-circuit at the top:

```python
if self.cloud_provider == "local_ludus":
    if os.path.exists("/inventory.yml"):
        shutil.copy("/inventory.yml", self.inventory_path)
        return
```

`scripts/prepare-attack-range-config.sh` writes `config/${RANGE_ID}.yml`
with `status: running` so simulate/API validation passes without a cloud
build. `scripts/start-attack-range.sh` calls it automatically.

`docker/attack-range.compose.yml` mounts `ansible/inventory.yml` at
`/inventory.yml` in the container.

### Patch 4 — `simulate --loop / --random / --interval / --exclude`

**Why**: Upstream `simulate` only accepts a comma-separated technique
list and runs once. We want a fire-and-forget loop that picks random
techniques from the Atomics index, skipping destructive ones.

**Where**:
- `attack_range.py` — add four flags to `simulate_parser`
- `attack_range/attack_range_controller.py::simulate` — wrap the existing
  body in a `while True:` driven by the new flags. Existing body is
  renamed to `_simulate_inner` (the wrapper calls it on each iteration).

**Random selection** pulls from `redcanaryco/atomic-red-team`'s shipped
Indexes CSVs under `atomics/Indexes/Indexes-CSV/*.csv`. The exclude list
filters destructive techniques (default in `.env`: `T1485,T1486,T1490,T1491,T1561,T1565,T1529`).

### Patch 5 — Docker compose override

**Why**: Tell the upstream compose stack to run with the `local_ludus`
provider, hide the VPN UI, mount our inventory, and use host networking
so the container reaches lab VMs over the host's tailnet.

**Where**: `docker/attack-range.compose.yml` in *this* repo (NOT in the
fork). Used as:

```bash
docker compose \
  -f attack_range_fork/upstream/docker/docker-compose.yml \
  -f docker/attack-range.compose.yml \
  up -d
```

## Re-applying patches against a new Attack Range release

```bash
# 1. Bump the tag
sed -i 's/ATTACK_RANGE_REF:=v5.0.0/ATTACK_RANGE_REF:=v5.X.Y/' attack_range_fork/bootstrap.sh

# 2. Re-run bootstrap
attack_range_fork/bootstrap.sh

# 3. If apply-patches.py reports "WARN: pattern not matched" for any
#    patch, the upstream code drifted. Open the named file, find the
#    equivalent location, and update the regex/anchor in apply-patches.py.
```

The patcher is intentionally string-matching rather than line-numbered so
that minor drift (whitespace, neighbouring lines) doesn't break it.
