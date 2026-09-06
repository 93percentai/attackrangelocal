#!/usr/bin/env bash
# Renders a ludus/range-config-*.yml.j2 from .env and tells Ludus to deploy.
# Template is selected by RANGE_MODE (full | minimal).
# Blocks until the range reports SUCCESS (or fails out).
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
STATUS_FILE=/var/lib/ludus-bootstrap/status

write_status() { echo "$1" > "$STATUS_FILE" 2>/dev/null || true; }

if [[ ! -f "$ENV_FILE" ]]; then
  echo ".env not found at $ENV_FILE (copy ludus/.env.example to .env and fill it in)" >&2
  exit 1
fi

set -a; source "$ENV_FILE"; set +a

# RANGE_MODE picks which template to render. Default = full for backward
# compatibility with .env files that pre-date minimal mode.
RANGE_MODE="${RANGE_MODE:-full}"
case "$RANGE_MODE" in
  full)    TEMPLATE="${REPO_ROOT}/ludus/range-config.yml.j2" ;;
  minimal) TEMPLATE="${REPO_ROOT}/ludus/range-config-minimal.yml.j2" ;;
  *) echo "RANGE_MODE must be 'full' or 'minimal' (got: $RANGE_MODE)" >&2; exit 1 ;;
esac
OUT="${REPO_ROOT}/ludus/range-config.yml"
echo "Using $RANGE_MODE-mode template: $TEMPLATE"

# SPLUNK_ADMIN_PASSWORD is rendered into the splunk VM's role_vars, so an
# empty value would silently install Splunk with a blank admin password.
required=(RANGE_ID TS_AUTHKEY TS_API_KEY AD_DOMAIN_FQDN AD_DOMAIN_ADMIN AD_PASSWORD
          TS_TAG SPLUNK_ADMIN_PASSWORD)
for v in "${required[@]}"; do
  if [[ -z "${!v:-}" || "${!v}" == REPLACE_ME* ]]; then
    echo "Required env var $v is unset or still a placeholder" >&2
    exit 1
  fi
done

# envsubst leaves Ludus's own {{ range_id }} mustaches alone because they use
# double-braces; we only substitute ${VAR} form.
envsubst < "$TEMPLATE" > "$OUT"
echo "Rendered range config -> $OUT"

ludus range config set -f "$OUT"
echo "Deploying range (45-60 minutes)..."
write_status range-deploying
ludus range deploy

# Poll for completion.
while true; do
  state="$(ludus range status -j 2>/dev/null | grep -oE '"rangeState":"[A-Z_]+"' | head -1 | cut -d'"' -f4 || echo UNKNOWN)"
  echo "Range state: $state"
  case "$state" in
    SUCCESS) break ;;
    FAIL|ERROR) echo "Range deploy FAILED" >&2; exit 1 ;;
    *) sleep 60 ;;
  esac
done

write_status range-up
echo "Range UP."
