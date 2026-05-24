#!/usr/bin/env bash
# Removes every "bootstrap-*" rule from the range config and redeploys the
# Ludus router only. After this runs, NO lab VM can initiate connections to
# the public internet except for Tailscale UDP/41641 and DNS UDP/53.
#
# Idempotent: safe to run twice.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${REPO_ROOT}/ludus/range-config.yml"
STATUS_FILE=/var/lib/ludus-bootstrap/status

if [[ ! -f "$CONFIG" ]]; then
  echo "Rendered range config not found at $CONFIG — run deploy-range.sh first" >&2
  exit 1
fi

python3 - "$CONFIG" <<'PY'
import sys, re, pathlib
path = pathlib.Path(sys.argv[1])
text = path.read_text()
# Strip any rule whose `name:` starts with bootstrap-. Each rule is a
# multi-line YAML mapping in our template.
out, skip = [], False
for line in text.splitlines():
    stripped = line.strip()
    if stripped.startswith("- name: bootstrap-"):
        skip = True
        continue
    if skip:
        # rule attributes are indented further than the list marker; the rule
        # ends at the next "    - name:" or any line at the rules-list indent
        if re.match(r"^    - ", line) or re.match(r"^  [A-Za-z]", line):
            skip = False
            out.append(line)
        # else: still inside the bootstrap rule, drop it
        continue
    out.append(line)
path.write_text("\n".join(out) + "\n")
print(f"Stripped bootstrap rules from {path}")
PY

ludus range config set -f "$CONFIG"
echo "Pushing router-only redeploy..."
ludus range deploy --only-router || ludus range deploy
echo "Lockdown applied."
echo "lockdown-applied" > "$STATUS_FILE" 2>/dev/null || true
