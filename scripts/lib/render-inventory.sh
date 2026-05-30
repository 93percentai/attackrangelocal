#!/usr/bin/env bash
# Source-able helper: picks the right inventory template based on RANGE_MODE
# and renders it via envsubst.
#
# Usage from another script:
#   REPO_ROOT="..."
#   set -a; source "$REPO_ROOT/.env"; set +a
#   source "$REPO_ROOT/scripts/lib/render-inventory.sh"
#   render_inventory          # writes $REPO_ROOT/ansible/inventory.yml

render_inventory() {
  local mode="${RANGE_MODE:-full}"
  local src
  case "$mode" in
    full)    src="${REPO_ROOT}/ansible/inventory.yml.j2" ;;
    minimal) src="${REPO_ROOT}/ansible/inventory-minimal.yml.j2" ;;
    *) echo "RANGE_MODE must be 'full' or 'minimal' (got: $mode)" >&2; return 1 ;;
  esac
  envsubst < "$src" > "${REPO_ROOT}/ansible/inventory.yml"
}
