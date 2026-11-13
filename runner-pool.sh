#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${1:-}"

if [[ -z "${REPO_URL}" ]]; then
  echo "Usage: sudo $0 https://github.com/OWNER/REPOSITORY" >&2
  exit 2
fi
if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script with sudo so it can read the PAT and manage the rootless socket." >&2
  exit 1
fi

children=()
stop_pool() {
  trap - INT TERM EXIT
  if ((${#children[@]})); then
    kill "${children[@]}" 2>/dev/null || true
    wait "${children[@]}" 2>/dev/null || true
  fi
}
trap stop_pool INT TERM EXIT

run_forever() {
  local kind="$1"
  local launcher
  if [[ "${kind}" == deploy ]]; then
    launcher="${SCRIPT_DIR}/deployment-runner/run-once.sh"
  else
    launcher="${SCRIPT_DIR}/build-runner/run-once.sh"
  fi

  while true; do
    echo "[$(date --iso-8601=seconds)] Starting one ${kind} runner for ${REPO_URL}."
    if "${launcher}" "${REPO_URL}"; then
      :
    else
      status=$?
      echo "[$(date --iso-8601=seconds)] ${kind} runner ended with status ${status}; retrying in 10 seconds." >&2
      sleep 10
    fi
  done
}

run_forever build & children+=("$!")
run_forever build & children+=("$!")
run_forever deploy & children+=("$!")

echo "Started runner pool: 2 build workers, 1 deployment worker. Press Ctrl-C to stop."
wait -n "${children[@]}"
status=$?
echo "A runner-pool worker stopped unexpectedly (status ${status}); stopping the pool." >&2
