# Attack Range v5 patches

We do not maintain a hard fork of `splunk/attack_range`. Instead,
`attack_range_fork/bootstrap.sh` clones the upstream repo at a pinned tag
(default `v5.0.0`) into `attack_range_fork/upstream/` and applies our
patches programmatically via `attack_range_fork/apply-patches.py`.

This keeps us close to upstream — to follow a new Attack Range release,
bump `ATTACK_RANGE_REF` in `bootstrap.sh` and re-run it.

The patcher uses exact literal-string anchors (not line numbers, not loose
regexes) taken directly from the pinned tag's source, so a
`WARN: literal text not found` means upstream drifted and the anchor in
`apply-patches.py` needs updating — see "Re-applying patches" below. Run
`attack_range_fork/bootstrap.sh` after any change and confirm every patch
reports `OK` (not `WARN`) before trusting the result.

## Why `local_ludus` needs patches at all

Upstream Attack Range v5 assumes it owns the whole VM lifecycle: it reads a
`general.cloud_provider` (`aws | azure | gcp`) from the config YAML,
provisions infrastructure with Terraform, stands up a WireGuard VPN router,
and only then configures the lab with Ansible. In this repo, **Ludus has
already created and configured every VM** (`scripts/deploy-range.sh`) and
**Tailscale already provides remote access** — there's no Terraform state
and no WireGuard router to build. The patches teach Attack Range's
controller about a `local_ludus` provider that skips all of that and treats
the range as already running.

## The patches

### Patch 1 — register `local_ludus` as a valid provider

**Where**: `attack_range/attack_range_controller.py`

- `AttackRangeController.__init__` validates `self.cloud_provider_name`
  against an allow-list (`["aws", "azure", "gcp"]`) and calls `sys.exit(1)`
  otherwise — `local_ludus` is added to that list.
- `_init_cloud_provider()` gets a `local_ludus` branch that instantiates
  `LocalLudusProvider` (companion file, copied in — not patched).
- `_setup_directories()` gets a `local_ludus` branch for `self.terraform_dir`
  (unused in practice, since local_ludus never calls `terraform_manager`,
  but every other branch sets it so we keep the invariant).

**Companion file** (copied in by `bootstrap.sh`, not patched):
`attack_range/cloud_providers/local_ludus_provider.py` — implements the
`BaseCloudProvider`-shaped no-op methods; none of them are actually called
in the local_ludus code path (see Patch 2), so it exists mostly so
`_init_cloud_provider()` has something concrete to instantiate.

### Patch 2 — short-circuit `build()` and `destroy()`

**Why**: upstream's `build()` runs `build_vpn_phase()` (Terraform apply +
WireGuard playbooks) then `build_lab_phase()` (regenerates `lab.yaml` from
the `attack_range:` config and runs it) — both entirely Terraform/VPN
lifecycle, not just "the WireGuard part". There's no narrower seam to patch
around; for `local_ludus` the whole thing is skipped.

**Where**:
- `AttackRangeController.build()` — for `local_ludus`, instead of calling
  `terraform_manager`/`ansible_manager` VPN+lab machinery, it saves the
  config, copies the static inventory (Patch 3), and marks
  `general.status = "running"` directly, then returns. This is what makes
  `/attack-range/simulate` (which requires `status in ["running", "completed"]`)
  usable at all for `local_ludus` — nothing else in this codebase ever calls
  `build()`'s upstream Terraform path.
- `AttackRangeController.destroy()` — for `local_ludus`, just removes the
  config file; use `scripts/teardown.sh` to actually remove the Ludus range.

**Operational implication**: `scripts/start-attack-range.sh` runs
`attack_range.py build --template local_ludus/default.yml` once (via the
`attack_range` CLI container) after `docker compose up -d`, purely to
create `config/local-ludus-range.yml` with `status: running`. Re-running it
is idempotent (Patch 5 keeps the same `attack_range_id` every time).

### Patch 3 — static inventory injection

**Why**: Upstream rebuilds Ansible inventory from `attack_range:` config
entries every time it needs to talk to a VM (`update_inventory_attack_range_servers`),
assuming AWS-shaped `10.0.2.<ip_last_octet>` private IPs and a shared SSH
private key file. We have neither — real connectivity info lives in
`ansible/inventory.yml.j2` (Tailscale MagicDNS hostnames, per-OS
WinRM/SSH auth).

**Where**: `attack_range/managers/ansible_manager.py::update_inventory_attack_range_servers`
gets a short-circuit at the top:

```python
if self.cloud_provider == "local_ludus":
    if os.path.exists("/inventory.yml"):
        shutil.copy("/inventory.yml", self.inventory_path)
        return
```

`docker/attack-range.compose.yml` mounts `ansible/inventory.yml` at
`/inventory.yml` in **both** the `attack_range` (CLI) and `api` services —
the `api` service is the one that's actually always running and serves
`/attack-range/simulate`, so it needs the mount too.

