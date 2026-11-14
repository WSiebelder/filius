#!/usr/bin/env bash
set -euo pipefail

# Start one ephemeral Actions runner. It waits for one matching job, runs it,
# then deregisters and exits. The host removes its container on exit.

readonly IMAGE="${RUNNER_IMAGE:-filius-builder:local}"
readonly RUNNER_KIND="${RUNNER_KIND:-build}"
readonly TOKEN_FILE="${GITHUB_PAT_FILE:-/etc/filius/github-token}"
readonly RUNNER_DOCKER_USER="${RUNNER_DOCKER_USER:-filius-runner}"
readonly RUNNER_HOME="${RUNNER_HOME:-/var/lib/filius-runner}"
readonly DEPLOYMENTS_DIR="${FILIUS_DEPLOYMENTS_DIR:-${RUNNER_HOME}/deployments}"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly COMPOSE_FILE="${FILIUS_RUNNER_COMPOSE_FILE:-${REPO_DIR}/compose.runners.yaml}"

usage() {
  echo "Usage: sudo $0 https://github.com/OWNER/REPOSITORY" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
case "${RUNNER_KIND}" in
  build|deploy|orchestration) ;;
  *) echo "Unknown runner kind: ${RUNNER_KIND}" >&2; exit 2 ;;
esac
[[ "${EUID}" -eq 0 ]] || { echo "Run this script with sudo so it can read the PAT and access Docker." >&2; exit 1; }
[[ -r "${TOKEN_FILE}" ]] || { echo "Cannot read GitHub PAT file: ${TOKEN_FILE}" >&2; exit 1; }
id "${RUNNER_DOCKER_USER}" >/dev/null 2>&1 || { echo "Rootless Docker user not found: ${RUNNER_DOCKER_USER}" >&2; exit 1; }
runner_uid="$(id -u "${RUNNER_DOCKER_USER}")"
readonly DOCKER_SOCKET="${DOCKER_SOCKET:-/run/user/${runner_uid}/docker.sock}"
[[ -S "${DOCKER_SOCKET}" ]] || { echo "Rootless Docker socket not found: ${DOCKER_SOCKET}. Run rootless-docker/setup.sh first." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker CLI is required." >&2; exit 1; }
docker compose version >/dev/null 2>&1 || { echo "Docker Compose v2 plugin is required (docker compose)." >&2; exit 1; }
[[ -f "${COMPOSE_FILE}" ]] || { echo "Compose file not found: ${COMPOSE_FILE}" >&2; exit 1; }
if [[ "${RUNNER_KIND}" == deploy && ! -d "${DEPLOYMENTS_DIR}" ]]; then
  echo "Deployment directory not found: ${DEPLOYMENTS_DIR}. Run rootless-docker/setup.sh first." >&2
  exit 1
fi
if [[ "${RUNNER_KIND}" != orchestration ]]; then
  socket_dir="$(dirname -- "${DOCKER_SOCKET}")"
  socket_dir_owner="$(stat -c '%u' "${socket_dir}")"
  socket_dir_mode="$(stat -c '%a' "${socket_dir}")"
  socket_owner="$(stat -c '%u' "${DOCKER_SOCKET}")"
  if [[ "${socket_dir_owner}" != "${runner_uid}" || "${socket_owner}" != "${runner_uid}" ]] || (( (8#${socket_dir_mode} & 077) != 0 )); then
    echo "Refusing to relax socket permissions: ${socket_dir} must be owned by ${RUNNER_DOCKER_USER} and private to that user." >&2
    exit 1
  fi
  command -v flock >/dev/null 2>&1 || { echo "flock is required to coordinate concurrent runner socket access." >&2; exit 1; }
  readonly SOCKET_LOCK_FILE="${socket_dir}/.filius-runner-socket.lock"
  readonly SOCKET_STATE_FILE="${socket_dir}/.filius-runner-socket.state"
  exec {socket_lock_fd}>"${SOCKET_LOCK_FILE}"
  socket_permissions_registered=0

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
  trap restore_socket_permissions EXIT
fi
export DOCKER_HOST="unix://${DOCKER_SOCKET}"

github_url="${1%/}"
if [[ ! "${github_url}" =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
  echo "Expected a repository URL like https://github.com/OWNER/REPOSITORY" >&2
  exit 2
fi
owner="${BASH_REMATCH[1]}"
repo="${BASH_REMATCH[2]}"

github_pat="$(<"${TOKEN_FILE}")"
if [[ -z "${github_pat}" ]]; then
  echo "GitHub PAT file is empty: ${TOKEN_FILE}" >&2
  exit 1
fi
unset GITHUB_PAT_FILE

docker info >/dev/null
# The socket stays under the runner user's private runtime directory on the
# host. Make the socket itself accessible inside the container, where the
# rootless UID/GID mapping differs from the host IDs.
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
runner_name="${RUNNER_NAME:-filius-${RUNNER_KIND}-$(hostname -s)-$(date +%s)}"
api_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"

echo "Requesting a short-lived runner token for ${owner}/${repo}..."
api_response="$(printf 'Authorization: Bearer %s\n' "${github_pat}" | curl --silent --show-error --fail-with-body \
  --connect-timeout 10 --max-time 60 \
  --request POST \
  --header 'Accept: application/vnd.github+json' \
  --header @- \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "${api_url}")"
unset github_pat

runner_token="$(jq -er '.token' <<<"${api_response}")"
unset api_response
echo "Starting ephemeral runner ${runner_name}; it will exit after one job completes."

export DOCKER_SOCKET RUNNER_NAME="${runner_name}" RUNNER_TOKEN="${runner_token}" GITHUB_URL="${github_url}"
export RUNNER_IMAGE="${IMAGE}" FILIUS_DEPLOYMENTS_DIR="${DEPLOYMENTS_DIR}"
case "${RUNNER_KIND}" in
  deploy) compose_service=deployment-runner ;;
  orchestration) compose_service=orchestration-runner ;;
  build) compose_service=build-runner ;;
esac
docker compose --project-name filius-runners --file "${COMPOSE_FILE}" run \
  --rm --no-deps --name "${runner_name}" "${compose_service}"

unset runner_token
echo "Runner job completed; the ephemeral runner container has been removed."
