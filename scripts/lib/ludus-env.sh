#!/usr/bin/env bash
# Load Ludus API credentials written by bootstrap-ludus.sh.
set -euo pipefail

LUDUS_ENV_FILE=/var/lib/ludus-bootstrap/ludus.env

source_ludus_env() {
  if [[ -f "$LUDUS_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$LUDUS_ENV_FILE"; set +a
  elif [[ -f /opt/ludus/install/root-api-key ]]; then
    export LUDUS_API_KEY
    LUDUS_API_KEY="$(tr -d '\n' < /opt/ludus/install/root-api-key)"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  source_ludus_env
  if [[ -n "${LUDUS_API_KEY:-}" ]]; then
    echo "LUDUS_API_KEY is set"
  else
    echo "LUDUS_API_KEY is not set" >&2
    exit 1
  fi
fi
