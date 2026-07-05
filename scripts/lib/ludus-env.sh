#!/usr/bin/env bash
# Load Ludus API credentials written by bootstrap-ludus.sh.
set -euo pipefail

LUDUS_ENV_FILE=/var/lib/ludus-bootstrap/ludus.env

source_ludus_env() {
  if [[ -f "$LUDUS_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$LUDUS_ENV_FILE"; set +a
    return 0
  fi
  # Do not default to ROOT — most ludus CLI commands reject it.
  if command -v ludus-install-status >/dev/null 2>&1; then
    local status_out api_key
    status_out="$(ludus-install-status 2>&1 || true)"
    api_key="$(printf '%s\n' "$status_out" | sed -n 's/.*API key for user [^:]*: \([^[:space:]]*\).*/\1/p' | head -1)"
    if [[ -n "$api_key" ]]; then
      export LUDUS_API_KEY="$api_key"
      return 0
    fi
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
