#!/usr/bin/env bash
set -euo pipefail

# Start one ephemeral Actions runner. It waits for one matching job, runs it,
# then deregisters and exits. The host removes its container on exit.

readonly IMAGE="${RUNNER_IMAGE:-filius-builder:local}"
readonly TOKEN_FILE="${GITHUB_PAT_FILE:-/etc/filius/github-token}"
readonly RUNNER_DOCKER_USER="${RUNNER_DOCKER_USER:-filius-runner}"

usage() {
  echo "Usage: sudo $0 https://github.com/OWNER/REPOSITORY" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
[[ "${EUID}" -eq 0 ]] || { echo "Run this script with sudo so it can read the PAT and access Docker." >&2; exit 1; }
[[ -r "${TOKEN_FILE}" ]] || { echo "Cannot read GitHub PAT file: ${TOKEN_FILE}" >&2; exit 1; }
id "${RUNNER_DOCKER_USER}" >/dev/null 2>&1 || { echo "Rootless Docker user not found: ${RUNNER_DOCKER_USER}" >&2; exit 1; }
runner_uid="$(id -u "${RUNNER_DOCKER_USER}")"
readonly DOCKER_SOCKET="${DOCKER_SOCKET:-/run/user/${runner_uid}/docker.sock}"
[[ -S "${DOCKER_SOCKET}" ]] || { echo "Rootless Docker socket not found: ${DOCKER_SOCKET}. Run rootless-docker/setup.sh first." >&2; exit 1; }
socket_dir="$(dirname -- "${DOCKER_SOCKET}")"
socket_dir_owner="$(stat -c '%u' "${socket_dir}")"
socket_dir_mode="$(stat -c '%a' "${socket_dir}")"
socket_owner="$(stat -c '%u' "${DOCKER_SOCKET}")"
if [[ "${socket_dir_owner}" != "${runner_uid}" || "${socket_owner}" != "${runner_uid}" ]] || (( (8#${socket_dir_mode} & 077) != 0 )); then
  echo "Refusing to relax socket permissions: ${socket_dir} must be owned by ${RUNNER_DOCKER_USER} and private to that user." >&2
  exit 1
fi
original_socket_mode="$(stat -c '%a' "${DOCKER_SOCKET}")"
restore_socket_permissions() {
  chmod "${original_socket_mode}" "${DOCKER_SOCKET}" 2>/dev/null || true
}
trap restore_socket_permissions EXIT
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
chmod 0666 "${DOCKER_SOCKET}"
runner_name="filius-build-$(hostname -s)-$(date +%s)"
api_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"

echo "Requesting a short-lived runner token for ${owner}/${repo}..."
api_response="$(printf 'Authorization: Bearer %s\n' "${github_pat}" | curl --silent --show-error --fail-with-body \
  --request POST \
  --header 'Accept: application/vnd.github+json' \
  --header @- \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "${api_url}")"
unset github_pat

runner_token="$(jq -er '.token' <<<"${api_response}")"
unset api_response
echo "Starting ephemeral runner ${runner_name}; it will exit after one job completes."

docker run --rm \
  --name "${runner_name}" \
  --volume "${DOCKER_SOCKET}:/var/run/docker.sock" \
  --env "GITHUB_URL=${github_url}" \
  --env "RUNNER_TOKEN=${runner_token}" \
  --env "RUNNER_NAME=${runner_name}" \
  "${IMAGE}"

unset runner_token
echo "Runner job completed; the ephemeral runner container has been removed."
