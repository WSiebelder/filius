#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly TOKEN_FILE="${GITHUB_PAT_FILE:-/etc/filius/github-token}"
readonly REPO_FILE="${FILIUS_REPO_FILE:-/etc/filius/repository-url}"
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

configured_repo=""
if [[ -s "${REPO_FILE}" ]]; then
  IFS= read -r configured_repo <"${REPO_FILE}" || true
  configured_repo="${configured_repo%/}"
fi
prompt_repo="${configured_repo:-https://github.com/OWNER/REPOSITORY}"
read -r -p "Orchestration repository URL [${prompt_repo}] (press Enter to keep): " github_url
github_url="${github_url:-${configured_repo}}"
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
install -d -m 700 "$(dirname -- "${REPO_FILE}")"
umask 077
printf '%s\n' "${github_url}" >"${REPO_FILE}"
chmod 600 "${REPO_FILE}"

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
  DOCKER_SOCKET="${docker_socket}" \
  GITHUB_URL="https://github.com/${owner}/${repo}" \
  RUNNER_TOKEN="setup-validation-placeholder" \
  RUNNER_NAME="setup-validation-placeholder" \
  FILIUS_DEPLOYMENTS_DIR="${RUNNER_HOME}/deployments" \
  docker compose --project-name filius-runners --file "${SCRIPT_DIR}/compose.runners.yaml" config --quiet

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

command -v timeout >/dev/null || { echo "timeout is required for bounded orchestration shutdown." >&2; exit 1; }
readonly orchestration_unit=filius-orchestrator.service
readonly runtime_dir=/usr/local/lib/filius
readonly unit_file="/etc/systemd/system/${orchestration_unit}"
readonly dropin_dir="${unit_file}.d"
readonly orchestration_env=/etc/filius/orchestration.env
temporary_dir="$(mktemp -d)"
cleanup_installation() {
  rm -f "${temporary_dir}/orchestration.env" "${temporary_dir}/rootless-docker.conf"
  rmdir "${temporary_dir}"
}
trap cleanup_installation EXIT

write_setting() {
  local key="$1" value="$2"
  if [[ "${value}" == *$'\n'* || "${value}" == *$'\r'* ]]; then
    echo "Orchestration configuration must not contain line breaks: ${key}" >&2
    exit 1
  fi
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s="%s"\n' "${key}" "${value}"
}
{
  write_setting GITHUB_URL "${github_url}"
  write_setting GITHUB_PAT_FILE "${TOKEN_FILE}"
  write_setting RUNNER_DOCKER_USER "${RUNNER_USER}"
  write_setting RUNNER_HOME "${RUNNER_HOME}"
  write_setting DOCKER_SOCKET "${docker_socket}"
} >"${temporary_dir}/orchestration.env"
printf '[Unit]\nWants=user@%s.service\nAfter=user@%s.service\n' \
  "${runner_uid}" "${runner_uid}" >"${temporary_dir}/rootless-docker.conf"

runtime_sources=(
  "${SCRIPT_DIR}/build-runner/run-once.sh"
  "${SCRIPT_DIR}/orchestration-runner/run-once.sh"
  "${SCRIPT_DIR}/compose.runners.yaml"
  "${SCRIPT_DIR}/orchestration-runner/filius-orchestrator.service"
  "${temporary_dir}/orchestration.env"
  "${temporary_dir}/rootless-docker.conf"
)
runtime_targets=(
  "${runtime_dir}/build-runner/run-once.sh"
  "${runtime_dir}/orchestration-runner/run-once.sh"
  "${runtime_dir}/compose.runners.yaml"
  "${unit_file}"
  "${orchestration_env}"
  "${dropin_dir}/rootless-docker.conf"
)
service_state="$(systemctl show --property=ActiveState --value "${orchestration_unit}" 2>/dev/null || true)"
case "${service_state}" in
  active|activating|deactivating)
    for i in "${!runtime_sources[@]}"; do
      if ! cmp -s "${runtime_sources[$i]}" "${runtime_targets[$i]}"; then
        echo "Orchestration runtime changes require an explicit stop before installation." >&2
        echo "When no orchestration job is active, run: sudo systemctl stop ${orchestration_unit}" >&2
        echo "Then rerun sudo ${SCRIPT_DIR}/setup.sh to install the changes and start the service." >&2
        exit 1
      fi
    done
    ;;
esac

echo "Installing the root-owned orchestration runtime..."
install -d -o root -g root -m 755 "${runtime_dir}" \
  "${runtime_dir}/build-runner" "${runtime_dir}/orchestration-runner" "${dropin_dir}"
install -d -o root -g root -m 700 /etc/filius
for i in "${!runtime_sources[@]}"; do
  target="${runtime_targets[$i]}"
  mode=644
  [[ "${target}" == "${orchestration_env}" ]] && mode=600
  if ! cmp -s "${runtime_sources[$i]}" "${target}"; then
    install -o root -g root -m "${mode}" "${runtime_sources[$i]}" "${target}"
  else
    chown root:root "${target}"
    chmod "${mode}" "${target}"
  fi
done
systemctl daemon-reload
systemctl enable --now "${orchestration_unit}"
if ! systemctl is-active --quiet "${orchestration_unit}"; then
  echo "Orchestration service is not active; inspect: sudo journalctl -u ${orchestration_unit}" >&2
  exit 1
fi

echo
echo "Setup complete. The build and deployment runner images are ready and the GitHub API check passed."
echo "The orchestration service is enabled and active. GitHub registration may still be starting."
echo "Check readiness with: sudo journalctl -u ${orchestration_unit} -f"
echo "Once the runner is online, manually dispatch dispatch_runner.yml in the selected repository; it prints HelloWorld."
echo "The legacy build/deployment pool has not been started."
