# Tracking upstream `splunk/attack_range`

Record of what we've reviewed upstream, what we adopted, and what we
deliberately didn't. Update it whenever you re-review, so the next person
doesn't redo the analysis.

**Last reviewed:** 2026-09-06, against `v5.0.0` (`5f63cd7`) and
`develop` (`8acb922`).

## Upstream state at last review

- **`v5.0.0` is still the newest release.** No `v5.1`, no newer tag.
  We pin `ATTACK_RANGE_REF=v5.0.0` in `attack_range_fork/bootstrap.sh`.
- The default branch is `develop`, ~44 commits ahead of `v5.0.0`.
- There is **no upstream local/on-prem provider**.
  `attack_range/cloud_providers/` is still exactly aws / azure / gcp /
  base. Our `local_ludus` approach remains the only way to run this
  off-cloud, so the fork stays necessary.

## Adopted

| What | Where | Notes |
|---|---|---|
| **Splunk 10.2.2 pin** | `ludus/range-config*.yml.j2` | Upstream `develop` pins Splunk via `ludus_ar_splunk_url`. We had no pin and were inheriting `P4T12ICK.ludus_ar_splunk`'s 9.3.0 default. Now pinned explicitly in both range configs. |

## Deliberately not adopted

| What | Why not |
|---|---|
| **Rebase onto `develop`** | `BaseCloudProvider` changed incompatibly: `update_backend_config(dict, …)` was renamed to `write_backend_config(BackendParams, …)` **and** a new abstract `get_backend_params()` was added (8 abstract methods → 9). `local_ludus_provider.py` would fail to instantiate until it implements both. Not worth it for an unreleased branch. |
| **`--atomics` / `--atomic-file` simulate flags** | Genuinely nice (run one specific atomic GUID, or ship a custom atomic YAML). But `develop`-only, and our continuous simulation runs through `ansible/atomic-runner.yml` on the target host rather than through Attack Range's `simulate`. Low marginal value for the maintenance cost of two more patches. |
| **Structured ART execution results** | `develop` added `_normalize_art_execution_result` / `_parse_debug_msg_payload` and friends in `ansible_manager.py`, giving per-technique pass/fail. Attractive for our `--loop` mode's logging, but same reasoning as above — revisit if we move continuous sim onto Attack Range's simulate path. |
| **`apply-role` subcommand + `ATTACK_RANGE_LOCAL_ROLES`** | Runs arbitrary local Ansible roles against a range host. We already invoke Ansible directly from `scripts/`, so this duplicates capability we have. |
| **`attack_range/splunk_export.py`** | Pulls raw events out of Splunk over REST. Hardcodes `10.0.2.{octet}` AWS addressing, so it needs rework for Ludus addressing, and we have direct Splunk access over Tailscale anyway. |

## Confirmed absent upstream (so our patches stay ours)

- **No continuous / loop / scheduled simulation mode.** Grepping
  `continuous|loop|interval|schedule` across `attack_range/`, `api/` and
  `attack_range.py` on both `v5.0.0` and `develop` finds only
  `wait_for_ssh(check_interval=…)` and WinRM retry settings. Our
  `simulate --loop --random --interval --exclude` patches have no upstream
  equivalent to defer to.
- **No new simulation engines.** Atomic Red Team via
  `p4t12ick.ar_atomic_red_team` is still the only one. Branches exist for
  PurpleSharp (`650-issue-purplesharp-simulation-technique`) and Caldera
  (`ZachTheSplunker-mitre-caldera`) but neither is merged. We install both
  ourselves via `ansible/extended-attacks.yml` / `caldera-server.yml`.
- **No template schema change.** Still `templates/{aws,azure,gcp}/*.yml`.

## When you next review

1. Check for a release newer than `v5.0.0`. If there is one, bump
   `ATTACK_RANGE_REF` and run `attack_range_fork/bootstrap.sh` — the
   patcher's verification gate will tell you precisely which patterns
   broke (see `docs/attack-range-patches.md`).
2. Re-check `BaseCloudProvider`'s abstract methods. Any addition means
   `local_ludus_provider.py` needs a matching implementation or the
   controller raises `TypeError` at construction.
3. Re-check whether upstream has grown a loop/continuous mode. If it has,
   our four simulate patches could potentially be retired.
