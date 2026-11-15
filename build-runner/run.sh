#!/usr/bin/env bash
set -euo pipefail

readonly IMAGE="${RUNNER_IMAGE:-filius-builder:local}"
readonly RUNNER_KIND="${RUNNER_KIND:-build}"
readonly RUNNER_DOCKER_USER="${RUNNER_DOCKER_USER:-filius-runner}"
readonly RUNNER_HOME="${RUNNER_HOME:-/var/lib/filius-runner}"
readonly DEPLOYMENTS_DIR="${FILIUS_DEPLOYMENTS_DIR:-${RUNNER_HOME}/deployments}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly COMPOSE_FILE="${FILIUS_RUNNER_COMPOSE_FILE:-${REPO_DIR}/compose.runners.yaml}"
readonly BROKER="${REPO_DIR}/token-broker/broker.py"

usage() {
  echo "Usage: sudo $0 {--once|--all|--service} https://github.com/OWNER/REPOSITORY"
  echo "  --once     Run one ephemeral job in the foreground."
  echo "  --all      Supervise the installed build worker in the foreground."
  echo "  --service  Enable/start the installed background build worker."
  echo "Long-running build modes keep the eight-hour idle limit and one-worker cap."
}
if [[ $# -eq 1 && "$1" == --help ]]; then
  usage
  exit 0
fi
[[ $# -eq 2 ]] || { usage >&2; exit 2; }
mode="$1"
case "${mode}" in --once|--all|--service) ;; *) usage >&2; exit 2 ;; esac
github_url="${2%/}"
if [[ ! "${github_url}" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "Expected a repository URL like https://github.com/OWNER/REPOSITORY" >&2
  exit 2
fi
case "${RUNNER_KIND}" in
  build|deploy|orchestration) ;;
  *) echo "Unknown runner kind: ${RUNNER_KIND}" >&2; exit 2 ;;
esac
if [[ "${mode}" != --once && "${RUNNER_KIND}" != build ]]; then
  echo "--all and --service manage only the installed build worker." >&2
  exit 2
fi
[[ "${EUID}" -eq 0 ]] || { echo "Run this launcher with sudo to authorize a runner and manage its rootless socket." >&2; exit 1; }
id "${RUNNER_DOCKER_USER}" >/dev/null 2>&1 || { echo "Rootless Docker user not found: ${RUNNER_DOCKER_USER}" >&2; exit 1; }
runner_uid="$(id -u "${RUNNER_DOCKER_USER}")"
export DOCKER_SOCKET="${DOCKER_SOCKET:-/run/user/${runner_uid}/docker.sock}"
export DOCKER_HOST="unix://${DOCKER_SOCKET}"
export RUNNER_DOCKER_USER RUNNER_HOME GITHUB_URL="${github_url}"
export FILIUS_TOKEN_BROKER_DIR="${FILIUS_TOKEN_BROKER_DIR:-/var/lib/filius-control/token-broker}"

if [[ "${mode}" != --once ]]; then
  controller=/usr/local/lib/filius/host-control/controller.py
  [[ -f "${controller}" ]] || { echo "Install the host runtime with setup.sh first." >&2; exit 1; }
  if [[ "${mode}" == --all ]]; then
    exec /usr/bin/python3 "${controller}" all
  fi
  exec /usr/bin/python3 "${controller}" enable
fi

[[ -S "${DOCKER_SOCKET}" ]] || { echo "Rootless Docker socket not found: ${DOCKER_SOCKET}" >&2; exit 1; }
[[ -S "${FILIUS_TOKEN_BROKER_DIR}/broker.sock" && -f "${BROKER}" ]] || {
  echo "Token broker is not installed/running; run root setup.sh first." >&2
  exit 1
}
command -v docker >/dev/null 2>&1 || { echo "Docker CLI is required." >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 plugin is required." >&2; exit 1; }
[[ -f "${COMPOSE_FILE}" ]] || { echo "Compose file not found: ${COMPOSE_FILE}" >&2; exit 1; }
if [[ "${RUNNER_KIND}" == deploy && ! -d "${DEPLOYMENTS_DIR}" ]]; then
  echo "Deployment directory not found: ${DEPLOYMENTS_DIR}" >&2
  exit 1
fi
instance=""
socket_permissions_registered=0
cleanup_runner() {
  local status=$?
  if [[ -n "${instance}" ]]; then
    /usr/bin/python3 -B "${BROKER}" revoke "${instance}" \
      || echo "Could not revoke the runner startup grant; it expires automatically." >&2
  fi
  if [[ "${RUNNER_KIND}" != orchestration ]]; then
    restore_socket_permissions
  fi
  return "${status}"
}
if [[ "${RUNNER_KIND}" != orchestration ]]; then
  socket_dir="$(dirname -- "${DOCKER_SOCKET}")"
  socket_dir_owner="$(stat -c '%u' "${socket_dir}")"
  socket_dir_mode="$(stat -c '%a' "${socket_dir}")"
  socket_owner="$(stat -c '%u' "${DOCKER_SOCKET}")"
  if [[ "${socket_dir_owner}" != "${runner_uid}" || "${socket_owner}" != "${runner_uid}" ]] || (( (8#${socket_dir_mode} & 077) != 0 )); then
    echo "Refusing to relax socket permissions: ${socket_dir} must be owned by ${RUNNER_DOCKER_USER} and private." >&2
    exit 1
  fi
  command -v flock >/dev/null 2>&1 || { echo "flock is required for runner socket coordination." >&2; exit 1; }
  readonly SOCKET_LOCK_FILE="${socket_dir}/.filius-runner-socket.lock"
  readonly SOCKET_STATE_FILE="${socket_dir}/.filius-runner-socket.state"
  exec {socket_lock_fd}>"${SOCKET_LOCK_FILE}"
  restore_socket_permissions() {
    flock -x "${socket_lock_fd}"
    if [[ "${socket_permissions_registered}" -eq 1 && -s "${SOCKET_STATE_FILE}" ]]; then
      local original_mode active_count
      IFS=' ' read -r original_mode active_count <"${SOCKET_STATE_FILE}" || true
      active_count=$((active_count - 1))
      if ((active_count <= 0)); then
        chmod "${original_mode}" "${DOCKER_SOCKET}" 2>/dev/null || true
        rm -f "${SOCKET_STATE_FILE}"
      else
        printf '%s %s\n' "${original_mode}" "${active_count}" >"${SOCKET_STATE_FILE}"
      fi
    fi
    flock -u "${socket_lock_fd}"
  }
fi
trap cleanup_runner EXIT
docker info >/dev/null
runner_name="${RUNNER_NAME:-filius-${RUNNER_KIND}-$(cat /proc/sys/kernel/random/uuid)}"
instance="$(/usr/bin/python3 -B "${BROKER}" authorize "${github_url}" "${runner_name}" "${RUNNER_KIND}")"
if [[ "${RUNNER_KIND}" != orchestration ]]; then
  flock -x "${socket_lock_fd}"
  if [[ -s "${SOCKET_STATE_FILE}" ]]; then
    read -r original_socket_mode active_socket_users <"${SOCKET_STATE_FILE}"
  else
    original_socket_mode="$(stat -c '%a' "${DOCKER_SOCKET}")"
    active_socket_users=0
  fi
  active_socket_users=$((active_socket_users + 1))
  printf '%s %s\n' "${original_socket_mode}" "${active_socket_users}" >"${SOCKET_STATE_FILE}"
  socket_permissions_registered=1
  chmod 0666 "${DOCKER_SOCKET}"
  flock -u "${socket_lock_fd}"
fi

unset RUNNER_TOKEN GITHUB_PAT_FILE
export RUNNER_NAME="${runner_name}" FILIUS_RUNNER_INSTANCE="${instance}"
export RUNNER_IMAGE="${IMAGE}" FILIUS_DEPLOYMENTS_DIR="${DEPLOYMENTS_DIR}"
case "${RUNNER_KIND}" in
  deploy) compose_service=deployment-runner ;;
  orchestration) compose_service=orchestration-runner ;;
  build) compose_service=build-runner ;;
esac
echo "Starting one ephemeral ${RUNNER_KIND} runner; registration uses the host token broker."
docker compose --project-name filius-runners --file "${COMPOSE_FILE}" run \
  --rm --no-deps --name "${runner_name}" "${compose_service}"
