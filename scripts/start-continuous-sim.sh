#!/usr/bin/env bash
# Kicks off the continuous fire-and-forget attack loop.
#
# Two paths — pick one:
#   --laptop  : runs `attack_range simulate --loop --random` from the Docker
#               container on this machine. If the laptop sleeps, attacks pause.
#   --windows : installs Atomic Runner as a Windows service on win-client1.
#               Survives reboots and disconnections. Runs forever.
#
# Default: --windows (more resilient).
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
set -a; source "${REPO_ROOT}/.env"; set +a

MODE="${1:---windows}"

case "$MODE" in
  --laptop)
    : "${SIM_INTERVAL_MINUTES:=30}"
    : "${SIM_EXCLUDE:=T1485,T1486,T1490,T1491,T1561,T1565,T1529}"
    FORK_DIR="${REPO_ROOT}/attack_range_fork/upstream"
    if [[ ! -d "$FORK_DIR" ]]; then
      echo "Attack Range fork not present. Run: attack_range_fork/bootstrap.sh" >&2
      exit 1
    fi
    source "${REPO_ROOT}/scripts/lib/render-inventory.sh"
    render_inventory
    COMPOSE_FILES=(
      -f "${FORK_DIR}/docker/docker-compose.yml"
      -f "${REPO_ROOT}/docker/attack-range.compose.yml"
    )
    echo "Starting laptop-side continuous loop (interval ${SIM_INTERVAL_MINUTES}m, exclude ${SIM_EXCLUDE})"
    docker compose "${COMPOSE_FILES[@]}" --profile cli run --rm attack_range \
      python attack_range.py simulate \
        --target winclient1 \
        --techniques T1082 \
        --random \
        --loop \
        --interval "${SIM_INTERVAL_MINUTES}" \
        --exclude "${SIM_EXCLUDE}"
    ;;
  --windows)
    source "${REPO_ROOT}/scripts/lib/render-inventory.sh"
    render_inventory
    ansible-galaxy collection install -r "${REPO_ROOT}/ansible/requirements.yml" 1>&2
    ansible-playbook \
      -i "${REPO_ROOT}/ansible/inventory.yml" \
      "${REPO_ROOT}/ansible/atomic-runner.yml"
    echo "Atomic Runner service installed on win-client1. Schedule:"
    echo "  $(wc -l < "${REPO_ROOT}/ansible/files/atomic-schedule.csv") techniques over ~6h rotation."
    echo "Stop by SSH-ing to ${RANGE_ID}-winclient1 and creating C:\\AtomicRunner\\stop"
    ;;
  *)
    echo "Usage: $0 [--laptop | --windows]" >&2
    exit 1
    ;;
esac
