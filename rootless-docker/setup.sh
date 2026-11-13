#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNNER_USER="${RUNNER_USER:-filius-runner}"
readonly RUNNER_HOME="${RUNNER_HOME:-/var/lib/filius-runner}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this setup script with sudo: sudo $0" >&2
  exit 1
fi

if [[ "$(uname -s)" != Linux ]] || ! command -v systemctl >/dev/null; then
  echo "This setup expects a Linux host running systemd." >&2
  exit 1
fi

if ! command -v apt-get >/dev/null; then
  echo "This first version supports Debian or Ubuntu hosts with apt-get." >&2
  exit 1
fi

if ! id "${RUNNER_USER}" >/dev/null 2>&1; then
  useradd --system --user-group --create-home \
    --home-dir "${RUNNER_HOME}" --shell /bin/bash "${RUNNER_USER}"
  passwd --lock "${RUNNER_USER}" >/dev/null
  echo "Created locked service account ${RUNNER_USER}."
else
  actual_home="$(getent passwd "${RUNNER_USER}" | cut -d: -f6)"
  if [[ "${actual_home}" != "${RUNNER_HOME}" ]]; then
    echo "${RUNNER_USER} already exists with home ${actual_home}, not ${RUNNER_HOME}." >&2
    echo "Set RUNNER_HOME=${actual_home} and rerun, or resolve the account mismatch." >&2
    exit 1
  fi
fi

ensure_subid_range() {
  local file="$1"
  local option="$2"
  local existing

  existing="$(awk -F: -v user="${RUNNER_USER}" '$1 == user && $3 >= 65536 { print $3; exit }' "${file}" 2>/dev/null || true)"
  if [[ -n "${existing}" ]]; then
    return
  fi

  local start=100000
  local end
  while :; do
    end=$((start + 65535))
    if ! awk -F: -v start="${start}" -v end="${end}" \
      '($2 <= end) && (($2 + $3 - 1) >= start) { found = 1 } END { exit found ? 0 : 1 }' \
      "${file}" 2>/dev/null; then
      usermod "${option}" "${start}-${end}" "${RUNNER_USER}"
      return
    fi
    start=$((end + 1))
  done
}

apt-get update
apt-get install -y --no-install-recommends uidmap dbus-user-session slirp4netns fuse-overlayfs

if ! command -v docker >/dev/null; then
  echo "Docker CLI is missing. Install Docker Engine before running this setup." >&2
  exit 1
fi

if ! command -v dockerd-rootless-setuptool.sh >/dev/null; then
  if apt-cache show docker-ce-rootless-extras >/dev/null 2>&1; then
    apt-get install -y --no-install-recommends docker-ce-rootless-extras
  fi
fi
if ! command -v dockerd-rootless-setuptool.sh >/dev/null; then
  echo "dockerd-rootless-setuptool.sh is missing." >&2
  echo "Install the rootless extras package matching your Docker Engine, then rerun." >&2
  exit 1
fi

ensure_subid_range /etc/subuid --add-subuids
ensure_subid_range /etc/subgid --add-subgids

runner_uid="$(id -u "${RUNNER_USER}")"
bash "${SCRIPT_DIR}/delegate-cgroups.sh"
loginctl enable-linger "${RUNNER_USER}"
systemctl start "user@${runner_uid}.service"

runtime_dir="/run/user/${runner_uid}"
for attempt in {1..30}; do
  [[ -S "${runtime_dir}/bus" ]] && break
  sleep 1
done
if [[ ! -S "${runtime_dir}/bus" ]]; then
  echo "The systemd user bus did not start at ${runtime_dir}/bus." >&2
  exit 1
fi

runuser -u "${RUNNER_USER}" -- env \
  HOME="${RUNNER_HOME}" \
  USER="${RUNNER_USER}" \
  LOGNAME="${RUNNER_USER}" \
  XDG_RUNTIME_DIR="${runtime_dir}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  dockerd-rootless-setuptool.sh install --force

runuser -u "${RUNNER_USER}" -- env \
  HOME="${RUNNER_HOME}" \
  USER="${RUNNER_USER}" \
  LOGNAME="${RUNNER_USER}" \
  XDG_RUNTIME_DIR="${runtime_dir}" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  systemctl --user enable --now docker.service

socket="${runtime_dir}/docker.sock"
for attempt in {1..30}; do
  [[ -S "${socket}" ]] && break
  sleep 1
done
if [[ ! -S "${socket}" ]]; then
  echo "Rootless Docker did not create its socket at ${socket}." >&2
  echo "Check: sudo journalctl -u user@${runner_uid}.service" >&2
  exit 1
fi

echo
echo "Rootless Docker is ready for ${RUNNER_USER}."
echo "Socket: ${socket}"
echo "The setup leaves /etc/filius/github-token root-only. Do not add ${RUNNER_USER} to the docker group."
echo "Check the daemon with: sudo -u ${RUNNER_USER} DOCKER_HOST=unix://${socket} docker info"
echo "The runner launcher mounts this rootless socket into the runner container."
