#!/usr/bin/env bash
# Removes every "bootstrap-*" rule from the range config and redeploys the
# Ludus router only. After this runs, NO lab VM can initiate connections to
# the public internet except for the three Tailscale-required egress rules
# (TCP/443, UDP/41641, UDP/53).
#
# Works on BOTH range-config formats:
#   - block style (full mode):     - name: bootstrap-X
#                                    vlan_src: 20
#                                    ...
#   - flow style (minimal mode):   - { name: bootstrap-X, vlan_src: 20, ... }
#
# Idempotent: safe to run twice. Uses real YAML parsing so it's not fooled
# by indentation tricks the way the previous regex was.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/ludus/range-config.yml"
STATUS_FILE=/var/lib/ludus-bootstrap/status

if [[ ! -f "$CONFIG" ]]; then
  echo "Rendered range config not found at $CONFIG — run deploy-range.sh first" >&2
  exit 1
fi

# Use ruamel.yaml when available (preserves comments + ordering), fall back
# to pyyaml otherwise. The fallback loses comments but keeps the rules.
python3 - "$CONFIG" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])

try:
    from ruamel.yaml import YAML
    yaml = YAML()
    yaml.preserve_quotes = True
    yaml.width = 4096
    yaml.indent(mapping=2, sequence=4, offset=2)
    data = yaml.load(path.read_text())
    have_ruamel = True
except ImportError:
    import yaml as pyyaml
    data = pyyaml.safe_load(path.read_text())
    have_ruamel = False

rules = data.get("network", {}).get("rules", []) or []
before = len(rules)
kept = [r for r in rules if not str(r.get("name", "")).startswith("bootstrap-")]
removed = before - len(kept)
data["network"]["rules"] = kept

if have_ruamel:
    from io import StringIO
    buf = StringIO()
    yaml.dump(data, buf)
    path.write_text(buf.getvalue())
else:
    import yaml as pyyaml
    path.write_text(pyyaml.safe_dump(data, sort_keys=False, default_flow_style=False))

print(f"Stripped {removed} bootstrap rule(s); kept {len(kept)} permanent rule(s).")
if removed == 0:
    print("WARNING: no bootstrap-* rules found. Either:")
    print("  - Lockdown was already applied (re-run is a no-op, safe)")
    print("  - Or the range config never had bootstrap rules (check the template)")
PY

ludus range config set -f "$CONFIG"
echo "Pushing router-only redeploy..."
ludus range deploy --only-router || ludus range deploy
echo "Lockdown applied."
echo "lockdown-applied" > "$STATUS_FILE" 2>/dev/null || true
