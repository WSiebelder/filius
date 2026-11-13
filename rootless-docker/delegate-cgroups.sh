#!/usr/bin/env bash
set -euo pipefail

readonly RUNNER_USER="${RUNNER_USER:-filius-runner}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo: sudo $0" >&2
  exit 1
fi
if ! command -v systemctl >/dev/null; then
  echo "This setup expects a Linux host running systemd." >&2
  exit 1
fi
if ! id "${RUNNER_USER}" >/dev/null 2>&1; then
  echo "User not found: ${RUNNER_USER}" >&2
  exit 1
fi

runner_uid="$(id -u "${RUNNER_USER}")"
unit="user@${runner_uid}.service"
dropin_dir="/etc/systemd/system/${unit}.d"
dropin="${dropin_dir}/delegate.conf"
expected='[Service]
Delegate=cpu cpuset io memory pids'

if [[ "$(stat -fc '%T' /sys/fs/cgroup)" != cgroup2fs ]]; then
  echo "WARNING: The host is not using unified cgroup v2; some Docker resource-controller warnings may remain." >&2
fi

install -d -m 755 "${dropin_dir}"
if [[ -f "${dropin}" ]] && [[ "$(cat "${dropin}")" == "${expected}" ]]; then
  echo "Cgroup delegation is already configured for ${RUNNER_USER}."
  exit 0
fi

tmp_file="$(mktemp "${dropin_dir}/delegate.conf.XXXXXX")"
trap 'rm -f "${tmp_file}"' EXIT
printf '%s\n' "${expected}" >"${tmp_file}"
chmod 644 "${tmp_file}"
mv "${tmp_file}" "${dropin}"
trap - EXIT

systemctl daemon-reload
if systemctl is-active --quiet "${unit}"; then
  echo "Restarting ${unit} to apply cgroup delegation; its rootless Docker daemon will restart."
  systemctl restart "${unit}"
fi

echo "Delegated cpu, cpuset, io, memory, and pids controllers to ${RUNNER_USER}'s systemd user manager."
