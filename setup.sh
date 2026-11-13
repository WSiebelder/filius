#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TOKEN_FILE="${GITHUB_PAT_FILE:-/etc/filius/github-token}"
readonly RUNNER_USER="${RUNNER_USER:-filius-runner}"
readonly RUNNER_HOME="${RUNNER_HOME:-/var/lib/filius-runner}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run the installer with sudo: sudo $0" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "This installer currently supports Debian or Ubuntu." >&2
  exit 1
fi
host_os="$(. /etc/os-release; printf '%s %s' "${ID:-}" "${ID_LIKE:-}")"
if [[ ! " ${host_os,,} " =~ (debian|ubuntu) ]]; then
  echo "This installer currently supports Debian or Ubuntu." >&2
  exit 1
fi
if ! command -v systemctl >/dev/null || ! command -v apt-get >/dev/null; then
  echo "This installer requires systemd and apt-get." >&2
  exit 1
fi

if ! command -v curl >/dev/null || ! command -v jq >/dev/null; then
  apt-get update
  apt-get install -y --no-install-recommends curl jq
fi

install -d -m 700 "$(dirname -- "${TOKEN_FILE}")"
if [[ ! -s "${TOKEN_FILE}" ]]; then
  echo "No GitHub PAT found at ${TOKEN_FILE}."
  echo "Create a fine-grained PAT with repository Administration: Read and write permission."
  read -r -s -p "Paste the PAT (input hidden): " github_pat
  echo
  if [[ -z "${github_pat}" ]]; then
    echo "No token entered." >&2
    exit 1
  fi
  umask 077
  printf '%s' "${github_pat}" >"${TOKEN_FILE}"
  unset github_pat
fi
chmod 600 "${TOKEN_FILE}"

read -r -p "GitHub repository URL (https://github.com/OWNER/REPOSITORY): " github_url
github_url="${github_url%/}"
if [[ ! "${github_url}" =~ ^https://github\.com/([^/]+)/([^/]+)$ ]]; then
  echo "Expected a repository URL like https://github.com/OWNER/REPOSITORY" >&2
  exit 2
fi
owner="${BASH_REMATCH[1]}"
repo="${BASH_REMATCH[2]}"
api_url="https://api.github.com/repos/${owner}/${repo}/actions/runners/registration-token"
github_pat="$(<"${TOKEN_FILE}")"

echo "Checking GitHub API access for ${owner}/${repo}..."
api_response="$(printf 'Authorization: Bearer %s\n' "${github_pat}" | curl --silent --show-error --fail-with-body \
  --request POST \
  --header 'Accept: application/vnd.github+json' \
  --header @- \
  --header 'X-GitHub-Api-Version: 2022-11-28' \
  "${api_url}")"
unset github_pat
discarded_runner_token="$(jq -er '.token' <<<"${api_response}")"
unset api_response discarded_runner_token
echo "GitHub accepted the credential and returned a registration token. The test token was discarded."

echo "Setting up rootless Docker..."
bash "${SCRIPT_DIR}/rootless-docker/setup.sh"

runner_uid="$(id -u "${RUNNER_USER}")"
docker_socket="/run/user/${runner_uid}/docker.sock"
if [[ ! -S "${docker_socket}" ]]; then
  echo "Rootless Docker socket not found: ${docker_socket}" >&2
  exit 1
fi

echo "Building the runner image with ${RUNNER_USER}'s rootless Docker daemon..."
runuser -u "${RUNNER_USER}" -- env \
  HOME="${RUNNER_HOME}" \
  USER="${RUNNER_USER}" \
  LOGNAME="${RUNNER_USER}" \
  DOCKER_HOST="unix://${docker_socket}" \
  bash "${SCRIPT_DIR}/build-runner/build.sh"

echo "Building the deployment runner image with ${RUNNER_USER}'s rootless Docker daemon..."
runuser -u "${RUNNER_USER}" -- env \
  HOME="${RUNNER_HOME}" \
  USER="${RUNNER_USER}" \
  LOGNAME="${RUNNER_USER}" \
  DOCKER_HOST="unix://${docker_socket}" \
  bash "${SCRIPT_DIR}/deployment-runner/build.sh"

runuser -u "${RUNNER_USER}" -- env \
  HOME="${RUNNER_HOME}" \
  USER="${RUNNER_USER}" \
  LOGNAME="${RUNNER_USER}" \
  DOCKER_HOST="unix://${docker_socket}" \
  docker image inspect filius-builder:local >/dev/null
runuser -u "${RUNNER_USER}" -- env \
  HOME="${RUNNER_HOME}" \
  USER="${RUNNER_USER}" \
  LOGNAME="${RUNNER_USER}" \
  DOCKER_HOST="unix://${docker_socket}" \
  docker image inspect filius-deployer:local >/dev/null

echo
echo "Setup complete. The build and deployment runner images are ready and the GitHub API check passed."
echo "To wait for one job, run: sudo ${SCRIPT_DIR}/build-runner/run-once.sh ${github_url}"
echo "For a deployment job, run: sudo ${SCRIPT_DIR}/deployment-runner/run-once.sh ${github_url}"
