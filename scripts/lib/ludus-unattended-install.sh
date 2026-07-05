#!/usr/bin/env bash
# Non-interactive Ludus client + server install for Proxmox first-boot.
#
# Ludus 2.x exposes an official unattended mode: `ludus-server --no-prompt`.
# That skips the license dialog, Proxmox warning TUI, config form, and admin
# form. We pre-seed /opt/ludus/install/initial-admin.yml for the admin user.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/ludus-network.sh
source "${SCRIPT_DIR}/ludus-network.sh"

LUDUS_PROJECT_ID=54052321
LUDUS_ENV_FILE=/var/lib/ludus-bootstrap/ludus.env

set_proxmox_locale() {
  if [[ -f /usr/bin/pveversion ]]; then
    export LANGUAGE=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    export LANG=en_US.UTF-8
    export LC_CTYPE=en_US.UTF-8
  fi
}

ludus_latest_tag() {
  curl -fsSL "https://gitlab.com/api/v4/projects/${LUDUS_PROJECT_ID}/repository/tags" \
    | grep -o '"name":"[^"]*' | cut -d'"' -f4 | head -n1
}

ludus_client_installed() {
  command -v ludus >/dev/null 2>&1
}

ludus_server_ready() {
  [[ -f /opt/ludus/install/.stage-3-complete ]] \
    && systemctl is-active --quiet ludus.service 2>/dev/null
}

ludus_install_in_progress() {
  if systemctl is-active --quiet ludus-install.service 2>/dev/null; then
    return 0
  fi
  if [[ -f /opt/ludus/install/.stage-1-complete || -f /opt/ludus/install/.stage-2-complete ]] \
    && [[ ! -f /opt/ludus/install/.stage-3-complete ]]; then
    return 0
  fi
  return 1
}

write_initial_admin_yml() {
  local dest="$1"
  local user_id name email password

  # Ludus 2.x: userID must match ^[A-Za-z][A-Za-z0-9]{0,20}$
  user_id="${LUDUS_API_USER_ID:-rangeadmin}"
  name="${LUDUS_API_USER_NAME:-Range Admin}"
  email="${LUDUS_API_USER_EMAIL:-admin@${AD_DOMAIN_FQDN:-range.local}}"
  password="${LUDUS_API_USER_PASSWORD:-${LUDUS_ADMIN_PASSWORD:-}}"

  if [[ -z "$password" ]]; then
    password="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 20)"
    echo "Generated Ludus admin password (saved in ${LUDUS_ENV_FILE%.env}-admin-password)"
    install -d -m 700 "$(dirname "$LUDUS_ENV_FILE")"
    printf '%s\n' "$password" > "${LUDUS_ENV_FILE%.env}-admin-password"
    chmod 600 "${LUDUS_ENV_FILE%.env}-admin-password"
  fi

  cat >"$dest" <<EOF
---
name: ${name}
email: ${email}
userID: ${user_id}
password: ${password}
EOF
  chmod 600 "$dest"
}

ensure_initial_admin_yml() {
  install -d -m 700 /opt/ludus/install
  if [[ ! -f /opt/ludus/install/initial-admin.yml ]]; then
    write_initial_admin_yml /opt/ludus/install/initial-admin.yml
  fi
}

install_ludus_client_only() {
  local tag tmpdir file

  if ludus_client_installed; then
    echo "Ludus client already installed: $(ludus version 2>/dev/null || echo present)"
    return 0
  fi

  tag="$(ludus_latest_tag)"
  [[ -n "$tag" ]] || { echo "Could not resolve Ludus release tag" >&2; return 1; }

  tmpdir="$(mktemp -d)"
  file="ludus-client_linux-amd64-${tag}"
  curl -fsSL \
    "https://gitlab.com/api/v4/projects/${LUDUS_PROJECT_ID}/packages/generic/ludus/${tag}/${file}" \
    -o "${tmpdir}/ludus"
  chmod +x "${tmpdir}/ludus"
  install -C -m 755 "${tmpdir}/ludus" /usr/local/bin/ludus
  rm -rf "$tmpdir"
  echo "Installed Ludus client ${tag}"
}