**Inventory shape matters**: `ansible/inventory.yml.j2` declares groups
FLAT at the top level (not nested under `all: children:`), because
`AttackRangeController.simulate()` does its own raw `yaml.safe_load()` of
this file and looks up `inventory[target]['hosts']` as a **top-level key**
— it does not walk `all.children`. Per-host singleton groups (`dc01`,
`winclient1`, `winsrv1`) exist purely so `simulate --target winclient1`
resolves to exactly one host even though `winclient1` also belongs to the
3-host `windows` group (for WinRM connection vars, which Ansible merges
from every group a host belongs to).

### Patch 4 — `simulate --loop / --random / --interval / --exclude`

**Why**: Upstream `simulate` only accepts a comma-separated technique list
and runs once, and neither the CLI dispatcher nor `AttackRangeController.simulate()`
forward any extra state. We want a fire-and-forget loop that picks random
techniques from the Atomics index, skipping destructive ones.

**Where**:
- `attack_range.py` — add four flags to `simulate_parser` (`--techniques` /
  `-te` stays **required** by argparse even when `--random` is set — its
  value is simply ignored in that case).
- `attack_range.py::simulate_action` — forward the parsed flags into
  `controller.simulate(...)` (upstream calls
  `controller.simulate(args.target, techniques)` with the *local* `techniques`
  variable, not `args.techniques` — don't anchor a patch on `args.techniques`).
- `attack_range/attack_range_controller.py::simulate` — the original method
  (which validates the target, refreshes inventory, and calls
  `run_ansible_playbook_safe("simulate_atomic_red_team.yml", ...)`) is
  renamed to `_simulate_inner` verbatim. A new `simulate()` wrapper with the
  extra kwargs is added in front of it: single-shot when `loop=False`,
  otherwise loops forever picking `_pick_random_technique()` (or the fixed
  list) every `interval_minutes`, tolerating per-iteration failures.

**Random selection** pulls from `redcanaryco/atomic-red-team`'s shipped
Indexes CSVs under `atomics/Indexes/Indexes-CSV/*.csv` (mounted into the
`attack_range` container from the `atomic-red-team` volume). The exclude
list filters destructive techniques (default in `.env`:
`T1485,T1486,T1490,T1491,T1561,T1565,T1529`).

**Not exposed over the API**: `--loop`/`--random`/`--interval`/`--exclude`
only exist on the CLI (`attack_range.py simulate`). The Flask API's
`POST /attack-range/simulate` (`api/app.py`) takes a plain
`{attack_range_id, target, techniques[]}` body and always calls
`controller.simulate(target, techniques)` once — that's intentional
(`docs/continuous-simulation.md`'s "Path B" runs the CLI directly via
`docker compose exec`, not through the API).

### Patch 5 — fixed `attack_range_id`

**Why**: `local_ludus` is a persistent lab (Ludus owns the VMs and their
lifetime), not a disposable per-build cloud stack. Upstream's
`build_action()` always calls `prepare_config_from_template(..., generate_id=True)`,
minting a fresh random UUID (and therefore a fresh `config/<uuid>.yml`,
losing any previous `status: running`) on every single invocation of
`attack_range.py build`.

**Where**: `attack_range.py::build_action` peeks at the resolved template's
`general.cloud_provider` before calling `prepare_config_from_template`; if
it's `local_ludus`, `generate_id=False` is passed instead, so the fixed
`general.attack_range_id: local-ludus-range` baked into
`templates/local_ludus/default.yml` is reused every time — re-running
`scripts/start-attack-range.sh` (and therefore the seed `build` call) is a
safe, idempotent no-op that just re-marks the same config as `running`.

### Patch 6 — Docker compose override

**Where**: `docker/attack-range.compose.yml` in *this* repo (NOT in the
fork). Sets host networking (so the container reaches lab VMs over the
host's tailnet by MagicDNS) and mounts `ansible/inventory.yml` on both the
`attack_range` and `api` services. Used as:

```bash
docker compose \
  -f attack_range_fork/upstream/docker/docker-compose.yml \
  -f docker/attack-range.compose.yml \
  up -d
```

Note the upstream `attack_range` service is tagged `profiles: [cli]` and
never starts with `up -d` — it's invoked directly
(`docker compose ... run --rm attack_range <args>`), which is how
`scripts/start-attack-range.sh` seeds the range (Patch 2) and how
`scripts/start-continuous-sim.sh --laptop` drives the loop (Patch 4).

## Re-applying patches against a new Attack Range release

```bash
# 1. Bump the tag
sed -i 's/ATTACK_RANGE_REF:=v5.0.0/ATTACK_RANGE_REF:=v5.X.Y/' attack_range_fork/bootstrap.sh

# 2. Re-run bootstrap
attack_range_fork/bootstrap.sh

# 3. If apply-patches.py reports "WARN: literal text not found" for any
#    patch, the upstream code drifted. Open the named file, find the
#    equivalent location, and update the literal anchor in apply-patches.py
#    to match the new source exactly (copy-paste from the real file rather
#    than guessing/regexing — this pinned-version patcher trades generality
#    for being trivially easy to verify against one specific tag).
# 4. Re-run and confirm every line says OK, not WARN.
```

If you want to sanity-check the patched fork without touching real
infrastructure, you can exercise the controller directly with a fake
`/inventory.yml` and confirm `build()` marks a config `running` and
`simulate()` reaches (and only fails at) the actual `ansible-playbook`
network call — see the test transcript in this repo's PR history for an
example harness.
