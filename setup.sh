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

if ! command -v curl >/dev/null || ! command -v jq >/dev/null || [[ ! -x /usr/bin/python3 ]]; then
  apt-get update
  apt-get install -y --no-install-recommends curl jq python3
fi
/usr/bin/python3 -c 'import sys; assert sys.version_info >= (3, 8), "Python 3.8+ is required"'

install -d -m 700 "$(dirname -- "${TOKEN_FILE}")"
if [[ ! -s "${TOKEN_FILE}" ]]; then
  echo "No GitHub PAT found at ${TOKEN_FILE}."
  echo "Create a fine-grained PAT with repository Administration: Read and write, and Actions: Read permissions."
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
chown root:root "${TOKEN_FILE}"

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
/usr/bin/python3 "${SCRIPT_DIR}/host-control/controller.py" validate "${SCRIPT_DIR}/eligible-repositories.json" "${github_url}"
GITHUB_URL="${github_url}" GITHUB_PAT_FILE="${TOKEN_FILE}" \
  FILIUS_ELIGIBILITY_FILE="${SCRIPT_DIR}/eligible-repositories.json" \
  /usr/bin/python3 "${SCRIPT_DIR}/host-control/controller.py" check-access
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
command -v flock >/dev/null || { echo "flock is required for managed build socket coordination." >&2; exit 1; }
readonly orchestration_unit=filius-orchestrator.service
readonly runtime_dir=/usr/local/lib/filius
readonly unit_file="/etc/systemd/system/${orchestration_unit}"
readonly dropin_dir="${unit_file}.d"
readonly orchestration_env=/etc/filius/orchestration.env
readonly control_dir=/var/lib/filius-control
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
  write_setting FILIUS_CONTROL_DIR "${control_dir}"
  write_setting FILIUS_ELIGIBILITY_FILE /etc/filius/eligible-repositories.json
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
  "${SCRIPT_DIR}/eligible-repositories.json"
  "${SCRIPT_DIR}/host-control/controller.py"
  "${SCRIPT_DIR}/host-control/drain.sh"
  "${SCRIPT_DIR}/host-control/filius-dispatch.path"
  "${SCRIPT_DIR}/host-control/filius-dispatch.service"
  "${SCRIPT_DIR}/host-control/filius-build-worker.service"
  "${temporary_dir}/rootless-docker.conf"
  "${temporary_dir}/rootless-docker.conf"
)
runtime_targets=(
  "${runtime_dir}/build-runner/run-once.sh"
  "${runtime_dir}/orchestration-runner/run-once.sh"
  "${runtime_dir}/compose.runners.yaml"
  "${unit_file}"
  "${orchestration_env}"
  "${dropin_dir}/rootless-docker.conf"
  /etc/filius/eligible-repositories.json
  "${runtime_dir}/host-control/controller.py"
  "${runtime_dir}/host-control/drain.sh"
  /etc/systemd/system/filius-dispatch.path
  /etc/systemd/system/filius-dispatch.service
  /etc/systemd/system/filius-build-worker.service
  /etc/systemd/system/filius-dispatch.service.d/rootless-docker.conf
  /etc/systemd/system/filius-build-worker.service.d/rootless-docker.conf
)
runtime_changed=0
for i in "${!runtime_sources[@]}"; do
  if ! cmp -s "${runtime_sources[$i]}" "${runtime_targets[$i]}"; then
    runtime_changed=1
  fi
done
if ((runtime_changed)); then
  for unit in "${orchestration_unit}" filius-build-worker.service filius-dispatch.path filius-dispatch.service filius-build-drain.service; do
    service_state="$(systemctl show --property=ActiveState --value "${unit}" 2>/dev/null || true)"
    case "${service_state}" in
      active|activating|deactivating)
        echo "Runtime changes require an explicit stop of ${unit} before installation." >&2
        echo "Pause dispatch, stop supervision when safe, and wait for build containers to finish; see README.md." >&2
        exit 1
        ;;
    esac
  done
  if [[ -f "${control_dir}/state/worker.json" ]]; then
    GITHUB_URL="${github_url}" DOCKER_SOCKET="${docker_socket}" \
      FILIUS_CONTROL_DIR="${control_dir}" FILIUS_ELIGIBILITY_FILE="${SCRIPT_DIR}/eligible-repositories.json" \
      /usr/bin/python3 "${SCRIPT_DIR}/host-control/controller.py" check-install
  fi
fi

echo "Installing the root-owned orchestration and demand-enabled build runtime..."
install -d -o root -g root -m 755 "${runtime_dir}" \
  "${runtime_dir}/build-runner" "${runtime_dir}/orchestration-runner" "${runtime_dir}/host-control" "${dropin_dir}" \
  /etc/systemd/system/filius-dispatch.service.d /etc/systemd/system/filius-build-worker.service.d
install -d -o root -g root -m 700 /etc/filius
if [[ -L "${control_dir}" ]]; then
  echo "Refusing a symlink control directory: ${control_dir}" >&2
  exit 1
fi
# The daemon account may traverse this parent for bind mounts; other users may not.
install -d -o root -g "$(id -gn "${RUNNER_USER}")" -m 710 "${control_dir}"
for directory in requests results state; do
  if [[ -L "${control_dir}/${directory}" ]]; then
    echo "Refusing a symlink control subdirectory: ${directory}" >&2
    exit 1
  fi
done
install -d -o root -g root -m 1733 "${control_dir}/requests"
install -d -o root -g root -m 755 "${control_dir}/results"
install -d -o root -g root -m 700 "${control_dir}/state"
for i in "${!runtime_sources[@]}"; do
  target="${runtime_targets[$i]}"
  mode=644
  [[ "${target}" == "${orchestration_env}" || "${target}" == /etc/filius/eligible-repositories.json ]] && mode=600
  if ! cmp -s "${runtime_sources[$i]}" "${target}"; then
    install -o root -g root -m "${mode}" "${runtime_sources[$i]}" "${target}"
  else
    chown root:root "${target}"
    chmod "${mode}" "${target}"
  fi
done
systemctl daemon-reload
systemctl enable filius-build-worker.service
systemctl enable --now filius-dispatch.path
systemctl enable --now "${orchestration_unit}"
if ! systemctl is-active --quiet "${orchestration_unit}"; then
  echo "Orchestration service is not active; inspect: sudo journalctl -u ${orchestration_unit}" >&2
  exit 1
fi

echo
echo "Setup complete. The build and deployment runner images are ready and the GitHub API check passed."
echo "The orchestration service is enabled and active. GitHub registration may still be starting."
echo "Check readiness with: sudo journalctl -u ${orchestration_unit} -f"
echo "Once the runner is online, manually dispatch dispatch_runner.yml to start/reuse one build worker for queued build work."
echo "Build workers are not started by setup; previously enabled state is retained for boot recovery."
echo "The legacy build/deployment pool has not been started."