install_ludus_server_unattended() {
  local tag workdir cleanup tmp

  set_proxmox_locale
  ensure_initial_admin_yml

  cleanup=0
  if [[ -x /opt/ludus/ludus-server ]]; then
    workdir=/opt/ludus
    echo "Using installed ludus-server in /opt/ludus"
  else
    tag="$(ludus_latest_tag)"
    [[ -n "$tag" ]] || { echo "Could not resolve Ludus release tag" >&2; return 1; }
    workdir="$(mktemp -d)"
    cleanup=1
    curl -fsSL \
      "https://gitlab.com/api/v4/projects/${LUDUS_PROJECT_ID}/packages/generic/ludus/${tag}/ludus-server-${tag}" \
      -o "${workdir}/ludus-server"
    chmod +x "${workdir}/ludus-server"
    echo "Downloaded Ludus server ${tag}"
  fi

  if [[ ! -f "${workdir}/config.yml" ]]; then
    echo "Writing ${workdir}/config.yml from host network detection..."
    render_ludus_server_config >"${workdir}/config.yml"
  fi

  echo "Starting Ludus server install via ludus-server --no-prompt..."
  echo "(On existing Proxmox this does not reboot; install may take 15-30 minutes.)"
  (
    cd "$workdir"
    ./ludus-server --no-prompt
  )

  if [[ "$cleanup" -eq 1 ]]; then
    rm -rf "$workdir"
  fi
}

wait_for_ludus_ready() {
  local i max="${LUDUS_INSTALL_WAIT_ITERATIONS:-360}"

  for ((i = 1; i <= max; i++)); do
    if ludus_server_ready; then
      return 0
    fi
    if command -v ludus-install-status >/dev/null 2>&1; then
      ludus-install-status 2>&1 | tail -15 || true
    elif ludus_install_in_progress; then
      systemctl status ludus-install.service --no-pager 2>&1 | tail -5 || true
      [[ -f /opt/ludus/install/install.log ]] && tail -3 /opt/ludus/install/install.log || true
    fi
    echo "Waiting for Ludus install to finish (${i}/${max})..."
    sleep 10
  done
  echo "Timed out waiting for Ludus to become ready" >&2
  echo "Inspect: ludus-install-status  and  tail -f /opt/ludus/install/install.log" >&2
  return 1
}

write_ludus_env_file() {
  local env_file="$LUDUS_ENV_FILE"
  local root_key=/opt/ludus/install/root-api-key
  local api_key=""

  install -d -m 700 "$(dirname "$env_file")"

  if command -v ludus-install-status >/dev/null 2>&1; then
    local status_out
    status_out="$(ludus-install-status 2>&1 || true)"
    api_key="$(printf '%s\n' "$status_out" | sed -n "s/.*LUDUS_API_KEY='\([^']*\)'.*/\1/p" | head -1)"
    if [[ -z "$api_key" ]]; then
      api_key="$(printf '%s\n' "$status_out" | sed -n 's/.*| \([A-Za-z][A-Za-z0-9]*\.[^ |]*\) |.*/\1/p' | head -1)"
    fi
  fi

  if [[ -z "$api_key" && -f "$root_key" ]]; then
    api_key="$(tr -d '\n' < "$root_key")"
  fi

  if [[ -z "$api_key" ]]; then
    echo "Ludus is up but no API key was found under /opt/ludus/install/" >&2
    return 1
  fi

  cat >"$env_file" <<EOF
# Written by scripts/bootstrap-ludus.sh — sourced by downstream pipeline scripts.
export LUDUS_API_KEY='${api_key}'
EOF
  chmod 600 "$env_file"

  cat >/etc/profile.d/attackrangelocal-ludus.sh <<EOF
# Ludus API key for unattended pipeline scripts (root shell).
export LUDUS_API_KEY='${api_key}'
EOF
  chmod 644 /etc/profile.d/attackrangelocal-ludus.sh
}

run_ludus_unattended_install() {
  if ludus_server_ready; then
    echo "Ludus server already running."
    write_ludus_env_file
    return 0
  fi

  if ludus_install_in_progress; then
    echo "Ludus install already in progress — waiting for completion..."
    wait_for_ludus_ready
    write_ludus_env_file
    return 0
  fi

  install_ludus_client_only
  install_ludus_server_unattended

  if ! ludus_server_ready; then
    if ludus_install_in_progress || [[ -d /opt/ludus ]]; then
      echo "Ludus install started. Waiting for completion..."
      wait_for_ludus_ready
    else
      echo "Ludus install did not start successfully" >&2
      return 1
    fi
  fi

  write_ludus_env_file

  set_proxmox_locale
  # shellcheck disable=SC1091
  source "$LUDUS_ENV_FILE"
  echo "Ludus install complete: $(ludus version)"
}
